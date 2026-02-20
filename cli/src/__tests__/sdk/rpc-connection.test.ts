import { describe, it, expect, vi } from "vitest";
import { createMemoryTransport } from "../../sdk/transport/memory.js";
import { RpcConnection } from "../../sdk/rpc/connection.js";
import type { Transport } from "../../sdk/transport/transport.js";
import { RpcError, TimeoutError } from "../../sdk/errors.js";

const tick = () => new Promise<void>((r) => setTimeout(r, 0));

/** Simulate a server: respond to incoming requests using the provided handler. */
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

describe("RpcConnection", () => {
  it("sends a request and receives a response", async () => {
    const [client, server] = createMemoryTransport();
    const rpc = new RpcConnection(client);
    respondOnServer(server, () => ({ result: { hello: "world" } }));

    const res = await rpc.request("test/method", { param: 1 });
    expect(res).toEqual({ hello: "world" });
    rpc.close();
  });

  it("handles multiple concurrent requests resolved out of order", async () => {
    const [client, server] = createMemoryTransport();
    const rpc = new RpcConnection(client);

    const responses: Array<{ id: number; msg: Record<string, unknown> }> = [];
    server.onMessage((line) => {
      const msg = JSON.parse(line) as Record<string, unknown>;
      if (msg.id != null && msg.method != null) {
        responses.push({ id: msg.id as number, msg });
      }
    });

    const p1 = rpc.request("method/a", { v: 1 });
    const p2 = rpc.request("method/b", { v: 2 });
    await tick();

    expect(responses).toHaveLength(2);
    // Respond in reverse order
    server.send(JSON.stringify({ jsonrpc: "2.0", id: responses[1].id, result: "b" }));
    server.send(JSON.stringify({ jsonrpc: "2.0", id: responses[0].id, result: "a" }));

    await expect(p1).resolves.toBe("a");
    await expect(p2).resolves.toBe("b");
    rpc.close();
  });

  it("rejects with RpcError on error response", async () => {
    const [client, server] = createMemoryTransport();
    const rpc = new RpcConnection(client);
    respondOnServer(server, () => ({
      error: { code: -32600, message: "Bad" },
    }));

    await expect(rpc.request("bad/method")).rejects.toThrow(RpcError);
    try {
      await rpc.request("bad/method");
    } catch (e) {
      expect(e).toBeInstanceOf(RpcError);
      expect((e as RpcError).rpcCode).toBe(-32600);
      expect((e as RpcError).code).toBe("SERVER_ERROR");
    }
    rpc.close();
  });

  it("rejects with TimeoutError when server does not respond", async () => {
    const [client] = createMemoryTransport();
    const rpc = new RpcConnection(client);

    await expect(rpc.request("slow/method", {}, 50)).rejects.toThrow(TimeoutError);
    rpc.close();
  });

  it("dispatches notifications to onNotification handlers", async () => {
    const [client, server] = createMemoryTransport();
    const rpc = new RpcConnection(client);
    const handler = vi.fn();
    rpc.onNotification(handler);

    server.send(
      JSON.stringify({
        jsonrpc: "2.0",
        method: "agent/event",
        params: { some_key: "value" },
      }),
    );
    await tick();

    expect(handler).toHaveBeenCalledWith("agent/event", { someKey: "value" });
    rpc.close();
  });

  it("handles server→client method calls via addMethod", async () => {
    const [client, server] = createMemoryTransport();
    const rpc = new RpcConnection(client);

    rpc.addMethod("client/confirm", async (params) => {
      const p = params as { file_path: string };
      return { confirmed: true, filePath: p.filePath };
    });

    server.send(
      JSON.stringify({
        jsonrpc: "2.0",
        id: 99,
        method: "client/confirm",
        params: { file_path: "/tmp/a.txt" },
      }),
    );

    const response = await new Promise<Record<string, unknown>>((resolve) => {
      server.onMessage((line) => {
        const msg = JSON.parse(line) as Record<string, unknown>;
        if (msg.id === 99) resolve(msg);
      });
    });

    expect(response.result).toEqual({
      confirmed: true,
      file_path: "/tmp/a.txt",
    });
    rpc.close();
  });

  it("sends METHOD_NOT_FOUND error for unregistered methods", async () => {
    const [client, server] = createMemoryTransport();
    const rpc = new RpcConnection(client);

    server.send(
      JSON.stringify({
        jsonrpc: "2.0",
        id: 42,
        method: "unknown/method",
        params: {},
      }),
    );

    const response = await new Promise<Record<string, unknown>>((resolve) => {
      server.onMessage((line) => {
        const msg = JSON.parse(line) as Record<string, unknown>;
        if (msg.id === 42) resolve(msg);
      });
    });

    const err = response.error as { code: number; message: string };
    expect(err.code).toBe(-32601);
    expect(err.message).toContain("unknown/method");
    rpc.close();
  });

  it("rejects pending requests on close()", async () => {
    const [client] = createMemoryTransport();
    const rpc = new RpcConnection(client);

    const pending = rpc.request("will/close");
    rpc.close();

    await expect(pending).rejects.toThrow(RpcError);
    await expect(pending).rejects.toThrow(/closed/i);
  });

  it("rejects pending requests when transport closes", async () => {
    const [client, server] = createMemoryTransport();
    const rpc = new RpcConnection(client);

    const pending = rpc.request("will/close");
    server.close();

    await expect(pending).rejects.toThrow(RpcError);
  });

  it("transforms outgoing params to snake_case on the wire", async () => {
    const [client, server] = createMemoryTransport();
    const rpc = new RpcConnection(client);

    const wireMessages: Record<string, unknown>[] = [];
    server.onMessage((line) => {
      const msg = JSON.parse(line) as Record<string, unknown>;
      wireMessages.push(msg);
      if (msg.id != null && msg.method != null) {
        server.send(
          JSON.stringify({
            jsonrpc: "2.0",
            id: msg.id,
            result: { result_key: "ok" },
          }),
        );
      }
    });

    const res = await rpc.request("test/case", { myParam: "value" });

    // Wire should be snake_case
    const wireParams = wireMessages[0].params as Record<string, unknown>;
    expect(wireParams).toHaveProperty("my_param", "value");

    // Result should be camelCase
    expect(res).toEqual({ resultKey: "ok" });
    rpc.close();
  });
});
