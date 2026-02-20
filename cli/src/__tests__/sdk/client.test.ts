import { describe, it, expect, vi } from "vitest";
import { createMemoryTransport } from "../../sdk/transport/memory.js";
import { RpcConnection } from "../../sdk/rpc/connection.js";
import { OpalClient } from "../../sdk/client.js";
import { ClientClosedError } from "../../sdk/errors.js";
import type { Transport } from "../../sdk/transport/transport.js";

const tick = () => new Promise<void>((r) => setTimeout(r, 0));

/** Auto-respond to requests on the server side. */
function respondOnServer(
  server: Transport,
  handler: (msg: Record<string, unknown>) => Record<string, unknown>,
) {
  server.onMessage((line) => {
    const msg = JSON.parse(line) as Record<string, unknown>;
    if (msg.id != null && msg.method != null) {
      const result = handler(msg);
      server.send(JSON.stringify({ jsonrpc: "2.0", id: msg.id, ...result }));
    }
  });
}

function createClient() {
  const [clientSide, serverSide] = createMemoryTransport();
  const rpc = new RpcConnection(clientSide);
  const client = new OpalClient(rpc);
  return { client, rpc, serverSide };
}

describe("OpalClient", () => {
  it("sends a typed request and resolves the response", async () => {
    const { client, serverSide } = createClient();
    respondOnServer(serverSide, () => ({ result: {} }));

    await expect(client.request("opal/ping")).resolves.toEqual({});
    client.close();
  });

  it("transforms params to snake_case and result to camelCase", async () => {
    const { client, serverSide } = createClient();

    const wireMessages: Record<string, unknown>[] = [];
    serverSide.onMessage((line) => {
      const msg = JSON.parse(line) as Record<string, unknown>;
      wireMessages.push(msg);
      if (msg.id != null && msg.method != null) {
        serverSide.send(
          JSON.stringify({
            jsonrpc: "2.0",
            id: msg.id,
            result: { session_id: "abc-123", created_at: "2025-01-01" },
          }),
        );
      }
    });

    const res = await client.request("session/start", {
      workingDir: "/tmp",
    } as never);

    // Outgoing params should be snake_case
    const wireParams = wireMessages[0].params as Record<string, unknown>;
    expect(wireParams).toHaveProperty("working_dir", "/tmp");

    // Incoming result should be camelCase
    expect(res).toEqual({ sessionId: "abc-123", createdAt: "2025-01-01" });
    client.close();
  });

  it("routes agent/event notifications to onEvent handlers", async () => {
    const { client, serverSide } = createClient();
    const handler = vi.fn();
    client.onEvent(handler);

    serverSide.send(
      JSON.stringify({
        jsonrpc: "2.0",
        method: "agent/event",
        params: { type: "tool_start", tool_name: "grep" },
      }),
    );
    await tick();

    expect(handler).toHaveBeenCalledTimes(1);
    const event = handler.mock.calls[0][0] as Record<string, unknown>;
    expect(event.type).toBe("toolStart");
    expect(event.toolName).toBe("grep");
    client.close();
  });

  it("dispatches server→client method via addServerMethod", async () => {
    const { client, serverSide } = createClient();

    client.addServerMethod("client/confirm", async (_params) => {
      return { confirmed: true } as never;
    });

    serverSide.send(
      JSON.stringify({
        jsonrpc: "2.0",
        id: 77,
        method: "client/confirm",
        params: { file_path: "/tmp/x.ts" },
      }),
    );

    const response = await new Promise<Record<string, unknown>>((resolve) => {
      serverSide.onMessage((line) => {
        const msg = JSON.parse(line) as Record<string, unknown>;
        if (msg.id === 77) resolve(msg);
      });
    });

    expect(response.result).toEqual({ confirmed: true });
    client.close();
  });

  it("throws ClientClosedError after close()", async () => {
    const { client } = createClient();
    client.close();

    try {
      await client.request("opal/ping");
      expect.unreachable("should have thrown");
    } catch (e) {
      expect(e).toBeInstanceOf(ClientClosedError);
      expect((e as ClientClosedError).code).toBe("CLIENT_CLOSED");
    }
  });

  it("ping resolves when server responds", async () => {
    const { client, serverSide } = createClient();
    respondOnServer(serverSide, () => ({ result: {} }));

    await expect(client.ping(100)).resolves.toBeUndefined();
    client.close();
  });

  it("disposed event subscription stops receiving events", async () => {
    const { client, serverSide } = createClient();
    const handler = vi.fn();
    const sub = client.onEvent(handler);
    sub.dispose();

    serverSide.send(
      JSON.stringify({
        jsonrpc: "2.0",
        method: "agent/event",
        params: { type: "tool_start" },
      }),
    );
    await tick();

    expect(handler).not.toHaveBeenCalled();
    client.close();
  });
});
