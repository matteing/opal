import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { EventEmitter, Readable, Writable } from "node:stream";
import { OpalClient } from "../sdk/client.js";

// Mock child_process.spawn
vi.mock("node:child_process", () => ({
  spawn: vi.fn(),
}));

// Mock resolve to avoid actual PATH lookup
vi.mock("../sdk/resolve.js", () => ({
  resolveServer: () => ({
    command: "/usr/bin/fake-opal-server",
    args: [],
  }),
}));

import { spawn } from "node:child_process";

function createMockProcess() {
  const stdin = new Writable({
    write(_chunk, _enc, cb) {
      cb();
    },
  });
  const stdout = new Readable({ read() {} });
  const stderr = new Readable({ read() {} });
  const proc = new EventEmitter() as EventEmitter & {
    stdin: Writable;
    stdout: Readable;
    stderr: Readable;
    kill: ReturnType<typeof vi.fn>;
    pid: number;
  };
  proc.stdin = stdin;
  proc.stdout = stdout;
  proc.stderr = stderr;
  proc.kill = vi.fn();
  proc.pid = 12345;
  return proc;
}

describe("OpalClient", () => {
  let mockProc: ReturnType<typeof createMockProcess>;

  beforeEach(() => {
    mockProc = createMockProcess();
    vi.mocked(spawn).mockReturnValue(mockProc as never);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("spawns server process on construction", () => {
    const _client = new OpalClient();
    expect(spawn).toHaveBeenCalledWith("/usr/bin/fake-opal-server", [], expect.any(Object));
  });

  it("spawns with explicit serverPath", () => {
    const _client = new OpalClient({ serverPath: "/my/server" });
    expect(spawn).toHaveBeenCalledWith("/my/server", [], expect.any(Object));
  });

  it("spawns with explicit server resolution", () => {
    const _client = new OpalClient({
      server: { command: "/custom/cmd", args: ["--flag"] },
      args: ["--extra"],
    });
    expect(spawn).toHaveBeenCalledWith("/custom/cmd", ["--flag", "--extra"], expect.any(Object));
  });

  it("request sends JSON-RPC with incremented IDs", async () => {
    const client = new OpalClient();
    const writes: string[] = [];
    mockProc.stdin.write = function (chunk: unknown, ...args: unknown[]) {
      writes.push(String(chunk));
      const cb = args.find((a) => typeof a === "function") as (() => void) | undefined;
      cb?.();
      return true;
    } as never;

    // Start request (don't await yet)
    const p1 = client.request("opal/ping", {});
    const p2 = client.request("opal/ping", {});

    // Respond
    mockProc.stdout.push(JSON.stringify({ jsonrpc: "2.0", id: 1, result: {} }) + "\n");
    mockProc.stdout.push(JSON.stringify({ jsonrpc: "2.0", id: 2, result: {} }) + "\n");

    await Promise.all([p1, p2]);
    expect(writes).toHaveLength(2);
    const msg1 = JSON.parse(writes[0].replace("\n", ""));
    const msg2 = JSON.parse(writes[1].replace("\n", ""));
    expect(msg1.id).toBe(1);
    expect(msg2.id).toBe(2);
  });

  it("request converts params to snake_case and result to camelCase", async () => {
    const client = new OpalClient();
    const writes: string[] = [];
    mockProc.stdin.write = function (chunk: unknown, ...args: unknown[]) {
      writes.push(String(chunk));
      const cb = args.find((a) => typeof a === "function") as (() => void) | undefined;
      cb?.();
      return true;
    } as never;

    const p = client.request("session/start" as never, { workingDir: "/tmp" } as never);
    mockProc.stdout.push(
      JSON.stringify({ jsonrpc: "2.0", id: 1, result: { session_id: "abc" } }) + "\n",
    );
    const result = await p;

    const sent = JSON.parse(writes[0].replace("\n", ""));
    expect(sent.params.working_dir).toBe("/tmp");
    expect((result as Record<string, unknown>).sessionId).toBe("abc");
  });

  it("request rejects on JSON-RPC error", async () => {
    const client = new OpalClient();
    const p = client.request("opal/ping", {});
    mockProc.stdout.push(
      JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        error: { code: -32600, message: "Invalid request" },
      }) + "\n",
    );
    await expect(p).rejects.toThrow("Invalid request");
  });

  it("request rejects on timeout", async () => {
    const client = new OpalClient();
    const p = client.request("opal/ping", {}, 50);
    await expect(p).rejects.toThrow("timed out");
  });

  it("request rejects when client is closed", async () => {
    const client = new OpalClient();
    client.close();
    await expect(client.request("opal/ping", {})).rejects.toThrow("closed");
  });

  it("ignores empty/whitespace lines", async () => {
    const client = new OpalClient();
    const errors: unknown[] = [];
    client.on("parseError", (e: unknown) => errors.push(e));
    mockProc.stdout.push("\n");
    mockProc.stdout.push("   \n");
    // Wait a tick
    await new Promise((r) => setTimeout(r, 10));
    expect(errors).toHaveLength(0);
  });

  it("emits parseError on malformed JSON", async () => {
    const client = new OpalClient();
    const errors: string[] = [];
    client.on("parseError", (line: string) => errors.push(line));
    mockProc.stdout.push("not json\n");
    await new Promise((r) => setTimeout(r, 10));
    expect(errors).toEqual(["not json"]);
  });

  it("routes agent/event notifications with camelCase type", async () => {
    const client = new OpalClient();
    const events: unknown[] = [];
    client.on("agentEvent", (e) => events.push(e));

    mockProc.stdout.push(
      JSON.stringify({
        jsonrpc: "2.0",
        method: "agent/event",
        params: { type: "agent_start" },
      }) + "\n",
    );
    await new Promise((r) => setTimeout(r, 10));
    expect(events).toHaveLength(1);
    expect((events[0] as Record<string, unknown>).type).toBe("agentStart");
  });

  it("handles server requests with onConfirm handler", async () => {
    const handler = vi.fn().mockResolvedValue({ action: "allow" });
    const _client = new OpalClient({ onConfirm: handler as never });
    const writes: string[] = [];
    mockProc.stdin.write = function (chunk: unknown, ...args: unknown[]) {
      writes.push(String(chunk));
      const cb = args.find((a) => typeof a === "function") as (() => void) | undefined;
      cb?.();
      return true;
    } as never;

    mockProc.stdout.push(
      JSON.stringify({
        jsonrpc: "2.0",
        id: 99,
        method: "client/confirm",
        params: { session_id: "s1", title: "Allow?" },
      }) + "\n",
    );
    await new Promise((r) => setTimeout(r, 10));

    expect(handler).toHaveBeenCalledWith(expect.objectContaining({ sessionId: "s1" }));
    const response = JSON.parse(writes[writes.length - 1].replace("\n", ""));
    expect(response.id).toBe(99);
    expect(response.result.action).toBe("allow");
  });

  it("sends error response when server request handler throws", async () => {
    const handler = vi.fn().mockRejectedValue(new Error("denied"));
    const _client = new OpalClient({ onConfirm: handler as never });
    const writes: string[] = [];
    mockProc.stdin.write = function (chunk: unknown, ...args: unknown[]) {
      writes.push(String(chunk));
      const cb = args.find((a) => typeof a === "function") as (() => void) | undefined;
      cb?.();
      return true;
    } as never;

    mockProc.stdout.push(
      JSON.stringify({
        jsonrpc: "2.0",
        id: 100,
        method: "client/confirm",
        params: {},
      }) + "\n",
    );
    await new Promise((r) => setTimeout(r, 10));

    const response = JSON.parse(writes[writes.length - 1].replace("\n", ""));
    expect(response.error.message).toBe("denied");
  });

  it("sends -32601 when no server request handler", async () => {
    const _client = new OpalClient();
    const writes: string[] = [];
    mockProc.stdin.write = function (chunk: unknown, ...args: unknown[]) {
      writes.push(String(chunk));
      const cb = args.find((a) => typeof a === "function") as (() => void) | undefined;
      cb?.();
      return true;
    } as never;

    mockProc.stdout.push(
      JSON.stringify({
        jsonrpc: "2.0",
        id: 101,
        method: "client/confirm",
        params: {},
      }) + "\n",
    );
    await new Promise((r) => setTimeout(r, 10));

    const response = JSON.parse(writes[writes.length - 1].replace("\n", ""));
    expect(response.error.code).toBe(-32601);
  });

  it("close kills process and rejects pending", async () => {
    const client = new OpalClient();
    const p = client.request("opal/ping", {});
    client.close();
    await expect(p).rejects.toThrow("closed");
    expect(mockProc.kill).toHaveBeenCalled();
  });

  it("close is idempotent", () => {
    const client = new OpalClient();
    client.close();
    client.close();
    expect(mockProc.kill).toHaveBeenCalledTimes(1);
  });

  it("process exit rejects pending requests", async () => {
    const client = new OpalClient();
    const p = client.request("opal/ping", {});
    mockProc.emit("exit", 1, null);
    await expect(p).rejects.toThrow("exited");
  });

  it("process exit includes stderr in error", async () => {
    const client = new OpalClient();
    const p = client.request("opal/ping", {});
    mockProc.stderr.push("Some error output");
    await new Promise((r) => setTimeout(r, 10));
    mockProc.emit("exit", 1, null);
    await expect(p).rejects.toThrow("stderr");
  });

  it("ping calls opal/ping with timeout", async () => {
    const client = new OpalClient();
    const p = client.ping(100);
    mockProc.stdout.push(JSON.stringify({ jsonrpc: "2.0", id: 1, result: {} }) + "\n");
    await p;
  });

  it("onNotification receives raw notifications", async () => {
    const client = new OpalClient();
    const notifications: [string, Record<string, unknown>][] = [];
    client.on("notification", (method, params) => notifications.push([method, params]));

    mockProc.stdout.push(
      JSON.stringify({
        jsonrpc: "2.0",
        method: "custom/notification",
        params: { some_key: "val" },
      }) + "\n",
    );
    await new Promise((r) => setTimeout(r, 10));
    expect(notifications).toHaveLength(1);
    expect(notifications[0][0]).toBe("custom/notification");
    expect(notifications[0][1]).toEqual({ someKey: "val" });
  });
});
