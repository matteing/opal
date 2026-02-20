import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  createMockProcess,
  respond,
  respondError,
  sendEvent,
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

describe("Integration failures", () => {
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

  // --- Auth flow failures ---

  describe("auth flow failures", () => {
    it("authPoll timeout rejects", async () => {
      const session = await startSession();
      const pending = session.authPoll("dc-123", 5);
      await tick();
      respondError(proc, 2, -32000, "Authorization expired");
      await expect(pending).rejects.toThrow("Authorization expired");
      session.close();
    });
  });

  // --- Model switching ---

  describe("model switching failures", () => {
    it("setModel with unknown model returns error", async () => {
      const session = await startSession();
      const pending = session.setModel("nonexistent-model");
      await tick();
      respondError(proc, 2, -32000, "Unknown model: nonexistent-model");
      await expect(pending).rejects.toThrow("Unknown model");
      session.close();
    });

    it("listModels returns empty array", async () => {
      const session = await startSession();
      const pending = session.listModels();
      await tick();
      respond(proc, 2, { models: [] });
      const result = await pending;
      expect(result.models).toEqual([]);
      session.close();
    });

    it("setModel during active prompt — both resolve independently", async () => {
      const session = await startSession();

      // prompt() is an async generator — its body runs lazily on iteration.
      // Start iterating in the background to trigger the agent/prompt request.
      const events: Array<{ type: string }> = [];
      const promptDone = (async () => {
        for await (const event of session.prompt("test")) {
          events.push(event);
        }
      })();
      await tick(20);

      // Respond to the prompt request
      const promptReq = writes.findByMethod("agent/prompt");
      expect(promptReq).toBeDefined();
      respond(proc, promptReq!.id as number, {});
      await tick();

      // Fire a concurrent setModel while the prompt stream is open
      const modelPending = session.setModel("gpt-4o");
      await tick();
      const modelReq = writes.findByMethod("model/set");
      expect(modelReq).toBeDefined();
      respond(proc, modelReq!.id as number, {
        model: { id: "gpt-4o", provider: "copilot", thinking_level: "off" },
      });

      const modelResult = await modelPending;
      expect(modelResult.model.id).toBe("gpt-4o");

      // End the prompt stream
      sendEvent(proc, { type: "agent_end" });

      await promptDone;
      expect(events.some((e) => e.type === "agentEnd")).toBe(true);
      session.close();
    });
  });

  // --- Compaction failures ---

  describe("compaction failures", () => {
    it("compact error is surfaced to caller", async () => {
      const session = await startSession();
      const pending = session.compact();
      await tick();
      respondError(proc, 2, -32000, "Compaction failed: no messages");
      await expect(pending).rejects.toThrow("Compaction failed");
      session.close();
    });
  });

  // --- Settings failures ---

  describe("settings failures", () => {
    it("saveSettings error is surfaced", async () => {
      const session = await startSession();
      const pending = session.saveSettings({ model: "test" });
      await tick();
      respondError(proc, 2, -32000, "Disk full");
      await expect(pending).rejects.toThrow("Disk full");
      session.close();
    });

    it("getSettings with empty result", async () => {
      const session = await startSession();
      const pending = session.getSettings();
      await tick();
      respond(proc, 2, { settings: {} });
      const result = await pending;
      expect(result.settings).toEqual({});
      session.close();
    });
  });

  // --- Opal config failures ---

  describe("opal config failures", () => {
    it("getOpalConfig error is surfaced", async () => {
      const session = await startSession();
      const pending = session.getOpalConfig();
      await tick();
      respondError(proc, 2, -32000, "Session not found");
      await expect(pending).rejects.toThrow("Session not found");
      session.close();
    });

    it("setOpalConfig error is surfaced", async () => {
      const session = await startSession();
      const pending = session.setOpalConfig({
        features: { debug: true, mcp: true, skills: true, subAgents: true },
      });
      await tick();
      respondError(proc, 2, -32000, "Invalid config");
      await expect(pending).rejects.toThrow("Invalid config");
      session.close();
    });
  });

  // --- Concurrent operations ---

  describe("concurrent operations", () => {
    it("out-of-order responses resolve to correct callers", async () => {
      const session = await startSession();
      const stateP = session.getState();
      const modelsP = session.listModels();
      const settingsP = session.getSettings();
      await tick();

      // Respond out of order: settings, state, models
      respond(proc, 4, { settings: { key: "val" } });
      respond(proc, 2, { status: "idle", model: { id: "gpt-4" } });
      respond(proc, 3, { models: [{ id: "gpt-4" }] });

      const [state, models, settings] = await Promise.all([stateP, modelsP, settingsP]);
      expect(state.status).toBe("idle");
      expect(models.models).toHaveLength(1);
      expect(settings.settings.key).toBe("val");
      session.close();
    });

    it("events interleaved with requests are not lost", async () => {
      const session = await startSession();
      const received: unknown[] = [];
      session.on("messageDelta", (delta: string) => received.push(delta));

      sendEvent(proc, { type: "message_delta", delta: "hello" });

      const pending = session.getState();
      await tick();
      respond(proc, 2, { status: "running" });
      await pending;

      sendEvent(proc, { type: "message_delta", delta: " world" });
      await tick();

      expect(received).toEqual(["hello", " world"]);
      session.close();
    });
  });
});
