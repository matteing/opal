/**
 * `opal auth login` — Start device-code OAuth login.
 * `opal auth status` — Check authentication state.
 */
import { OpalClient } from "../sdk/client.js";

export async function runAuthStatus(): Promise<void> {
  const client = new OpalClient();

  try {
    await client.ping(5000);

    const result = (await client.request("auth/status", {} as Record<string, never>)) as {
      authenticated: boolean;
      auth?: Record<string, unknown>;
    };

    if (result.authenticated) {
      console.log("✓ Authenticated");
    } else {
      console.log("✗ Not authenticated");
      console.log("  Run: opal auth login");
    }
  } catch (err) {
    console.error("Failed to connect to opal-server:", (err as Error).message);
    process.exitCode = 1;
  } finally {
    client.close();
  }
}

export async function runAuthLogin(): Promise<void> {
  const client = new OpalClient();

  try {
    await client.ping(5000);

    const result = (await client.request("auth/login", {} as Record<string, never>)) as {
      userCode: string;
      verificationUri: string;
      deviceCode: string;
      interval: number;
    };

    console.log(`\nOpen: ${result.verificationUri}`);
    console.log(`Code: ${result.userCode}\n`);
    console.log("Waiting for authorization...");

    const pollResult = (await client.request("auth/poll", {
      deviceCode: result.deviceCode,
      interval: result.interval,
    })) as { authenticated: boolean };

    if (pollResult.authenticated) {
      console.log("✓ Authenticated successfully!");
    } else {
      console.log("✗ Authentication failed.");
      process.exitCode = 1;
    }
  } catch (err) {
    console.error("Auth login failed:", (err as Error).message);
    process.exitCode = 1;
  } finally {
    client.close();
  }
}
