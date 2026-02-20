#!/usr/bin/env node
import yargs, { type Argv, type ArgumentsCamelCase } from "yargs";
import { hideBin } from "yargs/helpers";
import { parseModel } from "./lib/models.js";

/** Resolve working directory from flag → env → cwd. */
function resolveWorkingDir(flag?: string): string {
  return flag ?? process.env["OPAL_CWD"] ?? process.env["INIT_CWD"] ?? process.cwd();
}

/** TUI option builder — also used to derive the `TuiArgs` type. */
const tuiBuilder = (y: Argv) =>
  y
    .positional("prompt", {
      type: "string",
      describe: "Initial prompt to send on startup",
    })
    .option("model", {
      type: "string",
      describe: "Model to use (e.g. copilot/claude-sonnet-4)",
    })
    .option("working-dir", {
      alias: "C",
      type: "string",
      describe: "Working directory",
    })
    .option("session", {
      alias: "s",
      type: "string",
      describe: "Resume a previous session by ID",
    })
    .option("verbose", {
      alias: "v",
      type: "boolean",
      default: false,
      describe: "Verbose output",
    })
    .option("auto-confirm", {
      type: "boolean",
      default: false,
      describe: "Auto-confirm all tool executions",
    })
    .option("debug", {
      type: "boolean",
      default: false,
      describe: "Enable debug feature/tools for this session",
    })
    .option("expose", {
      type: "string",
      describe: "Expose instance for remote debugging (name or name#cookie)",
    })
    .option("version", {
      type: "boolean",
      default: false,
      describe: "Print version information and exit",
    });

/** Args type inferred from the TUI yargs builder. */
type TuiBuilderResult = ReturnType<typeof tuiBuilder>;
export type TuiArgs = ArgumentsCamelCase<TuiBuilderResult extends Argv<infer U> ? U : never>;

await yargs(hideBin(process.argv))
  .scriptName("opal")
  .usage("Usage: $0 [prompt] [options]")

  // --- Default: TUI or headless ---
  .command(["$0 [prompt]"], "Start interactive TUI (default)", tuiBuilder, async (argv) => {
    if (argv.version) {
      const { runVersion } = await import("./commands/version.js");
      return runVersion();
    }

    const { launchTui } = await import("./commands/tui.js");
    return launchTui({
      ...argv,
      workingDir: resolveWorkingDir(argv.workingDir),
    });
  })

  // --- Session management ---
  .command(
    "session <action> [id]",
    "Manage saved sessions",
    (y) =>
      y
        .positional("action", {
          type: "string",
          choices: ["list", "show", "delete"] as const,
          describe: "Session action",
          demandOption: true,
        })
        .positional("id", {
          type: "string",
          describe: "Session ID (for show/delete)",
        }),
    async (argv) => {
      switch (argv.action) {
        case "list": {
          const { runSessionList } = await import("./commands/session.js");
          return runSessionList();
        }
        case "show": {
          if (!argv.id) {
            console.error("Usage: opal session show <id>");
            process.exitCode = 1;
            return;
          }
          const { runSessionShow } = await import("./commands/session.js");
          return runSessionShow(argv.id);
        }
        case "delete": {
          if (!argv.id) {
            console.error("Usage: opal session delete <id>");
            process.exitCode = 1;
            return;
          }
          const { runSessionDelete } = await import("./commands/session.js");
          return runSessionDelete(argv.id);
        }
      }
    },
  )

  .strict()
  .help()
  .parseAsync();
