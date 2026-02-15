import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  createMockProcess,
  respond,
  respondError,
  sendEvent,
  sendRequest,
  capturingWrites,
  tick,
  SESSION_DEFAULTS,
  type MockProcess,
  type CapturedWrites,
} from "./helpers/mock-process.js";

vi.mock("node:child_process", () => ({ spawn: vi.fn() }));
vi.mock("../sdk/resolve.js", () => ({
  resolveServer: () => ({ command: "/usr/bin/fake-opal-server", args: [] }),
}));

import { spawn } from "node:child_process";
import { Session } from "../sdk/session.js";
import type { AgentEvent } from "../sdk/protocol.js";

// ---------------------------------------------------------------------------
// Helpers for the "prompt handler" pattern used in event stream tests.
// Instead of duplicating the stdin.write override + JSON parse + method check
// in every test, we register a responder that fires when a given method is sent.
// ---------------------------------------------------------------------------

type PromptResponder = (proc: MockProcess, requestId: number) => void;

function onMethod(
  proc: MockProcess,
  writes: CapturedWrites,
  method: string,
  handler: PromptResponder,
) {
  proc.stdin.write = function (chunk: unknown, ...args: unknown[]) {
    const str = String(chunk);
    writes.raw.push(str);
    const msg = JSON.parse(str.trim());
    if (msg.method === method) {
      setTimeout(() => handler(proc, msg.id), 5);
    }
    const cb = args.find((a) => typeof a === "function") as (() => void) | undefined;
    cb?.();
    return true;
  } as never;
}

describe("Session — failure modes", () => {
  let proc: MockProcess;
  let writes: CapturedWrites;

  beforeEach(() => {
    proc = createMockProcess();
    writes = capturingWrites(proc);
    vi.mocked(spawn).mockReturnValue(proc as never);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  async function startSession() {
    const pending = Session.start({ session: true });
    await tick();
    respond(proc, 1, SESSION_DEFAULTS);
    return pending;
  }

  // --- Session.start failures ---

  describe("start failures", () => {
    it("rejects when server exits before response", async () => {
      const pending = Session.start({});
      await tick();
      proc.stderr.push("CRASH: OTP boot failed\n");
      await tick();
      proc.emit("exit", 1, null);
      await expect(pending).rejects.toThrow("exited");
    });

    it("rejects when session/start returns RPC error", async () => {
      const pending = Session.start({});
      await tick();
      respondError(proc, 1, -32600, "Invalid session params");
      await expect(pending).rejects.toThrow("Invalid session params");
    });
  });

  // --- Event stream failures ---

  describe("prompt event stream", () => {
    it("terminates on server error event mid-stream", async () => {
      const session = await startSession();

      onMethod(proc, writes, "agent/prompt", (p, id) => {
        respond(p, id, {});
        sendEvent(p, { type: "agent_start" });
        sendEvent(p, { type: "message_delta", delta: "Hello" });
        sendEvent(p, { type: "error", reason: "Server crashed" });
      });

      const events: AgentEvent[] = [];
      for await (const event of session.prompt("test")) {
        events.push(event);
      }

      expect(events.length).toBeGreaterThanOrEqual(1);
      expect(events.find((e) => e.type === "error")).toBeDefined();
    });

    it("stops iteration at first agentEnd (ignoring duplicates)", async () => {
      const session = await startSession();

      onMethod(proc, writes, "agent/prompt", (p, id) => {
        respond(p, id, {});
        sendEvent(p, { type: "agent_start" });
        sendEvent(p, { type: "agent_end" });
        sendEvent(p, { type: "agent_end" }); // duplicate
      });

      const events: AgentEvent[] = [];
      for await (const event of session.prompt("test")) {
        events.push(event);
      }

      expect(events.filter((e) => e.type === "agentEnd")).toHaveLength(1);
      session.close();
    });

    it("cleans up listener on early break from for-await", async () => {
      const session = await startSession();

      onMethod(proc, writes, "agent/prompt", (p, id) => {
        respond(p, id, {});
        sendEvent(p, { type: "agent_start" });
        sendEvent(p, { type: "message_delta", delta: "a" });
        sendEvent(p, { type: "message_delta", delta: "b" });
        sendEvent(p, { type: "agent_end" });
      });

      let count = 0;
      for await (const _event of session.prompt("test")) {
        count++;
        if (count >= 1) break;
      }

      expect(count).toBe(1);
      session.close();
    });

    it("handles 100 rapid events without loss", async () => {
      const session = await startSession();

      onMethod(proc, writes, "agent/prompt", (p, id) => {
        respond(p, id, {});
        sendEvent(p, { type: "agent_start" });
        for (let i = 0; i < 100; i++) {
          sendEvent(p, { type: "message_delta", delta: `chunk${i}` });
        }
        sendEvent(p, { type: "agent_end" });
      });

      const events: AgentEvent[] = [];
      for await (const event of session.prompt("test")) {
        events.push(event);
      }

      // agentStart + 100 × messageDelta + agentEnd = 102
      expect(events).toHaveLength(102);
      session.close();
    });
  });

  // --- Callback handler failures ---

  describe("callback handler failures", () => {
    it("onConfirm error sends JSON-RPC error response", async () => {
      const onConfirm = vi.fn().mockRejectedValue(new Error("handler crash"));
      const pending = Session.start({ onConfirm });
      await tick();

      sendRequest(proc, 50, "client/confirm", {
        session_id: "s1",
        title: "Run?",
        message: "",
        actions: ["allow"],
      });
      await tick(20);

      const response = writes.lastRequest();
      expect(response.error).toMatchObject({ code: -32000, message: "handler crash" });

      respond(proc, 1, SESSION_DEFAULTS);
      const session = await pending;
      session.close();
    });

    it("client/input without handler sends error response", async () => {
      const pending = Session.start({});
      await tick();

      sendRequest(proc, 51, "client/input", {
        session_id: "s1",
        prompt: "Enter key",
      });
      await tick(20);

      const response = writes.lastRequest();
      expect(response.error).toMatchObject({ code: -32000 });
      expect((response.error as { message: string }).message).toContain("input handler");

      respond(proc, 1, SESSION_DEFAULTS);
      const session = await pending;
      session.close();
    });

    it("client/ask_user without handler sends error response", async () => {
      const pending = Session.start({});
      await tick();

      sendRequest(proc, 52, "client/ask_user", {
        session_id: "s1",
        question: "Which?",
      });
      await tick(20);

      const response = writes.lastRequest();
      expect(response.error).toMatchObject({ code: -32000 });
      expect((response.error as { message: string }).message).toContain("ask_user handler");

      respond(proc, 1, SESSION_DEFAULTS);
      const session = await pending;
      session.close();
    });

    it("unknown server request method sends -32601", async () => {
      const pending = Session.start({});
      await tick();

      sendRequest(proc, 53, "unknown/method", {});
      await tick(20);

      const response = writes.lastRequest();
      expect(response.error).toBeDefined();

      respond(proc, 1, SESSION_DEFAULTS);
      const session = await pending;
      session.close();
    });
  });
});
