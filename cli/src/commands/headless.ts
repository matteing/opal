/**
 * `opal "prompt" --no-tui` — Headless mode. Send prompt, print response, exit.
 */
import { OpalClient } from "../sdk/client.js";
import type { AgentEvent } from "../sdk/protocol.js";

export async function runHeadless(
  prompt: string,
  opts: {
    model?: { provider: string; id: string };
    workingDir?: string;
    autoConfirm?: boolean;
  },
): Promise<void> {
  const client = new OpalClient({
    onServerRequest: async (method) => {
      if (method === "client/confirm") {
        if (opts.autoConfirm) return { action: "allow" };
        return { action: "deny" };
      }
      throw new Error(`Unhandled server request in headless mode: ${method}`);
    },
  });

  try {
    await client.ping(10_000);

    const startParams: Record<string, unknown> = {};
    if (opts.model) startParams.model = opts.model;
    if (opts.workingDir) startParams.workingDir = opts.workingDir;

    const session = (await client.request("session/start", startParams)) as {
      sessionId: string;
    };

    const sessionId = session.sessionId;

    await client.request("agent/prompt", {
      sessionId,
      text: prompt,
    });

    // Collect response from event stream
    await new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => {
        reject(new Error("Headless mode timed out after 120s"));
      }, 120_000);

      client.onEvent((event: AgentEvent) => {
        switch (event.type) {
          case "messageDelta":
            process.stdout.write(event.delta);
            break;
          case "agentEnd":
            process.stdout.write("\n");
            clearTimeout(timeout);
            resolve();
            break;
          case "agentAbort":
            clearTimeout(timeout);
            resolve();
            break;
          case "error":
            clearTimeout(timeout);
            reject(new Error(event.reason));
            break;
        }
      });
    });
  } catch (err) {
    process.stderr.write((err as Error).message + "\n");
    process.exitCode = 1;
  } finally {
    client.close();
  }
}
