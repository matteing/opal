import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { OpalClient } from "../sdk/client.js";
import {
  createMockProcess,
  respond,
  sendEvent,
  capturingWrites,
  tick,
  type MockProcess,
} from "./helpers/mock-process.js";

vi.mock("node:child_process", () => ({ spawn: vi.fn() }));
vi.mock("../sdk/resolve.js", () => ({
  resolveServer: () => ({ command: "/usr/bin/fake-opal-server", args: [] }),
}));

import { spawn } from "node:child_process";

describe("OpalClient — failure modes", () => {
  let proc: MockProcess;

  beforeEach(() => {
    proc = createMockProcess();
    vi.mocked(spawn).mockReturnValue(proc as never);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  // --- Server crash / exit ---

  describe("server crash/exit", () => {
    it("rejects pending request on clean exit", async () => {
      const client = new OpalClient();
      const pending = client.request("opal/ping", {});
      proc.emit("exit", 0, null);
      await expect(pending).rejects.toThrow("exited");
    });

    it("includes stderr in exit error, capped at ~2 000 chars", async () => {
      const client = new OpalClient();
      const pending = client.request("opal/ping", {});

      proc.stderr.push("A".repeat(3000));
      await tick();
      proc.emit("exit", 1, null);

      const err = await pending.catch((e: Error) => e);
      expect(err.message).toContain("stderr");
      expect(err.message.length).toBeLessThan(3500);
    });

    it("includes signal name on SIGKILL", async () => {
      const client = new OpalClient();
      const pending = client.request("opal/ping", {});
      proc.emit("exit", null, "SIGKILL");
      const err = await pending.catch((e: Error) => e);
      expect(err.message).toContain("SIGKILL");
    });

    it("rejects every in-flight request on crash", async () => {
      const client = new OpalClient();
      const requests = [
        client.request("opal/ping", {}),
        client.request("opal/ping", {}),
        client.request("opal/ping", {}),
      ];
      proc.emit("exit", 1, null);
      for (const p of requests) {
        await expect(p).rejects.toThrow();
      }
    });

    it("throws 'closed' for requests sent after exit", async () => {
      const client = new OpalClient();
      proc.emit("exit", 0, null);
      await tick();
      await expect(client.request("opal/ping", {})).rejects.toThrow("closed");
    });
  });

  // --- Protocol violations ---

  describe("protocol violations", () => {
    it("ignores responses with unknown ids", async () => {
      const client = new OpalClient();
      respond(proc, 999, {}); // nobody is waiting for id 999
      await tick();

      // client still works
      const pending = client.request("opal/ping", {});
      respond(proc, 1, {});
      await pending;
      client.close();
    });

    it("emits parseError on binary garbage", async () => {
      const client = new OpalClient();
      const errors: string[] = [];
      client.on("parseError", (line: string) => errors.push(line));

      proc.stdout.push(Buffer.from([0xff, 0xfe, 0x0a]));
      await tick();

      expect(errors.length).toBeGreaterThan(0);
      client.close();
    });

    it("survives valid JSON that is not JSON-RPC", async () => {
      const client = new OpalClient();
      proc.stdout.push(JSON.stringify({ foo: "bar" }) + "\n");
      await tick();

      const pending = client.request("opal/ping", {});
      respond(proc, 1, {});
      await pending;
      client.close();
    });

    it("ignores late response for already-timed-out request", async () => {
      const client = new OpalClient();
      const pending = client.request("opal/ping", {}, 20);
      await expect(pending).rejects.toThrow("timed out");

      respond(proc, 1, {}); // belated — should not throw
      await tick();
      client.close();
    });
  });

  // --- Timeout edge cases ---

  describe("timeout edge cases", () => {
    it("one request times out, siblings still resolve", async () => {
      const client = new OpalClient();
      const willTimeout = client.request("opal/ping", {}, 20);
      const willResolve = client.request("opal/ping", {});

      await expect(willTimeout).rejects.toThrow("timed out");

      respond(proc, 2, { ok: true });
      expect(await willResolve).toEqual({ ok: true });
      client.close();
    });

    it("immediate response resolves before timeout fires", async () => {
      const client = new OpalClient();
      const pending = client.request("opal/ping", {}, 500);
      respond(proc, 1, {});
      await pending; // should not throw
      client.close();
    });
  });

  // --- Concurrency & ordering ---

  describe("concurrency", () => {
    it("resolves out-of-order responses to correct callers", async () => {
      const client = new OpalClient();
      const p1 = client.request("opal/ping", {});
      const p2 = client.request("opal/ping", {});
      const p3 = client.request("opal/ping", {});

      respond(proc, 3, { n: 3 });
      respond(proc, 1, { n: 1 });
      respond(proc, 2, { n: 2 });

      expect(await p1).toEqual({ n: 1 });
      expect(await p2).toEqual({ n: 2 });
      expect(await p3).toEqual({ n: 3 });
      client.close();
    });

    it("assigns unique IDs to 50 rapid-fire requests", async () => {
      const client = new OpalClient();
      const writes = capturingWrites(proc);

      const promises = Array.from({ length: 50 }, () => client.request("opal/ping", {}));

      for (let i = 1; i <= 50; i++) respond(proc, i, {});
      await Promise.all(promises);

      const ids = writes.parsed().map((m) => m?.id);
      expect(new Set(ids).size).toBe(50);
      client.close();
    });

    it("resolves correctly when interleaved with notifications", async () => {
      const client = new OpalClient();
      const p1 = client.request("opal/ping", {});
      const p2 = client.request("opal/ping", {});

      sendEvent(proc, { type: "error", reason: "transient" });
      respond(proc, 2, { b: 2 });
      respond(proc, 1, { a: 1 });

      expect(await p1).toEqual({ a: 1 });
      expect(await p2).toEqual({ b: 2 });
      client.close();
    });
  });

  // --- Lifecycle events ---

  describe("lifecycle", () => {
    it("emits exit event with code and signal", () => {
      const client = new OpalClient();
      const exits: [number | null, string | null][] = [];
      client.on("exit", (code: number | null, signal: string | null) => exits.push([code, signal]));
      proc.emit("exit", 137, "SIGTERM");
      expect(exits).toEqual([[137, "SIGTERM"]]);
    });

    it("emits stderr chunks", async () => {
      const client = new OpalClient();
      const chunks: string[] = [];
      client.on("stderr", (data: string) => chunks.push(data));

      proc.stderr.push("line 1\n");
      proc.stderr.push("line 2\n");
      await tick();

      expect(chunks).toHaveLength(2);
      client.close();
    });
  });
});
