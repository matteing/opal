#!/usr/bin/env node
import { render } from "ink";
import React from "react";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { App } from "./app.js";
import type { SessionOptions } from "./sdk/session.js";

// --- Parse CLI args ---

const argv = await yargs(hideBin(process.argv))
  .scriptName("opal")
  .usage("Usage: $0 [prompt] [options]")
  .command(["$0 [prompt]"], "Start interactive TUI (default)", (y) =>
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
      .option("no-tui", {
        type: "boolean",
        default: false,
        describe: "Headless mode: print response to stdout and exit",
      })
      .option("version", {
        type: "boolean",
        default: false,
        describe: "Print version information and exit",
      }),
  )
  .command("auth <action>", "Manage authentication", (y) =>
    y.positional("action", {
      type: "string",
      choices: ["login", "status"] as const,
      describe: "Auth action",
      demandOption: true,
    }),
  )
  .command("session <action> [id]", "Manage saved sessions", (y) =>
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
  )
  .command("doctor", "Check installation health")
  .strict()
  .help()
  .parse();

// --- Route to subcommands ---

const command = (argv._ as string[])[0];

if (command === "auth") {
  const action = argv.action as string;
  if (action === "login") {
    const { runAuthLogin } = await import("./commands/auth.js");
    await runAuthLogin();
  } else if (action === "status") {
    const { runAuthStatus } = await import("./commands/auth.js");
    await runAuthStatus();
  }
} else if (command === "session") {
  const action = argv.action as string;
  const id = argv.id as string | undefined;

  if (action === "list") {
    const { runSessionList } = await import("./commands/session.js");
    await runSessionList();
  } else if (action === "show") {
    if (!id) {
      console.error("Usage: opal session show <id>");
      process.exitCode = 1;
    } else {
      const { runSessionShow } = await import("./commands/session.js");
      await runSessionShow(id);
    }
  } else if (action === "delete") {
    if (!id) {
      console.error("Usage: opal session delete <id>");
      process.exitCode = 1;
    } else {
      const { runSessionDelete } = await import("./commands/session.js");
      await runSessionDelete(id);
    }
  }
} else if (command === "doctor") {
  const { runDoctor } = await import("./commands/doctor.js");
  await runDoctor();
} else {
  // Default command — TUI or headless

  // Handle --version
  if (argv.version) {
    const { runVersion } = await import("./commands/version.js");
    await runVersion();
  } else if (argv.noTui && argv.prompt) {
    // Headless mode
    const model = argv.model
      ? (() => {
          const [provider, ...idParts] = (argv.model as string).split("/");
          const id = idParts.join("/");
          return provider && id ? { provider, id } : undefined;
        })()
      : undefined;

    const { runHeadless } = await import("./commands/headless.js");
    await runHeadless(argv.prompt as string, {
      model,
      workingDir:
        (argv.workingDir as string | undefined) ??
        process.env["OPAL_CWD"] ??
        process.env["INIT_CWD"] ??
        process.cwd(),
      autoConfirm: argv.autoConfirm as boolean,
    });
  } else {
    // Interactive TUI
    const opts: SessionOptions = {};

    if (argv.model) {
      const [provider, ...idParts] = (argv.model as string).split("/");
      const id = idParts.join("/");
      if (provider && id) {
        opts.model = { provider, id };
      }
    }

    if (argv.workingDir) opts.workingDir = argv.workingDir as string;
    if (argv.session) opts.sessionId = argv.session as string;
    if (argv.verbose) opts.verbose = true;
    if (argv.autoConfirm) opts.autoConfirm = true;
    if (argv.debug) {
      opts.features = { debug: true } as SessionOptions["features"];
    }

    if (argv.expose) {
      const expose = argv.expose as string;
      const hashIdx = expose.indexOf("#");
      if (hashIdx >= 0) {
        opts.sname = expose.slice(0, hashIdx);
        opts.cookie = expose.slice(hashIdx + 1);
      } else {
        opts.sname = expose;
      }
    }

    if (!opts.workingDir) {
      opts.workingDir = process.env["OPAL_CWD"] || process.env["INIT_CWD"] || process.cwd();
    }

    // Clear the screen so the app starts with a fresh viewport.
    process.stdout.write("\x1b[2J\x1b[H");

    // Track the session ID so we can print a resume hint after exit.
    let exitSessionId: string | undefined;

    const instance = render(
      React.createElement(App, {
        sessionOpts: opts,
        initialPrompt: (argv.prompt as string | undefined) || undefined,
        onSessionId: (id: string) => {
          exitSessionId = id;
        },
      }),
    );

    instance
      .waitUntilExit()
      .then(() => {
        if (exitSessionId) {
          console.log(`\nResume this session: opal --session "${exitSessionId}"\n`);
        }
      })
      .catch((err: unknown) => {
        process.exitCode = 1;
        if (err instanceof Error && err.message) {
          process.stderr.write(err.message + "\n");
        }
      });
  }
}
