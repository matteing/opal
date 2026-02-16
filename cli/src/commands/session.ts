/**
 * `opal session list` — List saved sessions.
 * `opal session show <id>` — Show session details.
 * `opal session delete <id>` — Delete a saved session.
 */
import { OpalClient } from "../sdk/client.js";

export async function runSessionList(): Promise<void> {
  const client = new OpalClient();

  try {
    await client.ping(5000);

    const result = (await client.request("session/list", {} as Record<string, never>)) as {
      sessions: Array<{
        id: string;
        title: string;
        modified: string;
      }>;
    };

    if (result.sessions.length === 0) {
      console.log("No saved sessions.");
      return;
    }

    for (const session of result.sessions) {
      const title = session.title || "(untitled)";
      const date = session.modified || "";
      console.log(`  ${session.id}  ${title}  ${date}`);
    }
  } catch (err) {
    console.error("Failed to list sessions:", (err as Error).message);
    process.exitCode = 1;
  } finally {
    client.close();
  }
}

export async function runSessionShow(sessionId: string): Promise<void> {
  const client = new OpalClient();

  try {
    await client.ping(5000);

    const result = (await client.request("session/list", {} as Record<string, never>)) as {
      sessions: Array<{
        id: string;
        title: string;
        modified: string;
      }>;
    };

    const session = result.sessions.find((s) => s.id === sessionId);
    if (!session) {
      console.error(`Session not found: ${sessionId}`);
      process.exitCode = 1;
      return;
    }

    console.log(`ID:       ${session.id}`);
    console.log(`Title:    ${session.title || "(untitled)"}`);
    console.log(`Modified: ${session.modified || "unknown"}`);
    console.log(`\nResume:   opal --session "${session.id}"`);
  } catch (err) {
    console.error("Failed to show session:", (err as Error).message);
    process.exitCode = 1;
  } finally {
    client.close();
  }
}

export async function runSessionDelete(sessionId: string): Promise<void> {
  const client = new OpalClient();

  try {
    await client.ping(5000);

    await client.request("session/delete", { sessionId });
    console.log(`Deleted session: ${sessionId}`);
  } catch (err) {
    console.error("Failed to delete session:", (err as Error).message);
    process.exitCode = 1;
  } finally {
    client.close();
  }
}
