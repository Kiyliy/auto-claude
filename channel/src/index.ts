#!/usr/bin/env node
/**
 * Auto-Claude Telegram Channel — MCP Server (thin proxy)
 *
 * This is a thin wrapper around the Channel Daemon. It:
 *   1. Checks if the daemon is running, starts it if not
 *   2. Registers this CC session with the daemon (gets a topic)
 *   3. Polls the daemon for incoming messages -> pushes to CC
 *   4. Exposes MCP tools that proxy to the daemon's HTTP API
 *   5. On exit, unregisters the session
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { spawn } from "node:child_process";
import { request as httpRequest } from "node:http";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { z } from "zod";

import { loadConfig, type ChannelConfig } from "./config.js";

// ---------------------------------------------------------------------------
// Logging — always to stderr (stdout is MCP protocol)
// ---------------------------------------------------------------------------

function log(level: string, ...args: unknown[]): void {
  const ts = new Date().toISOString();
  console.error(`[${ts}] [mcp] [${level}]`, ...args);
}

// ---------------------------------------------------------------------------
// Unix socket HTTP helpers
// ---------------------------------------------------------------------------

interface DaemonResponse {
  ok: boolean;
  [key: string]: unknown;
}

/**
 * Make an HTTP request to the daemon via Unix domain socket.
 */
function daemonRequest(
  socketPath: string,
  method: string,
  path: string,
  body?: unknown,
): Promise<DaemonResponse> {
  return new Promise((resolve, reject) => {
    const options = {
      socketPath,
      path,
      method,
      headers: body
        ? { "Content-Type": "application/json" }
        : undefined,
    };

    const req = httpRequest(options, (res) => {
      let raw = "";
      res.on("data", (chunk: Buffer) => {
        raw += chunk.toString();
      });
      res.on("end", () => {
        try {
          resolve(JSON.parse(raw) as DaemonResponse);
        } catch {
          reject(new Error(`Invalid JSON from daemon: ${raw.slice(0, 200)}`));
        }
      });
    });

    req.on("error", (err) => {
      reject(err);
    });

    // Timeout for non-long-poll requests
    if (!path.includes("/messages")) {
      req.setTimeout(10000, () => {
        req.destroy(new Error("daemon request timeout"));
      });
    }

    if (body) {
      req.write(JSON.stringify(body));
    }
    req.end();
  });
}

/**
 * Long-poll version with configurable timeout.
 */
function daemonLongPoll(
  socketPath: string,
  path: string,
  timeoutSec: number,
): Promise<DaemonResponse> {
  return new Promise((resolve, reject) => {
    const options = {
      socketPath,
      path,
      method: "GET",
    };

    const req = httpRequest(options, (res) => {
      let raw = "";
      res.on("data", (chunk: Buffer) => {
        raw += chunk.toString();
      });
      res.on("end", () => {
        try {
          resolve(JSON.parse(raw) as DaemonResponse);
        } catch {
          reject(new Error(`Invalid JSON from daemon: ${raw.slice(0, 200)}`));
        }
      });
    });

    req.on("error", (err) => {
      reject(err);
    });

    // Allow extra time beyond the server-side timeout
    req.setTimeout((timeoutSec + 10) * 1000, () => {
      req.destroy(new Error("long-poll timeout"));
    });

    req.end();
  });
}

// ---------------------------------------------------------------------------
// Daemon lifecycle
// ---------------------------------------------------------------------------

async function checkHealth(socketPath: string): Promise<boolean> {
  try {
    const resp = await daemonRequest(socketPath, "GET", "/health");
    return resp.ok === true;
  } catch {
    return false;
  }
}

function startDaemon(): void {
  // Locate daemon.ts relative to this file
  const thisDir = dirname(fileURLToPath(import.meta.url));
  const daemonScript = join(thisDir, "daemon.ts");

  log("info", `Starting daemon: npx tsx ${daemonScript}`);

  const child = spawn("npx", ["tsx", daemonScript], {
    detached: true,
    stdio: "ignore",
    env: { ...process.env },
  });

  child.unref();

  log("info", `Daemon spawned (pid=${child.pid})`);
}

// ---------------------------------------------------------------------------
// Session registration / unregistration
// ---------------------------------------------------------------------------

async function registerSession(
  socketPath: string,
  sessionId: string,
): Promise<{ topic_thread_id: number | null }> {
  const resp = await daemonRequest(socketPath, "POST", "/sessions", {
    session_id: sessionId,
  });

  if (!resp.ok) {
    throw new Error(`Failed to register session: ${JSON.stringify(resp)}`);
  }

  return {
    topic_thread_id: (resp.topic_thread_id as number) ?? null,
  };
}

async function unregisterSession(
  socketPath: string,
  sessionId: string,
): Promise<void> {
  try {
    await daemonRequest(socketPath, "DELETE", `/sessions/${encodeURIComponent(sessionId)}`);
    log("info", `Session ${sessionId} unregistered`);
  } catch (err) {
    log("error", `Failed to unregister session ${sessionId}:`, err);
  }
}

// ---------------------------------------------------------------------------
// Message polling
// ---------------------------------------------------------------------------

interface QueuedMessage {
  message_id: number;
  text: string;
  user: string;
  date: number;
  message_thread_id?: number;
}

let pollingActive = false;

