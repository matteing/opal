import { render } from "ink";
import React from "react";
import { App, AppProps } from "../app.js";
import { TuiArgs } from "../bin.js";

export async function launchTui(args: TuiArgs): Promise<void> {
  const opts: AppProps = {
    // Generate a session ID if not provided, so we can always show the resume hint on exit.
    sessionId: args.session ?? crypto.randomUUID(),
    workingDir: args.workingDir,
  };

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
