import fs from "node:fs";
import path from "node:path";

const JOURNAL_DIR = "/root/clawd/journal";

function ensureDir(dir: string): void {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
}

function sanitizeKey(key: string): string {
  return key.replace(/[^a-zA-Z0-9_\-.:]/g, "_");
}

function appendEntry(sessionKey: string, entry: Record<string, unknown>): void {
  ensureDir(JOURNAL_DIR);
  const file = path.join(JOURNAL_DIR, `${sanitizeKey(sessionKey)}.jsonl`);
  const line = JSON.stringify({ ...entry, ts: Date.now() });
  fs.appendFileSync(file, line + "\n", "utf-8");
}

function extractAssistantText(messages: unknown[]): string | null {
  // Walk backwards to find the last assistant message
  for (let i = messages.length - 1; i >= 0; i--) {
    const msg = messages[i] as Record<string, unknown> | undefined;
    if (!msg || msg.role !== "assistant") continue;

    const content = msg.content;
    if (typeof content === "string") return content;
    if (Array.isArray(content)) {
      const texts: string[] = [];
      for (const block of content) {
        const b = block as Record<string, unknown>;
        if (b.type === "text" && typeof b.text === "string") {
          texts.push(b.text);
        }
      }
      if (texts.length > 0) return texts.join("\n");
    }
    return null;
  }
  return null;
}

// Using `any` for the api parameter since we can't import OpenClawPluginApi
// without a direct dependency on openclaw internals. The plugin loader calls
// register(api) with the correct type at runtime.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export default function register(api: any) {
  // Log every inbound user message
  api.on(
    "message_received",
    (
      event: { from: string; content: string; timestamp?: number; metadata?: Record<string, unknown> },
      ctx: { channelId: string; accountId?: string; conversationId?: string },
    ) => {
      const key = ctx.conversationId || ctx.channelId || "unknown";
      appendEntry(key, {
        role: "user",
        from: event.from,
        text: event.content,
        channel: ctx.channelId,
      });
    },
  );

  // After each LLM turn, extract and log the assistant reply
  api.on(
    "agent_end",
    (
      event: { messages: unknown[]; success: boolean; error?: string; durationMs?: number },
      ctx: { agentId?: string; sessionKey?: string; workspaceDir?: string },
    ) => {
      const key = ctx.sessionKey || ctx.agentId || "unknown";
      const text = extractAssistantText(event.messages);
      if (text) {
        appendEntry(key, {
          role: "assistant",
          text,
          success: event.success,
          durationMs: event.durationMs,
        });
      }
    },
  );
}
