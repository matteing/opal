/**
 * `opal --version` — Print CLI and server versions, then exit.
 */
import { OpalClient, RpcConnection, StdioTransport } from "@unfinite/opal-sdk";

export async function runVersion(): Promise<void> {
  const pkg = await import("../../package.json", { with: { type: "json" } });
  const cliVersion = (pkg.default as { version: string }).version;

  console.log(`opal ${cliVersion}`);

  try {
    const transport = new StdioTransport();
    const rpc = new RpcConnection(transport);
    const client = new OpalClient(rpc);
    const result = (await client.request("opal/version", {} as Record<string, never>)) as {
      serverVersion: string;
      protocolVersion: string;
    };
    console.log(`opal-server ${result.serverVersion} (protocol ${result.protocolVersion})`);
    client.close();
  } catch {
    console.log("opal-server (not available)");
  }
}
