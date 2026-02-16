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
  .usage("Usage: $0 [options]")
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
  .strict()
  .help()
  .version(false)
  .parse();

const opts: SessionOptions = {};

if (argv.model) {
  const [provider, ...idParts] = argv.model.split("/");
  const id = idParts.join("/");
  if (provider && id) {
    opts.model = { provider, id };
  }
}

if (argv.workingDir) opts.workingDir = argv.workingDir;
if (argv.session) opts.sessionId = argv.session;
if (argv.verbose) opts.verbose = true;
if (argv.autoConfirm) opts.autoConfirm = true;
if (argv.debug) {
  opts.features = { debug: true } as SessionOptions["features"];
}

if (!opts.workingDir) {
  // INIT_CWD is set cross-platform by npm/pnpm to the original working directory.
  // OPAL_CWD is kept as a manual override.
  opts.workingDir = process.env["OPAL_CWD"] || process.env["INIT_CWD"] || process.cwd();
}

// Clear the screen so the app starts with a fresh viewport.
process.stdout.write("\x1b[2J\x1b[H");

// Track the session ID so we can print a resume hint after exit.
let exitSessionId: string | undefined;

const instance = render(
  React.createElement(App, {
    sessionOpts: opts,
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