async function startMessagePolling(
  socketPath: string,
  sessionId: string,
  server: McpServer,
): Promise<void> {
  pollingActive = true;
  const pollPath = `/sessions/${encodeURIComponent(sessionId)}/messages?timeout=30`;
  let backoff = 1000;

  log("info", `Message polling started for session ${sessionId}`);

  while (pollingActive) {
    try {
      const resp = await daemonLongPoll(socketPath, pollPath, 30);
      backoff = 1000;

      if (!resp.ok) {
        log("error", "Message poll returned error:", resp);
        await sleep(backoff);
        continue;
      }

      const messages = (resp.messages as QueuedMessage[]) ?? [];

      for (const msg of messages) {
        try {
          await server.server.notification({
            method: "notifications/claude/channel",
            params: {
              content: msg.text,
              meta: {
                chat_id: String(msg.message_thread_id ?? ""),
                message_id: msg.message_id,
                user: msg.user,
              },
            },
          });
        } catch (notifErr) {
          log("error", "Failed to push notification to CC:", notifErr);
        }
      }
    } catch (err) {
      if (!pollingActive) break;
      log("error", `Message polling error (retry in ${backoff}ms):`, err);
      await sleep(backoff);
      backoff = Math.min(backoff * 2, 30000);
    }
  }

  log("info", "Message polling stopped");
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ---------------------------------------------------------------------------
// MCP Server
// ---------------------------------------------------------------------------

const server = new McpServer(
  {
    name: "auto-claude-telegram-channel",
    version: "0.2.0",
  },
  {
    capabilities: {
      experimental: { "claude/channel": {} },
    },
    instructions: [
      "Telegram 消息到达时显示为 <channel source=\"auto-claude-telegram\" chat_id=\"...\" message_id=\"...\" user=\"...\">。",
      "使用 reply tool 回复。对最新消息直接回复不需要 reply_to。",
    ].join("\n"),
  },
);

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  const config = loadConfig();
  const socketPath = config.socketPath;

  log("info", "Auto-Claude Telegram Channel MCP starting...");
  log("info", `  socket: ${socketPath}`);

  // 1. Check if daemon is running
  let daemonRunning = await checkHealth(socketPath);

  // 2. If not running, start daemon
  if (!daemonRunning) {
    log("info", "Daemon not running, starting...");
    startDaemon();

    // Wait and retry health check
    for (let i = 0; i < 10; i++) {
      await sleep(1000);
      daemonRunning = await checkHealth(socketPath);
      if (daemonRunning) break;
      log("info", `Waiting for daemon to start (attempt ${i + 1}/10)...`);
    }

    if (!daemonRunning) {
      log("error", "Failed to start daemon after 10 seconds");
      // Continue anyway — tools will fail gracefully
    }
  }

  log("info", `Daemon status: ${daemonRunning ? "running" : "NOT running"}`);

  // 3. Register this session
  const sessionId = process.env["CLAUDE_SESSION_ID"] || `session-${Date.now()}`;
  let topicThreadId: number | null = null;

  if (daemonRunning) {
    try {
      const reg = await registerSession(socketPath, sessionId);
      topicThreadId = reg.topic_thread_id;
      log("info", `Session registered: ${sessionId} (topic=${topicThreadId})`);
    } catch (err) {
      log("error", "Failed to register session:", err);
    }
  }

  // 4. Start polling daemon for messages -> push to CC
  if (daemonRunning) {
    startMessagePolling(socketPath, sessionId, server).catch((err) => {
      log("error", "Message polling loop exited with error:", err);
    });
  }

  // 5. Set up MCP tools that proxy to daemon

  // reply — send a message to this session's topic
  server.tool(
    "reply",
    "回复 Telegram 消息。传入 text，可选 reply_to 引用某条消息。",
    {
      text: z.string().describe("Message text to send"),
      reply_to: z.number().optional().describe("Message ID to reply to (quote-reply)"),
    },
    async ({ text, reply_to }) => {
      log("tool", `reply -> text="${text.slice(0, 60)}..." reply_to=${reply_to ?? "none"}`);

      try {
        const resp = await daemonRequest(
          socketPath,
          "POST",
          `/sessions/${encodeURIComponent(sessionId)}/reply`,
          { text, reply_to },
        );

        if (!resp.ok) {
          return {
            content: [{ type: "text" as const, text: `Error: ${resp.error ?? "unknown error"}` }],
          };
        }

        return {
          content: [
            { type: "text" as const, text: `Sent message_id=${resp.message_id}` },
          ],
        };
      } catch (err) {
        return {
          content: [
            { type: "text" as const, text: `Error: ${err instanceof Error ? err.message : String(err)}` },
          ],
        };
      }
    },
  );

  // notify — send a notification (optionally to this session's topic)
  server.tool(
    "notify",
    "发送通知到 Telegram。",
    {
      text: z.string().describe("Notification text"),
    },
    async ({ text }) => {
      log("tool", `notify -> text="${text.slice(0, 60)}..."`);

      try {
        const resp = await daemonRequest(socketPath, "POST", "/notify", {
          message: text,
          event_type: "info",
          session_id: sessionId,
        });

        if (!resp.ok) {
          return {
            content: [{ type: "text" as const, text: `Error: ${resp.error ?? "unknown error"}` }],
          };
        }

        return {
          content: [
            { type: "text" as const, text: `Notification sent (routed=${resp.sent ?? false})` },
          ],
        };
      } catch (err) {
        return {
          content: [
            { type: "text" as const, text: `Error: ${err instanceof Error ? err.message : String(err)}` },
          ],
        };
      }
    },
  );

  // 6. Connect MCP to stdio
  const transport = new StdioServerTransport();
  await server.connect(transport);

  log("info", "MCP server connected via stdio");

  // 7. On exit: unregister session
  const cleanup = async (): Promise<void> => {
    pollingActive = false;
    if (daemonRunning) {
      await unregisterSession(socketPath, sessionId);
    }
    process.exit(0);
  };

  process.on("SIGINT", () => { cleanup(); });
  process.on("SIGTERM", () => { cleanup(); });
}

main().catch((err) => {
  log("fatal", "Startup failed:", err);
  process.exit(1);
});
