import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

export interface ChannelConfig {
  botToken: string | null;
  chatId: string | null;
  /** Unix domain socket path for daemon communication */
  socketPath: string;
  /** True when chatId is a supergroup (starts with -100). Topics mode. */
  groupMode: boolean;
}

/** Default locations under ~/.sleepship */
export const SLEEPSHIP_DIR = join(homedir(), ".sleepship");
export const DEFAULT_SOCKET_PATH = join(SLEEPSHIP_DIR, "channel.sock");
export const STATE_DIR = join(SLEEPSHIP_DIR, "state");
export const PID_FILE = join(SLEEPSHIP_DIR, "channel.pid");
export const SESSIONS_FILE = join(STATE_DIR, "channel-sessions.json");

const CONFIG_PATH = join(SLEEPSHIP_DIR, "config.env");

/**
 * Parse a config.env file (KEY=VALUE lines).
 * Handles comments, empty lines, and quoted values.
 */
function parseEnvFile(filePath: string): Record<string, string> {
  const result: Record<string, string> = {};
  if (!existsSync(filePath)) return result;

  const content = readFileSync(filePath, "utf-8");
  for (const raw of content.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;

    const eqIndex = line.indexOf("=");
    if (eqIndex === -1) continue;

    const key = line.slice(0, eqIndex).trim();
    let value = line.slice(eqIndex + 1).trim();

    // Strip surrounding quotes (single or double)
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }

    // Strip inline comments (only outside quotes)
    const commentIndex = value.indexOf(" #");
    if (commentIndex !== -1) {
      value = value.slice(0, commentIndex).trim();
    }

    result[key] = value;
  }
  return result;
}

/**
 * Load configuration from environment variables and ~/.sleepship/config.env.
 * Environment variables take precedence over config file values.
 */
export function loadConfig(): ChannelConfig {
  const fileVars = parseEnvFile(CONFIG_PATH);

  const botToken =
    process.env["TG_BOT_TOKEN"] || fileVars["TG_BOT_TOKEN"] || null;
  const chatId =
    process.env["TG_CHAT_ID"] || fileVars["TG_CHAT_ID"] || null;

  // Socket path: env > config file > default
  let socketPath =
    process.env["CHANNEL_SOCKET"] || fileVars["CHANNEL_SOCKET"] || "";
  if (socketPath.startsWith("~")) {
    socketPath = socketPath.replace("~", homedir());
  }
  if (!socketPath) {
    socketPath = DEFAULT_SOCKET_PATH;
  }

  // Detect group/topics mode: supergroup IDs start with -100
  const groupMode = chatId ? chatId.startsWith("-100") : false;

  return { botToken, chatId, socketPath, groupMode };
}
