// Telegram Bot API helpers — raw fetch, no external deps.

const API_BASE = "https://api.telegram.org";

/** Subset of Telegram User object */
export interface TelegramUser {
  id: number;
  is_bot: boolean;
  first_name: string;
  last_name?: string;
  username?: string;
}

/** Subset of Telegram Message object */
export interface TelegramMessage {
  message_id: number;
  from?: TelegramUser;
  chat: { id: number; type: string; title?: string };
  date: number;
  text?: string;
  message_thread_id?: number;
  is_topic_message?: boolean;
}

/** Subset of Telegram Update object */
export interface TelegramUpdate {
  update_id: number;
  message?: TelegramMessage;
}

/** Forum topic returned by createForumTopic */
export interface ForumTopic {
  message_thread_id: number;
  name: string;
  icon_color?: number;
}

interface SendMessageOptions {
  reply_to_message_id?: number;
  parse_mode?: string;
  message_thread_id?: number;
}

/**
 * Send a text message via Telegram Bot API.
 * Returns the sent Message object on success, or null on failure.
 */
export async function sendMessage(
  token: string,
  chatId: string | number,
  text: string,
  options?: SendMessageOptions,
): Promise<TelegramMessage | null> {
  const body: Record<string, unknown> = {
    chat_id: chatId,
    text,
  };
  if (options?.reply_to_message_id) {
    body["reply_to_message_id"] = options.reply_to_message_id;
  }
  if (options?.parse_mode) {
    body["parse_mode"] = options.parse_mode;
  }
  if (options?.message_thread_id) {
    body["message_thread_id"] = options.message_thread_id;
  }

  try {
    const resp = await fetch(`${API_BASE}/bot${token}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const data = (await resp.json()) as { ok: boolean; result?: TelegramMessage; description?: string };
    if (!data.ok) {
      console.error(`[telegram] sendMessage failed: ${data.description}`);
      return null;
    }
    return data.result ?? null;
  } catch (err) {
    console.error(`[telegram] sendMessage error:`, err);
    return null;
  }
}

/**
 * Long-poll for updates from Telegram Bot API.
 * Returns an array of Update objects (may be empty on timeout).
 */
export async function getUpdates(
  token: string,
  offset: number,
  timeout: number = 30,
): Promise<TelegramUpdate[]> {
  const params = new URLSearchParams({
    offset: String(offset),
    timeout: String(timeout),
    allowed_updates: JSON.stringify(["message"]),
  });

  const resp = await fetch(
    `${API_BASE}/bot${token}/getUpdates?${params.toString()}`,
    { signal: AbortSignal.timeout((timeout + 5) * 1000) },
  );
  const data = (await resp.json()) as { ok: boolean; result?: TelegramUpdate[]; description?: string };
  if (!data.ok) {
    throw new Error(`getUpdates failed: ${data.description}`);
  }
  return data.result ?? [];
}

// ---------------------------------------------------------------------------
// Forum Topic APIs (for supergroup with Topics enabled)
// ---------------------------------------------------------------------------

/**
 * Create a forum topic in a supergroup.
 * The bot must be admin with can_manage_topics permission.
 * Returns the created topic, or null on failure.
 */
export async function createForumTopic(
  token: string,
  chatId: string | number,
  name: string,
  iconColor?: number,
): Promise<ForumTopic | null> {
  const body: Record<string, unknown> = {
    chat_id: chatId,
    name,
  };
  if (iconColor !== undefined) {
    body["icon_color"] = iconColor;
  }

  try {
    const resp = await fetch(`${API_BASE}/bot${token}/createForumTopic`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const data = (await resp.json()) as { ok: boolean; result?: ForumTopic; description?: string };
    if (!data.ok) {
      console.error(`[telegram] createForumTopic failed: ${data.description}`);
      return null;
    }
    return data.result ?? null;
  } catch (err) {
    console.error(`[telegram] createForumTopic error:`, err);
    return null;
  }
}

/**
 * Close (archive) a forum topic in a supergroup.
 * Returns true on success, false on failure.
 */
export async function closeForumTopic(
  token: string,
  chatId: string | number,
  messageThreadId: number,
): Promise<boolean> {
  try {
    const resp = await fetch(`${API_BASE}/bot${token}/closeForumTopic`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        chat_id: chatId,
        message_thread_id: messageThreadId,
      }),
    });
    const data = (await resp.json()) as { ok: boolean; description?: string };
    if (!data.ok) {
      console.error(`[telegram] closeForumTopic failed: ${data.description}`);
      return false;
    }
    return true;
  } catch (err) {
    console.error(`[telegram] closeForumTopic error:`, err);
    return false;
  }
}

/**
 * Edit (rename) a forum topic in a supergroup.
 * Returns true on success, false on failure.
 */
export async function editForumTopic(
  token: string,
  chatId: string | number,
  messageThreadId: number,
  name: string,
): Promise<boolean> {
  try {
    const resp = await fetch(`${API_BASE}/bot${token}/editForumTopic`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        chat_id: chatId,
        message_thread_id: messageThreadId,
        name,
      }),
    });
    const data = (await resp.json()) as { ok: boolean; description?: string };
    if (!data.ok) {
      console.error(`[telegram] editForumTopic failed: ${data.description}`);
      return false;
    }
    return true;
  } catch (err) {
    console.error(`[telegram] editForumTopic error:`, err);
    return false;
  }
}
