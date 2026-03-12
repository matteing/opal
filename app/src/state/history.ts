/**
 * Converts session/history messages into renderable TimelineEntry values.
 *
 * When resuming a saved session, the server returns the full message list
 * (system, user, assistant, tool_call, tool_result). This function walks
 * that list and produces the same timeline shape that live streaming would,
 * so the UI renders resumed sessions identically to live ones.
 *
 * Tool results are matched to their corresponding tool entries by callId
 * (scanning backwards, since results follow their calls).
 */

import type { HistoryMessage } from "../sdk/bridge.js";
import type { TimelineEntry } from "./types.js";

export function historyToTimeline(messages: HistoryMessage[]): TimelineEntry[] {
  const entries: TimelineEntry[] = [];

  for (const msg of messages) {
    switch (msg.role) {
      case "user":
        if (msg.content) {
          entries.push({ type: "user", text: msg.content });
        }
        break;

      case "assistant":
        if (msg.content) {
          entries.push({
            type: "assistant",
            text: msg.content,
            isStreaming: false,
          });
        }
        if (msg.toolCalls) {
          for (const tc of msg.toolCalls) {
            entries.push({
              type: "tool",
              name: tc.name,
              callId: tc.callId,
              args: tc.arguments,
              output: null,
              status: "done",
            });
          }
        }
        break;

      case "tool_result":
        // Walk backwards to find the matching tool entry by callId
        if (msg.callId) {
          for (let i = entries.length - 1; i >= 0; i--) {
            const e = entries[i];
            if (e.type === "tool" && e.callId === msg.callId) {
              entries[i] = { ...e, output: msg.content ?? null };
              break;
            }
          }
        }
        break;

      // system messages, compaction summaries, etc. are not rendered
    }
  }

  return entries;
}

/**
 * Derive a session title from the first user message.
 * Takes the first line, truncated to 50 chars. No LLM call needed.
 */
export function autoTitle(text: string): string {
  const firstLine = text.split("\n")[0] ?? text;
  return firstLine.length > 50 ? firstLine.slice(0, 47) + "…" : firstLine;
}
