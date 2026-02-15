// Extracted from hooks/use-opal.ts for testability
import type { SubAgent } from "./reducers.js";

/** Convert an unknown error value to a human-readable string. */
export function errorMessage(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

/** Parse a slash-command string into command name and argument. */
export function parseCommand(input: string): { cmd: string; arg: string } {
  const parts = input.trim().slice(1).split(/\s+/);
  const cmd = parts[0]?.toLowerCase() ?? "";
  const arg = parts.slice(1).join(" ");
  return { cmd, arg };
}

/** Format a model for display: `provider:id` for non-copilot, just `id` for copilot. */
export function buildDisplaySpec(model: { id: string; provider: string }): string {
  return model.provider !== "copilot" ? `${model.provider}:${model.id}` : model.id;
}

/** Normalize model spec: convert `/` separator to `:`. */
export function normalizeModelSpec(arg: string): string {
  return arg.includes("/") ? arg.replace("/", ":") : arg;
}

/** Build the static help message. */
export function buildHelpMessage(): string {
  return (
    "**Commands:**\n" +
    "  `/model`                  — show current model\n" +
    "  `/model <provider:id>`    — switch model (e.g. `anthropic:claude-sonnet-4`)\n" +
    "  `/models`                 — select model interactively\n" +
    "  `/agents`                 — list active sub-agents\n" +
    "  `/agents <n|main>`        — switch view to sub-agent or main\n" +
    "  `/opal`                   — open configuration menu\n" +
    "  `/compact`                — compact conversation history\n" +
    "  `/help`                   — show this help"
  );
}

/** Build a formatted sub-agent list message. Returns null if no sub-agents. */
export function buildAgentListMessage(subs: SubAgent[], activeTab: string): string | null {
  if (subs.length === 0) return null;
  const lines = subs.map(
    (sub, i) =>
      `  ${i + 1}. **${sub.label || sub.sessionId.slice(0, 8)}** — ${sub.model} · ${sub.toolCount} tools · ${sub.isRunning ? "running" : "done"}`,
  );
  const viewing =
    activeTab !== "main"
      ? `\nCurrently viewing: **${subs.find((s) => s.sessionId === activeTab)?.label || activeTab}**. Use \`/agents main\` to return.`
      : "";
  return `**Active sub-agents:**\n${lines.join("\n")}${viewing}\n\nUse \`/agents <number>\` to view, \`/agents main\` to return.`;
}
