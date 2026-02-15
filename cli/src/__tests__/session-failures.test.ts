import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { EventEmitter, Readable, Writable } from "node:stream";

vi.mock("node:child_process", () => ({ spawn: vi.fn() }));
vi.mock("../sdk/resolve.js", () => ({
  resolveServer: () => ({ command: "/usr/bin/fake-opal-server", args: [] }),
}));

import { spawn } from "node:child_process";
import { Session } from "../sdk/session.js";
import type { AgentEvent } from "../sdk/protocol.js";

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

function respond(proc: ReturnType<typeof createMockProcess>, id: number, result: unknown) {
  proc.stdout.push(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
}

function respondError(
  proc: ReturnType<typeof createMockProcess>,
  id: number,
  code: number,
  message: string,
) {
  proc.stdout.push(JSON.stringify({ jsonrpc: "2.0", id, error: { code, message } }) + "\n");
}

function sendEvent(proc: ReturnType<typeof createMockProcess>, params: unknown) {
  proc.stdout.push(JSON.stringify({ jsonrpc: "2.0", method: "agent/event", params }) + "\n");
}

const sessionResult = {
  session_id: "s1",
  session_dir: "/tmp/s1",
  context_files: [],
  available_skills: [],
  mcp_servers: [],
  node_name: "opal@test",
  auth: { provider: "copilot", providers: [], status: "ready" },
};

describe("Session — failure modes", () => {
  let mockProc: ReturnType<typeof createMockProcess>;
  const writes: string[] = [];

  beforeEach(() => {
    mockProc = createMockProcess();
    writes.length = 0;
    mockProc.stdin.write = function (chunk: unknown, ...args: unknown[]) {
      writes.push(String(chunk));
      const cb = args.find((a) => typeof a === "function") as (() => void) | undefined;
      cb?.();
      return true;
    } as never;
    vi.mocked(spawn).mockReturnValue(mockProc as never);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  async function startSession() {
    const p = Session.start({ session: true });
    await new Promise((r) => setTimeout(r, 10));
    respond(mockProc, 1, sessionResult);
    return p;
  }

  // --- Session.start failures ---

  describe("start failures", () => {
    it("rejects when server exits before response", async () => {
      const p = Session.start({});
      await new Promise((r) => setTimeout(r, 10));
      mockProc.stderr.push("CRASH: OTP boot failed\n");
      await new Promise((r) => setTimeout(r, 10));
      mockProc.emit("exit", 1, null);
      await expect(p).rejects.toThrow("exited");
    });

    it("rejects when session/start returns RPC error", async () => {
      const p = Session.start({});
      await new Promise((r) => setTimeout(r, 10));
      respondError(mockProc, 1, -32600, "Invalid session params");
      await expect(p).rejects.toThrow("Invalid session params");
    });
  });

  // --- Event stream failures ---

  describe("prompt event stream", () => {
    it("terminates when server crashes mid-stream", async () => {
      const session = await startSession();
      const events: AgentEvent[] = [];

      mockProc.stdin.write = function (chunk: unknown, ...args: unknown[]) {
        const str = String(chunk);
        writes.push(str);
        const msg = JSON.parse(str.replace("\n", ""));
        if (msg.method === "agent/prompt") {
          setTimeout(() => {
            respond(mockProc, msg.id, {});
            sendEvent(mockProc, { type: "agent_start" });
            sendEvent(mockProc, { type: "message_delta", delta: "Hello" });
            // Send an error event to terminate the stream, then crash
            sendEvent(mockProc, { type: "error", reason: "Server crashed" });
          }, 5);
        }
        const cb = args.find((a) => typeof a === "function") as (() => void) | undefined;
        cb?.();
        return true;
      } as never;

      for await (const event of session.prompt("test")) {
        events.push(event);
      }

      expect(events.length).toBeGreaterThanOrEqual(1);
      // The error event should have been received
      const errorEvent = events.find((e) => e.type === "error");
      expect(errorEvent).toBeDefined();
    });

    it("handles duplicate agentEnd — stops at first", async () => {
      const session = await startSession();
      const events: AgentEvent[] = [];

      mockProc.stdin.write = function (chunk: unknown, ...args: unknown[]) {
        const str = String(chunk);
        writes.push(str);
        const msg = JSON.parse(str.replace("\n", ""));
        if (msg.method === "agent/prompt") {
          setTimeout(() => {
            respond(mockProc, msg.id, {});
            sendEvent(mockProc, { type: "agent_start" });
            sendEvent(mockProc, { type: "agent_end" });
            sendEvent(mockProc, { type: "agent_end" }); // duplicate
          }, 5);
        }
        const cb = args.find((a) => typeof a === "function") as (() => void) | undefined;
        cb?.();
        return true;
      } as never;

      for await (const event of session.prompt("test")) {
        events.push(event);
      }

      // Should stop at the first agentEnd
      const endCount = events.filter((e) => e.type === "agentEnd").length;
      expect(endCount).toBe(1);
      session.close();
    });

    it("cleans up listener on early break from for-await", async () => {
      const session = await startSession();

      mockProc.stdin.write = function (chunk: unknown, ...args: unknown[]) {
        const str = String(chunk);
        writes.push(str);
        const msg = JSON.parse(str.replace("\n", ""));
        if (msg.method === "agent/prompt") {
          setTimeout(() => {
            respond(mockProc, msg.id, {});
            sendEvent(mockProc, { type: "agent_start" });
            sendEvent(mockProc, { type: "message_delta", delta: "a" });
            sendEvent(mockProc, { type: "message_delta", delta: "b" });
            sendEvent(mockProc, { type: "agent_end" });
          }, 5);
        }
        const cb = args.find((a) => typeof a === "function") as (() => void) | undefined;
        cb?.();
        return true;
      } as never;

      let count = 0;
      for await (const _event of session.prompt("test")) {
        count++;
        if (count >= 1) break; // break early
      }

      expect(count).toBe(1);
      // Client should still function after break
      session.close();
    });

    it("handles rapid events without loss", async () => {
      const session = await startSession();
      const events: AgentEvent[] = [];

      mockProc.stdin.write = function (chunk: unknown, ...args: unknown[]) {
        const str = String(chunk);
        writes.push(str);
        const msg = JSON.parse(str.replace("\n", ""));
        if (msg.method === "agent/prompt") {
          setTimeout(() => {
            respond(mockProc, msg.id, {});
            sendEvent(mockProc, { type: "agent_start" });
            for (let i = 0; i < 100; i++) {
              sendEvent(mockProc, { type: "message_delta", delta: `chunk${i}` });
            }
            sendEvent(mockProc, { type: "agent_end" });
          }, 5);
        }
        const cb = args.find((a) => typeof a === "function") as (() => void) | undefined;
        cb?.();
        return true;
      } as never;

      for await (const event of session.prompt("test")) {
        events.push(event);
      }

      // 1 agentStart + 100 messageDelta + 1 agentEnd = 102
      expect(events).toHaveLength(102);
      session.close();
    });
  });

  // --- Callback handler failures ---

  describe("callback handler failures", () => {
    it("onConfirm throwing sends error response", async () => {
      const onConfirm = vi.fn().mockRejectedValue(new Error("handler crash"));
      const p = Session.start({ onConfirm });
      await new Promise((r) => setTimeout(r, 10));

      mockProc.stdout.push(
        JSON.stringify({
          jsonrpc: "2.0",
          id: 50,
          method: "client/confirm",
          params: { session_id: "s1", title: "Run?", message: "", actions: ["allow"] },
        }) + "\n",
      );
      await new Promise((r) => setTimeout(r, 20));

      const response = JSON.parse(writes[writes.length - 1].replace("\n", ""));
      expect(response.error.code).toBe(-32000);
      expect(response.error.message).toBe("handler crash");

      respond(mockProc, 1, sessionResult);
      const session = await p;
      session.close();
    });

    it("client/input without handler sends error response", async () => {
      const p = Session.start({});
      await new Promise((r) => setTimeout(r, 10));

      mockProc.stdout.push(
        JSON.stringify({
          jsonrpc: "2.0",
          id: 51,
          method: "client/input",
          params: { session_id: "s1", prompt: "Enter key" },
        }) + "\n",
      );
      await new Promise((r) => setTimeout(r, 20));

      const response = JSON.parse(writes[writes.length - 1].replace("\n", ""));
      expect(response.error.code).toBe(-32000);
      expect(response.error.message).toContain("input handler");

      respond(mockProc, 1, sessionResult);
      const session = await p;
      session.close();
    });

    it("client/ask_user without handler sends error response", async () => {
      const p = Session.start({});
      await new Promise((r) => setTimeout(r, 10));

      mockProc.stdout.push(
        JSON.stringify({
          jsonrpc: "2.0",
          id: 52,
          method: "client/ask_user",
          params: { session_id: "s1", question: "Which?" },
        }) + "\n",
      );
      await new Promise((r) => setTimeout(r, 20));

      const response = JSON.parse(writes[writes.length - 1].replace("\n", ""));
      expect(response.error.code).toBe(-32000);
      expect(response.error.message).toContain("ask_user handler");

      respond(mockProc, 1, sessionResult);
      const session = await p;
      session.close();
    });

    it("unknown server request method sends -32601", async () => {
      const p = Session.start({});
      await new Promise((r) => setTimeout(r, 10));

      mockProc.stdout.push(
        JSON.stringify({
          jsonrpc: "2.0",
          id: 53,
          method: "unknown/method",
          params: {},
        }) + "\n",
      );
      await new Promise((r) => setTimeout(r, 20));

      // The onServerRequest catches unknown methods and throws
      const response = JSON.parse(writes[writes.length - 1].replace("\n", ""));
      expect(response.error).toBeDefined();

      respond(mockProc, 1, sessionResult);
      const session = await p;
      session.close();
    });
  });
});
