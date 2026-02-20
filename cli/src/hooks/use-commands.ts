/**
 * useCommands — declarative slash-command registry and executor.
 *
 * Define commands as data, register them with the hook, and call `run`
 * with user input. Parsing, matching, help generation, and error handling
 * are built in.
 *
 * @example
 * ```tsx
 * function App() {
 *   const { session } = useSession({ workingDir: "." });
 *   const models = useModels(session);
 *
 *   const commands = useCommands({
 *     compact: {
 *       description: "Compact conversation history",
 *       execute: () => session?.compact(),
 *     },
 *     model: {
 *       description: "Show or set current model",
 *       args: "[provider:id]",
 *       execute: ({ arg }) => {
 *         if (!arg) return `Current: ${models.current?.displayName}`;
 *         models.select(arg);
 *       },
 *     },
 *   });
 *
 *   // In input handler:
 *   if (input.startsWith("/")) {
 *     const result = commands.run(input);
 *     if (result.message) addSystemMessage(result.message);
 *   }
 * }
 * ```
 *
 * @module
 */

import { useMemo, useCallback, useRef } from "react";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/** Context passed to a command's execute function. */
export interface CommandContext {
  /** The raw argument string after the command name (empty if none). */
  readonly arg: string;
}

/** Result returned from executing a command. */
export interface CommandResult {
  /** Whether the command was found and executed. */
  readonly ok: boolean;
  /** Optional message to display to the user (info, error, etc). */
  readonly message?: string;
}

/** Definition of a single slash command. */
export interface CommandDef {
  /** Human-readable description shown in `/help`. */
  readonly description: string;
  /** Argument placeholder for help display (e.g. `"<provider:id>"`, `"[n|main]"`). */
  readonly args?: string;
  /**
   * Execute the command. May return:
   * - `void` / `undefined` — success, no message
   * - `string` — success message to display
   * - `Promise<string | void>` — async variant
   */
  readonly execute: (ctx: CommandContext) => string | void | Promise<string | void>;
}

/** Map of command names to their definitions. */
export type CommandRegistry = Record<string, CommandDef>;

/** Metadata about a registered command (for rendering help, completions). */
export interface CommandInfo {
  readonly name: string;
  readonly description: string;
  readonly args?: string;
  /** Full usage string: `/name [args]`. */
  readonly usage: string;
}

/** Return type of the useCommands hook. */
export interface UseCommandsReturn {
  /** Run a slash-command input string (e.g. `"/model gpt-4"`). */
  readonly run: (input: string) => CommandResult | Promise<CommandResult>;
  /** Whether the input string is a slash command. */
  readonly isCommand: (input: string) => boolean;
  /** Sorted list of registered commands (for help, completion). */
  readonly commands: readonly CommandInfo[];
  /** Formatted help text for all registered commands. */
  readonly helpText: string;
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

function parseInput(input: string): { cmd: string; arg: string } {
  const trimmed = input.trim();
  if (!trimmed.startsWith("/")) return { cmd: "", arg: "" };
  const parts = trimmed.slice(1).split(/\s+/);
  const cmd = parts[0]?.toLowerCase() ?? "";
  const arg = parts.slice(1).join(" ");
  return { cmd, arg };
}

// ---------------------------------------------------------------------------
// Hook
// ---------------------------------------------------------------------------

/**
 * Declarative slash-command registry.
 *
 * Pass a record of command definitions — the hook provides a stable
 * `run` function, command metadata for help/completion, and pre-formatted
 * help text.
 *
 * Command definitions are captured by ref so they can close over
 * current state without causing the hook to re-render.
 */
export function useCommands(registry: CommandRegistry): UseCommandsReturn {
  // Keep registry in a ref so execute closures are always fresh.
  const registryRef = useRef(registry);
  registryRef.current = registry;

  // Stable sorted command metadata (only recomputed when keys change).
  const commandKeys = Object.keys(registry).sort().join(",");
  const commands = useMemo<readonly CommandInfo[]>(() => {
    const reg = registryRef.current;
    return Object.keys(reg)
      .sort()
      .map((name) => {
        const def = reg[name];
        const usage = def.args ? `/${name} ${def.args}` : `/${name}`;
        return { name, description: def.description, args: def.args, usage };
      });
  }, [commandKeys]); // eslint-disable-line react-hooks/exhaustive-deps

  const helpText = useMemo(() => {
    const maxUsage = Math.max(...commands.map((c) => c.usage.length), 0);
    const lines = commands.map((c) => `  ${c.usage.padEnd(maxUsage + 2)} — ${c.description}`);
    return `**Commands:**\n${lines.join("\n")}`;
  }, [commands]);

  const isCommand = useCallback((input: string): boolean => {
    return input.trimStart().startsWith("/");
  }, []);

  const run = useCallback((input: string): CommandResult | Promise<CommandResult> => {
    const { cmd, arg } = parseInput(input);

    if (!cmd) {
      return { ok: false, message: "Empty command." };
    }

    const def = registryRef.current[cmd];
    if (!def) {
      return {
        ok: false,
        message: `Unknown command: \`/${cmd}\`. Type \`/help\` for available commands.`,
      };
    }

    try {
      const result = def.execute({ arg });

      // Sync path
      if (typeof result === "string") {
        return { ok: true, message: result };
      }
      if (result == null) {
        return { ok: true };
      }

      // Async path
      return result.then(
        (msg) => (msg ? { ok: true, message: msg } : { ok: true }),
        (err: unknown) => ({
          ok: false,
          message: `Error: ${err instanceof Error ? err.message : String(err)}`,
        }),
      );
    } catch (err: unknown) {
      return {
        ok: false,
        message: `Error: ${err instanceof Error ? err.message : String(err)}`,
      };
    }
  }, []);

  return { run, isCommand, commands, helpText };
}
