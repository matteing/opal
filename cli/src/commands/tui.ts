import { render } from "ink";
import React from "react";
import { App, AppProps } from "../app.js";
import { TuiArgs } from "../bin.js";

function parseExpose(expose: string): { name: string; cookie?: string } {
  const [name, cookie] = expose.split("#", 2);
  return cookie ? { name, cookie } : { name };
}

/**
 * On Windows, ensure the console is in VT processing mode and clear the
 * screen so Ink gets a clean slate. Without this, ANSI cursor-movement
 * sequences may be ignored and the initial render "sticks" to the top.
 */
function prepareTerminal(): void {
  if (process.platform !== "win32" || !process.stdout.isTTY) return;

  // Emit an ANSI escape to nudge the console into VT mode (no-op if already enabled).
  // ESC[6n (device status report) is harmless and forces VT processing on.
  process.stdout.write("\x1b[6n");

  // Clear the screen so Ink starts from a known state.
  process.stdout.write("\x1b[2J\x1b[3J\x1b[H");
}

export async function launchTui(args: TuiArgs): Promise<void> {
  const opts: AppProps = {
    // Generate a session ID if not provided, so we can always show the resume hint on exit.
    sessionId: args.session ?? crypto.randomUUID(),
    workingDir: args.workingDir,
    ...(args.expose ? { distribution: parseExpose(args.expose) } : {}),
  };

  prepareTerminal();

  // Off to the races, bitch
  const instance = render(React.createElement(App, opts));

  await instance
    .waitUntilExit()
    .then(() => {
      const cols = process.stdout.columns ?? 80;
      const resume = `Accident? Resume this session: opal --session "${opts.sessionId}"`;
      const padResume = Math.max(0, Math.floor((cols - resume.length) / 2));
      console.log();
      console.log(" ".repeat(padResume) + resume);
      console.log();
    })
    .catch((err: unknown) => {
      process.exitCode = 1;
      if (err instanceof Error && err.message) {
        process.stderr.write(err.message + "\n");
      }
    });
}
