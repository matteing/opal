#!/usr/bin/env node
import { render } from "ink";
import React from "react";
import { App } from "./app.js";
import type { SessionOptions } from "./sdk/session.js";

// --- Parse CLI args ---

const args = process.argv.slice(2);
const opts: SessionOptions = {};

for (let i = 0; i < args.length; i++) {
  const arg = args[i];
  switch (arg) {
    case "--model": {
      const val = args[++i];
      if (val) {
        const [provider, ...idParts] = val.split("/");
        const id = idParts.join("/");
        if (provider && id) {
          opts.model = { provider, id };
        }
      }
      break;
    }
    case "--working-dir":
    case "-C":
      opts.workingDir = args[++i];
      break;
    case "--verbose":
    case "-v":
      opts.verbose = true;
      break;
    case "--auto-confirm":
      opts.autoConfirm = true;
      break;
    case "--debug":
      opts.features = {
        ...(opts.features ?? {}),
        debug: true,
      } as SessionOptions["features"];
      break;
    case "--help":
    case "-h":
      console.log(`Usage: opal [options]

Options:
  --model <provider/id>   Model to use (e.g. anthropic/claude-sonnet-4-20250514)
  --working-dir, -C <dir> Working directory
  --auto-confirm          Auto-confirm all tool executions
  --debug                 Enable debug feature/tools for this session
  --verbose, -v           Verbose output
  --help, -h              Show help`);
      process.exit(0);
  }
}

if (!opts.workingDir) {
  // INIT_CWD is set cross-platform by npm/pnpm to the original working directory.
  // OPAL_CWD is kept as a manual override.
  opts.workingDir = process.env["OPAL_CWD"] || process.env["INIT_CWD"] || process.cwd();
}

// Clear the screen so the app starts with a fresh viewport.
process.stdout.write("\x1b[2J\x1b[H");

render(React.createElement(App, { sessionOpts: opts }));
