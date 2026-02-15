import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { EventEmitter, Readable, Writable } from "node:stream";
import { OpalClient } from "../sdk/client.js";

vi.mock("node:child_process", () => ({ spawn: vi.fn() }));
vi.mock("../sdk/resolve.js", () => ({
  resolveServer: () => ({ command: "/usr/bin/fake-opal-server", args: [] }),
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

describe("OpalClient — failure modes", () => {
  let mockProc: ReturnType<typeof createMockProcess>;

  beforeEach(() => {
    mockProc = createMockProcess();
    vi.mocked(spawn).mockReturnValue(mockProc as never);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  // --- Server crash / exit ---

  describe("server crash/exit", () => {
    it("rejects all pending on exit code 0", async () => {
      const client = new OpalClient();
      const p = client.request("opal/ping", {});
      mockProc.emit("exit", 0, null);
      await expect(p).rejects.toThrow("exited");
    });

    it("includes stderr in exit error (capped at 2000 chars)", async () => {
      const client = new OpalClient();
      const p = client.request("opal/ping", {});
      mockProc.stderr.push("A".repeat(3000));
      await new Promise((r) => setTimeout(r, 10));
      mockProc.emit("exit", 1, null);
      const err = await p.catch((e: Error) => e);
      expect(err.message).toContain("stderr");
      // Should be capped
      expect(err.message.length).toBeLessThan(3500);
    });

    it("includes signal info on SIGKILL", async () => {
      const client = new OpalClient();
      const p = client.request("opal/ping", {});
      mockProc.emit("exit", null, "SIGKILL");
      const err = await p.catch((e: Error) => e);
      expect(err.message).toContain("SIGKILL");
    });

    it("rejects all pending when multiple in-flight", async () => {
      const client = new OpalClient();
      const p1 = client.request("opal/ping", {});
      const p2 = client.request("opal/ping", {});
      const p3 = client.request("opal/ping", {});
      mockProc.emit("exit", 1, null);
      await expect(p1).rejects.toThrow();
      await expect(p2).rejects.toThrow();
      await expect(p3).rejects.toThrow();
    });

    it("request after exit throws closed", async () => {
      const client = new OpalClient();
      mockProc.emit("exit", 0, null);
      await new Promise((r) => setTimeout(r, 10));
      await expect(client.request("opal/ping", {})).rejects.toThrow("closed");
    });
  });

  // --- Protocol violations ---

  describe("protocol violations", () => {
    it("ignores response with unknown id", async () => {
      const client = new OpalClient();
      // Send a response for id 999 which no one is waiting for
      mockProc.stdout.push(JSON.stringify({ jsonrpc: "2.0", id: 999, result: {} }) + "\n");
      await new Promise((r) => setTimeout(r, 10));
      // No crash — just verify client is still functional
      const p = client.request("opal/ping", {});
      mockProc.stdout.push(JSON.stringify({ jsonrpc: "2.0", id: 1, result: {} }) + "\n");
      await p;
      client.close();
    });

    it("emits parseError on binary garbage", async () => {
      const client = new OpalClient();
      const errors: string[] = [];
      client.on("parseError", (line: string) => errors.push(line));
      mockProc.stdout.push(Buffer.from([0xff, 0xfe, 0x0a])); // garbage + newline
      await new Promise((r) => setTimeout(r, 10));
      expect(errors.length).toBeGreaterThan(0);
      client.close();
    });

    it("handles valid JSON but not JSONRPC without crash", async () => {
      const client = new OpalClient();
      mockProc.stdout.push(JSON.stringify({ foo: "bar" }) + "\n");
      await new Promise((r) => setTimeout(r, 10));
      // Client should still work
      const p = client.request("opal/ping", {});
      mockProc.stdout.push(JSON.stringify({ jsonrpc: "2.0", id: 1, result: {} }) + "\n");
      await p;
      client.close();
    });

    it("ignores response for already-timed-out request", async () => {
      const client = new OpalClient();
      const p = client.request("opal/ping", {}, 20);
      await expect(p).rejects.toThrow("timed out");
      // Now send the response — should not throw
      mockProc.stdout.push(JSON.stringify({ jsonrpc: "2.0", id: 1, result: {} }) + "\n");
      await new Promise((r) => setTimeout(r, 10));
      client.close();
    });
  });

  // --- Timeout edge cases ---

  describe("timeout edge cases", () => {
    it("multiple concurrent, one times out, others still resolve", async () => {
      const client = new OpalClient();
      const p1 = client.request("opal/ping", {}, 20); // will timeout
      const p2 = client.request("opal/ping", {}); // no timeout

      await expect(p1).rejects.toThrow("timed out");

      // p2 should still resolve when response arrives
      mockProc.stdout.push(JSON.stringify({ jsonrpc: "2.0", id: 2, result: { ok: true } }) + "\n");
      const result = await p2;
      expect(result).toEqual({ ok: true });
      client.close();
    });

    it("response arriving just before timeout resolves normally", async () => {
      const client = new OpalClient();
      const p = client.request("opal/ping", {}, 500);
      // Respond immediately
      mockProc.stdout.push(JSON.stringify({ jsonrpc: "2.0", id: 1, result: {} }) + "\n");
      await p; // should not throw
      client.close();
    });
  });

  // --- Concurrency & ordering ---

  describe("concurrency", () => {
    it("resolves out-of-order responses correctly", async () => {
      const client = new OpalClient();
      const p1 = client.request("opal/ping", {});
      const p2 = client.request("opal/ping", {});
      const p3 = client.request("opal/ping", {});

      // Respond out of order: 3, 1, 2
      mockProc.stdout.push(JSON.stringify({ jsonrpc: "2.0", id: 3, result: { n: 3 } }) + "\n");
      mockProc.stdout.push(JSON.stringify({ jsonrpc: "2.0", id: 1, result: { n: 1 } }) + "\n");
      mockProc.stdout.push(JSON.stringify({ jsonrpc: "2.0", id: 2, result: { n: 2 } }) + "\n");

      expect(await p1).toEqual({ n: 1 });
      expect(await p2).toEqual({ n: 2 });
      expect(await p3).toEqual({ n: 3 });
      client.close();
    });

    it("handles rapid-fire requests with unique IDs", async () => {
      const client = new OpalClient();
      const writes: string[] = [];
      mockProc.stdin.write = function (chunk: unknown, ...args: unknown[]) {
        writes.push(String(chunk));
        const cb = args.find((a) => typeof a === "function") as (() => void) | undefined;
        cb?.();
        return true;
      } as never;

      const promises = Array.from({ length: 50 }, () => client.request("opal/ping", {}));

      // Respond to all
      for (let i = 1; i <= 50; i++) {
        mockProc.stdout.push(JSON.stringify({ jsonrpc: "2.0", id: i, result: {} }) + "\n");
      }

      await Promise.all(promises);
      const ids = writes.map((w) => JSON.parse(w.replace("\n", "")).id);
      const unique = new Set(ids);
      expect(unique.size).toBe(50);
      client.close();
    });

    it("out-of-order responses still resolve correctly after error events", async () => {
      const client = new OpalClient();

      // Start requests then send responses in reverse
      const p1 = client.request("opal/ping", {});
      const p2 = client.request("opal/ping", {});
      // Also send an unrelated notification
      mockProc.stdout.push(
        JSON.stringify({
          jsonrpc: "2.0",
          method: "agent/event",
          params: { type: "error", reason: "transient" },
        }) + "\n",
      );
      mockProc.stdout.push(JSON.stringify({ jsonrpc: "2.0", id: 2, result: { b: 2 } }) + "\n");
      mockProc.stdout.push(JSON.stringify({ jsonrpc: "2.0", id: 1, result: { a: 1 } }) + "\n");

      expect(await p1).toEqual({ a: 1 });
      expect(await p2).toEqual({ b: 2 });
      client.close();
    });
  });

  // --- Emit & close lifecycle ---

  describe("lifecycle", () => {
    it("emits exit event with code and signal", async () => {
      const client = new OpalClient();
      const exits: [number | null, string | null][] = [];
      client.on("exit", (code: number | null, signal: string | null) => exits.push([code, signal]));
      mockProc.emit("exit", 137, "SIGTERM");
      expect(exits).toEqual([[137, "SIGTERM"]]);
    });

    it("emits stderr chunks", async () => {
      const client = new OpalClient();
      const chunks: string[] = [];
      client.on("stderr", (data: string) => chunks.push(data));
      mockProc.stderr.push("line 1\n");
      mockProc.stderr.push("line 2\n");
      await new Promise((r) => setTimeout(r, 10));
      expect(chunks).toHaveLength(2);
      client.close();
    });
  });
});
