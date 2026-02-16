/**
 * `opal doctor` — Check installation health.
 */
import { OpalClient } from "../sdk/client.js";
import { resolveServer } from "../sdk/resolve.js";

export async function runDoctor(): Promise<void> {
  let allOk = true;

  // 1. Server resolution
  process.stdout.write("Server binary ....... ");
  try {
    const resolved = resolveServer();
    console.log(`✓ ${resolved.command} ${resolved.args.join(" ")}`.trim());
  } catch {
    console.log("✗ not found");
    console.log("  Install opal-server or run from the monorepo.");
    allOk = false;
    // Can't proceed without server
    if (!allOk) process.exitCode = 1;
    return;
  }

  // 2. Server connectivity
  process.stdout.write("Server connection ... ");
  const client = new OpalClient();

  try {
    await client.ping(10_000);
    console.log("✓ connected");
  } catch {
    console.log("✗ failed to connect");
    allOk = false;
    client.close();
    if (!allOk) process.exitCode = 1;
    return;
  }

  // 3. Server version
  process.stdout.write("Server version ...... ");
  try {
    const result = (await client.request("opal/version", {} as Record<string, never>)) as {
      serverVersion: string;
      protocolVersion: string;
    };
    console.log(`✓ ${result.serverVersion} (protocol ${result.protocolVersion})`);
  } catch {
    console.log("✗ could not retrieve version");
    allOk = false;
  }

  // 4. Authentication
  process.stdout.write("Authentication ...... ");
  try {
    const result = (await client.request("auth/status", {} as Record<string, never>)) as {
      authenticated: boolean;
    };
    if (result.authenticated) {
      console.log("✓ authenticated");
    } else {
      console.log("✗ not authenticated");
      console.log("  Run: opal auth login");
      allOk = false;
    }
  } catch {
    console.log("✗ auth check failed");
    allOk = false;
  }

  client.close();

  if (allOk) {
    console.log("\nAll checks passed.");
  } else {
    console.log("\nSome checks failed.");
    process.exitCode = 1;
  }
}
