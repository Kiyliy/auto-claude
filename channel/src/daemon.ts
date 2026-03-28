#!/usr/bin/env node
/**
 * Auto-Claude Channel Daemon — standalone long-running process.
 *
 * Manages:
 *   - Telegram long-polling (single connection per bot token)
 *   - HTTP API on a Unix domain socket (~/.auto-claude/channel.sock)
 *   - Session registry with Telegram topic isolation
 *   - Message routing: Telegram topic -> session message queue
 *
 * Started automatically by the MCP proxy (index.ts) if not already running.
 * Can also be started manually: npx tsx src/daemon.ts
 */

import { createServer, IncomingMessage, ServerResponse } from "node:http";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
  unlinkSync,
} from "node:fs";
import { dirname } from "node:path";

import {
  loadConfig,
  type ChannelConfig,
  STATE_DIR,
  PID_FILE,
  SESSIONS_FILE,
} from "./config.js";
import {
  sendMessage,
  getUpdates,
  createForumTopic,
  closeForumTopic,
  editForumTopic,
  type TelegramUpdate,
  type TelegramMessage,
} from "./telegram.js";

// ---------------------------------------------------------------------------
// Logging — always to stderr
// ---------------------------------------------------------------------------

function log(level: string, ...args: unknown[]): void {
  const ts = new Date().toISOString();
  console.error(`[${ts}] [daemon] [${level}]`, ...args);
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface SessionEntry {
  session_id: string;
  name: string;
  topic_thread_id: number | null; // null when groupMode is off
  created_at: string;
  message_queue: QueuedMessage[];
}

interface QueuedMessage {
  message_id: number;
  text: string;
  user: string;
  date: number;
  message_thread_id?: number;
}

/** Persisted format (no message_queue — that is transient) */
interface PersistedSession {
  session_id: string;
  name: string;
  topic_thread_id: number | null;
  created_at: string;
}

// ---------------------------------------------------------------------------
// Session Registry
// ---------------------------------------------------------------------------

const sessions = new Map<string, SessionEntry>();

/** Long-poll waiters: session_id -> list of resolve callbacks */
const waiters = new Map<string, Array<(msgs: QueuedMessage[]) => void>>();

function persistSessions(): void {
  try {
    mkdirSync(dirname(SESSIONS_FILE), { recursive: true });
    const data: PersistedSession[] = [];
    for (const s of sessions.values()) {
      data.push({
        session_id: s.session_id,
        name: s.name,
        topic_thread_id: s.topic_thread_id,
        created_at: s.created_at,
      });
    }
    writeFileSync(SESSIONS_FILE, JSON.stringify(data, null, 2));
  } catch (err) {
    log("error", "Failed to persist sessions:", err);
  }
}

function loadPersistedSessions(): void {
  if (!existsSync(SESSIONS_FILE)) return;
  try {
    const raw = readFileSync(SESSIONS_FILE, "utf-8");
    const data = JSON.parse(raw) as PersistedSession[];
    for (const ps of data) {
      sessions.set(ps.session_id, {
        ...ps,
        message_queue: [],
      });
    }
    log("info", `Recovered ${sessions.size} sessions from disk`);
  } catch (err) {
    log("error", "Failed to load persisted sessions:", err);
  }
}

// ---------------------------------------------------------------------------
// Topic naming
// ---------------------------------------------------------------------------

function makeTopicName(sessionId: string): string {
  const short = sessionId.slice(0, 8);
  const now = new Date();
  const pad = (n: number) => String(n).padStart(2, "0");
  const ts = `${pad(now.getMonth() + 1)}-${pad(now.getDate())} ${pad(now.getHours())}:${pad(now.getMinutes())}`;
  return `CC: ${short} | ${ts}`;
}

function makeDoneTopicName(sessionId: string): string {
  const short = sessionId.slice(0, 8);
  // Find the session's created_at for the original timestamp
  const entry = sessions.get(sessionId);
  if (entry) {
    const created = new Date(entry.created_at);
    const pad = (n: number) => String(n).padStart(2, "0");
    const ts = `${pad(created.getMonth() + 1)}-${pad(created.getDate())} ${pad(created.getHours())}:${pad(created.getMinutes())}`;
    return `[Done] CC: ${short} | ${ts}`;
  }
  return `[Done] CC: ${short}`;
}

// ---------------------------------------------------------------------------
// Session Management
// ---------------------------------------------------------------------------

async function registerSession(
  config: ChannelConfig,
  sessionId: string,
  name?: string,
): Promise<SessionEntry> {
  // Check if session already exists (reconnection)
  const existing = sessions.get(sessionId);
  if (existing) {
    log("info", `Session ${sessionId} re-registered (topic=${existing.topic_thread_id})`);
    return existing;
  }

  let topicThreadId: number | null = null;

  // Create a Telegram topic if in group mode
  if (config.groupMode && config.botToken && config.chatId) {
    const topicName = name || makeTopicName(sessionId);
    const topic = await createForumTopic(config.botToken, config.chatId, topicName);
    if (topic) {
      topicThreadId = topic.message_thread_id;
      log("info", `Created topic "${topicName}" (thread_id=${topicThreadId}) for session ${sessionId}`);
    } else {
      log("error", `Failed to create topic for session ${sessionId}`);
    }
  }

  const entry: SessionEntry = {
    session_id: sessionId,
    name: name || makeTopicName(sessionId),
    topic_thread_id: topicThreadId,
    created_at: new Date().toISOString(),
    message_queue: [],
  };

  sessions.set(sessionId, entry);
  persistSessions();

  log("info", `Session registered: ${sessionId} (topic=${topicThreadId})`);
  return entry;
}

async function unregisterSession(
  config: ChannelConfig,
  sessionId: string,
): Promise<boolean> {
  const entry = sessions.get(sessionId);
  if (!entry) return false;

  // Rename and close the topic
  if (entry.topic_thread_id && config.botToken && config.chatId) {
    const doneName = makeDoneTopicName(sessionId);
    await editForumTopic(config.botToken, config.chatId, entry.topic_thread_id, doneName);
    await closeForumTopic(config.botToken, config.chatId, entry.topic_thread_id);
    log("info", `Closed topic ${entry.topic_thread_id} for session ${sessionId}`);
  }

  sessions.delete(sessionId);
  persistSessions();

  // Resolve any pending waiters with empty array
  const pending = waiters.get(sessionId);
  if (pending) {
    for (const resolve of pending) {
      resolve([]);
    }
    waiters.delete(sessionId);
  }

  log("info", `Session unregistered: ${sessionId}`);
  return true;
}

// ---------------------------------------------------------------------------
// Message routing
// ---------------------------------------------------------------------------

/** Find which session owns a given topic thread_id */
function findSessionByTopic(threadId: number): SessionEntry | undefined {
  for (const entry of sessions.values()) {
    if (entry.topic_thread_id === threadId) {
      return entry;
    }
  }
  return undefined;
}

/** Push a message to a session's queue and wake any long-poll waiters */
function pushMessage(sessionId: string, msg: QueuedMessage): void {
  const entry = sessions.get(sessionId);
  if (!entry) return;

  // Wake any waiting long-poll requests first
  const pending = waiters.get(sessionId);
  if (pending && pending.length > 0) {
    for (const resolve of pending) {
      resolve([msg]);
    }
    waiters.delete(sessionId);
    return;
  }

  // No waiters — buffer in the queue
  entry.message_queue.push(msg);

  // Cap queue size to prevent unbounded growth
  while (entry.message_queue.length > 200) {
    entry.message_queue.shift();
  }
}

/** Drain (and return) all queued messages for a session */
function drainMessages(sessionId: string): QueuedMessage[] {
  const entry = sessions.get(sessionId);
  if (!entry) return [];
  const msgs = entry.message_queue.splice(0);
  return msgs;
}

/** Wait for messages with a timeout (long-poll) */
function waitForMessages(
  sessionId: string,
  timeoutMs: number,
): Promise<QueuedMessage[]> {
  // First check if there are already queued messages
  const immediate = drainMessages(sessionId);
  if (immediate.length > 0) {
    return Promise.resolve(immediate);
  }

  return new Promise<QueuedMessage[]>((resolve) => {
    const timer = setTimeout(() => {
      // Timeout — remove this waiter and return empty
      const list = waiters.get(sessionId);
      if (list) {
        const idx = list.indexOf(resolve);
        if (idx !== -1) list.splice(idx, 1);
        if (list.length === 0) waiters.delete(sessionId);
      }
      resolve([]);
    }, timeoutMs);

    // Register waiter
    const wrappedResolve = (msgs: QueuedMessage[]) => {
      clearTimeout(timer);
      resolve(msgs);
    };

    if (!waiters.has(sessionId)) {
      waiters.set(sessionId, []);
    }
    waiters.get(sessionId)!.push(wrappedResolve);
  });
}

// ---------------------------------------------------------------------------
// Telegram Long Polling
// ---------------------------------------------------------------------------

let pollingActive = false;
let pollOffset = 0;

async function startPolling(config: ChannelConfig): Promise<void> {
  if (!config.botToken) {
    log("warn", "TG_BOT_TOKEN not set — Telegram polling disabled");
    return;
  }

  if (!config.chatId) {
    log("error", "TG_CHAT_ID not set — Telegram polling disabled (required for security)");
    return;
  }

  pollingActive = true;
  let backoff = 1000;

  log("info", `Telegram polling started (filter: chat_id=${config.chatId}, groupMode=${config.groupMode})`);

  while (pollingActive) {
    try {
      const updates: TelegramUpdate[] = await getUpdates(
        config.botToken,
        pollOffset,
        30,
      );

      backoff = 1000;

      for (const update of updates) {
        pollOffset = update.update_id + 1;

        if (!update.message) continue;

        const msg = update.message;

        // Filter: only process messages from configured chat
        if (config.chatId && String(msg.chat.id) !== config.chatId) {
          log("debug", `Ignoring message from chat_id=${msg.chat.id} (not in allowlist)`);
          continue;
        }

        const userName = msg.from
          ? msg.from.username || `${msg.from.first_name}${msg.from.last_name ? " " + msg.from.last_name : ""}`
          : "unknown";

        const threadId = msg.message_thread_id;

        log("info", `Message from ${userName} in chat ${msg.chat.id} (thread=${threadId ?? "none"}): "${(msg.text ?? "").slice(0, 80)}"`);

        const queued: QueuedMessage = {
          message_id: msg.message_id,
          text: msg.text ?? "",
          user: userName,
          date: msg.date,
          message_thread_id: threadId,
        };

        // Route to the correct session
        if (config.groupMode && threadId) {
          const session = findSessionByTopic(threadId);
          if (session) {
            pushMessage(session.session_id, queued);
          } else {
            log("debug", `No session for thread_id=${threadId}, ignoring`);
          }
        } else if (!config.groupMode) {
          // Non-group mode: broadcast to all sessions (or first session if only one)
          if (sessions.size === 1) {
            const [onlySessionId] = sessions.keys();
            pushMessage(onlySessionId, queued);
          } else if (sessions.size > 1) {
            // In non-group mode with multiple sessions, broadcast to all
            for (const sessionId of sessions.keys()) {
              pushMessage(sessionId, { ...queued });
            }
          } else {
            log("debug", "No active sessions, message dropped");
          }
        } else {
          // Group mode but no thread_id: message in General topic
          // Route to any session that requested General (topic_thread_id=null),
          // or ignore if none.
          log("debug", `Group mode, no thread_id on message — dropped`);
        }
      }
    } catch (err) {
      if (!pollingActive) break;
      log("error", `Polling error (retry in ${backoff}ms):`, err);
      await sleep(backoff);
      backoff = Math.min(backoff * 2, 30000);
    }
  }

  log("info", "Telegram polling stopped");
}

function stopPolling(): void {
  pollingActive = false;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ---------------------------------------------------------------------------
// HTTP API
// ---------------------------------------------------------------------------

const EVENT_EMOJI: Record<string, string> = {
  error: "\u274c",
  complete: "\u2705",
  continue: "\u27a1\ufe0f",
  warning: "\u26a0\ufe0f",
  info: "\u2139\ufe0f",
  start: "\ud83d\ude80",
  max_reached: "\ud83d\uded1",
  subagent: "\ud83e\udd16",
};

function formatNotify(body: { message?: string; event_type?: string }): string {
  const message = body.message ?? "(empty)";
  const eventType = body.event_type ?? "info";
  const emoji = EVENT_EMOJI[eventType] ?? EVENT_EMOJI["info"];
  return `${emoji} [${eventType}] ${message}`;
}

async function readBody(req: IncomingMessage): Promise<string> {
  let raw = "";
  for await (const chunk of req) {
    raw += chunk;
  }
  return raw;
}

function jsonResponse(res: ServerResponse, status: number, data: unknown): void {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(data));
}

function startHttpServer(config: ChannelConfig): Promise<void> {
  return new Promise((resolve, reject) => {
    const httpServer = createServer(
      async (req: IncomingMessage, res: ServerResponse) => {
        const url = req.url ?? "/";
        const method = req.method ?? "GET";

        try {
          await handleRequest(config, method, url, req, res);
        } catch (err) {
          log("error", `HTTP handler error: ${method} ${url}`, err);
          jsonResponse(res, 500, { ok: false, error: "internal server error" });
        }
      },
    );

    // Remove stale socket file if it exists
    if (existsSync(config.socketPath)) {
      try {
        unlinkSync(config.socketPath);
        log("info", `Removed stale socket: ${config.socketPath}`);
      } catch (err) {
        log("error", `Failed to remove stale socket: ${config.socketPath}`, err);
        reject(err);
        return;
      }
    }

    // Ensure parent directory exists
    mkdirSync(dirname(config.socketPath), { recursive: true });

    httpServer.on("error", (err) => {
      log("error", "HTTP server error:", err);
      reject(err);
    });

    httpServer.listen(config.socketPath, () => {
      log("info", `HTTP server listening on unix:${config.socketPath}`);
      resolve();
    });

    // Graceful shutdown
    const shutdown = (): void => {
      log("info", "Shutting down HTTP server...");
      httpServer.close();
      // Clean up socket file
      try {
        if (existsSync(config.socketPath)) {
          unlinkSync(config.socketPath);
        }
      } catch {
        // ignore
      }
    };
    process.on("SIGINT", shutdown);
    process.on("SIGTERM", shutdown);
  });
}

async function handleRequest(
  config: ChannelConfig,
  method: string,
  url: string,
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  // ---- GET /health ----
  if (method === "GET" && url === "/health") {
    jsonResponse(res, 200, {
      ok: true,
      sessions: sessions.size,
      polling: pollingActive,
      groupMode: config.groupMode,
    });
    return;
  }

  // ---- POST /notify ----
  if (method === "POST" && url === "/notify") {
    const raw = await readBody(req);
    let body: { message?: string; event_type?: string; session_id?: string };
    try {
      body = JSON.parse(raw);
    } catch {
      jsonResponse(res, 400, { ok: false, error: "invalid JSON" });
      return;
    }

    const formatted = formatNotify(body);
    log("http", `POST /notify -> "${formatted.slice(0, 80)}"`);

    if (config.botToken && config.chatId) {
      // Route to specific session's topic if session_id provided
      let threadId: number | undefined;
      if (body.session_id && config.groupMode) {
        const entry = sessions.get(body.session_id);
        if (entry?.topic_thread_id) {
          threadId = entry.topic_thread_id;
        }
      }

      await sendMessage(config.botToken, config.chatId, formatted, {
        message_thread_id: threadId,
      });
      jsonResponse(res, 200, { ok: true, sent: true });
    } else {
      log("warn", "Cannot send notification: TG_BOT_TOKEN or TG_CHAT_ID not configured");
      jsonResponse(res, 200, { ok: true, sent: false, reason: "bot not configured" });
    }
    return;
  }

  // ---- POST /sessions ----
  if (method === "POST" && url === "/sessions") {
    const raw = await readBody(req);
    let body: { session_id?: string; name?: string };
    try {
      body = JSON.parse(raw);
    } catch {
      jsonResponse(res, 400, { ok: false, error: "invalid JSON" });
      return;
    }

    if (!body.session_id) {
      jsonResponse(res, 400, { ok: false, error: "session_id required" });
      return;
    }

    const entry = await registerSession(config, body.session_id, body.name);
    jsonResponse(res, 200, {
      ok: true,
      session_id: entry.session_id,
      topic_thread_id: entry.topic_thread_id,
      name: entry.name,
      created_at: entry.created_at,
    });
    return;
  }

  // ---- GET /sessions ----
  if (method === "GET" && url === "/sessions") {
    const list = Array.from(sessions.values()).map((s) => ({
      session_id: s.session_id,
      name: s.name,
      topic_thread_id: s.topic_thread_id,
      created_at: s.created_at,
      queued_messages: s.message_queue.length,
    }));
    jsonResponse(res, 200, { ok: true, sessions: list });
    return;
  }

  // ---- Routes with session_id path param ----
  const sessionMatch = url.match(/^\/sessions\/([^/?]+)(\/.*)?(\?.*)?$/);
  if (sessionMatch) {
    const sessionId = decodeURIComponent(sessionMatch[1]);
    const subPath = sessionMatch[2] ?? "";
    const queryString = sessionMatch[3] ?? "";

    // ---- DELETE /sessions/:id ----
    if (method === "DELETE" && !subPath) {
      const removed = await unregisterSession(config, sessionId);
      if (removed) {
        jsonResponse(res, 200, { ok: true });
      } else {
        jsonResponse(res, 404, { ok: false, error: "session not found" });
      }
      return;
    }

    // ---- GET /sessions/:id/messages?timeout=30 ----
    if (method === "GET" && subPath === "/messages") {
      if (!sessions.has(sessionId)) {
        jsonResponse(res, 404, { ok: false, error: "session not found" });
        return;
      }

      const params = new URLSearchParams(queryString.replace(/^\?/, ""));
      const timeout = Math.min(
        Math.max(parseInt(params.get("timeout") ?? "30", 10) || 30, 1),
        60,
      );

      const messages = await waitForMessages(sessionId, timeout * 1000);
      jsonResponse(res, 200, { ok: true, messages });
      return;
    }

    // ---- POST /sessions/:id/reply ----
    if (method === "POST" && subPath === "/reply") {
      const entry = sessions.get(sessionId);
      if (!entry) {
        jsonResponse(res, 404, { ok: false, error: "session not found" });
        return;
      }

      const raw = await readBody(req);
      let body: { text?: string; reply_to?: number };
      try {
        body = JSON.parse(raw);
      } catch {
        jsonResponse(res, 400, { ok: false, error: "invalid JSON" });
        return;
      }

      if (!body.text) {
        jsonResponse(res, 400, { ok: false, error: "text required" });
        return;
      }

      if (!config.botToken || !config.chatId) {
        jsonResponse(res, 500, { ok: false, error: "bot not configured" });
        return;
      }

      const msg = await sendMessage(config.botToken, config.chatId, body.text, {
        message_thread_id: entry.topic_thread_id ?? undefined,
        reply_to_message_id: body.reply_to,
      });

      if (msg) {
        jsonResponse(res, 200, {
          ok: true,
          message_id: msg.message_id,
        });
      } else {
        jsonResponse(res, 500, { ok: false, error: "failed to send message" });
      }
      return;
    }
  }

  // ---- 404 ----
  jsonResponse(res, 404, { error: "not found" });
}

// ---------------------------------------------------------------------------
// PID file management
// ---------------------------------------------------------------------------

function writePidFile(): void {
  mkdirSync(dirname(PID_FILE), { recursive: true });
  writeFileSync(PID_FILE, String(process.pid));
  log("info", `PID file written: ${PID_FILE} (pid=${process.pid})`);
}

function removePidFile(): void {
  try {
    if (existsSync(PID_FILE)) {
      const storedPid = readFileSync(PID_FILE, "utf-8").trim();
      if (storedPid === String(process.pid)) {
        unlinkSync(PID_FILE);
        log("info", "PID file removed");
      }
    }
  } catch {
    // ignore
  }
}

/**
 * Check if another daemon is already running based on the PID file.
 * Returns the running PID, or null if no daemon is running.
 */
function checkExistingDaemon(): number | null {
  if (!existsSync(PID_FILE)) return null;

  try {
    const storedPid = parseInt(readFileSync(PID_FILE, "utf-8").trim(), 10);
    if (isNaN(storedPid)) return null;

    // Check if process is actually running
    process.kill(storedPid, 0); // signal 0 = check existence
    return storedPid;
  } catch {
    // Process not running — stale PID file
    log("info", "Stale PID file found, removing");
    try {
      unlinkSync(PID_FILE);
    } catch {
      // ignore
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  const config = loadConfig();

  log("info", "Auto-Claude Channel Daemon starting...");
  log("info", `  bot_token:  ${config.botToken ? "configured" : "NOT SET"}`);
  log("info", `  chat_id:    ${config.chatId ?? "NOT SET"}`);
  log("info", `  socket:     ${config.socketPath}`);
  log("info", `  groupMode:  ${config.groupMode}`);

  // Check if another daemon is already running
  const existingPid = checkExistingDaemon();
  if (existingPid) {
    log("error", `Another daemon is already running (pid=${existingPid}). Exiting.`);
    process.exit(1);
  }

  // Write PID file
  writePidFile();

  // Ensure state directory exists
  mkdirSync(STATE_DIR, { recursive: true });

  // Load persisted sessions from previous run
  loadPersistedSessions();

  // Start HTTP server
  await startHttpServer(config);

  // Start Telegram polling in background
  startPolling(config).catch((err) => {
    log("error", "Polling loop exited with error:", err);
  });

  // Graceful shutdown
  const gracefulShutdown = async (signal: string): Promise<void> => {
    log("info", `${signal} received, shutting down...`);
    stopPolling();
    persistSessions();
    removePidFile();
    // Give a moment for cleanup
    setTimeout(() => process.exit(0), 500);
  };

  process.on("SIGINT", () => { gracefulShutdown("SIGINT"); });
  process.on("SIGTERM", () => { gracefulShutdown("SIGTERM"); });

  log("info", "Daemon is ready");
}

main().catch((err) => {
  log("fatal", "Daemon startup failed:", err);
  removePidFile();
  process.exit(1);
});
