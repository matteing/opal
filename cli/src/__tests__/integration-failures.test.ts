import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { EventEmitter, Readable, Writable } from "node:stream";

vi.mock("node:child_process", () => ({ spawn: vi.fn() }));
vi.mock("../sdk/resolve.js", () => ({
  resolveServer: () => ({ command: "/usr/bin/fake-opal-server", args: [] }),
}));

import { spawn } from "node:child_process";
import { Session } from "../sdk/session.js";

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
  msg: string,
) {
  proc.stdout.push(JSON.stringify({ jsonrpc: "2.0", id, error: { code, message: msg } }) + "\n");
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

describe("Integration failures", () => {
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

  // --- Auth flow failures ---

  describe("auth flow failures", () => {
    it("authPoll timeout rejects", async () => {
      const session = await startSession();
      const p = session.authPoll("dc-123", 5);
      await new Promise((r) => setTimeout(r, 10));
      // Server returns error
      respondError(mockProc, 2, -32000, "Authorization expired");
      await expect(p).rejects.toThrow("Authorization expired");
      session.close();
    });

    it("authSetKey with invalid key returns error", async () => {
      const session = await startSession();
      const p = session.authSetKey("anthropic", "bad-key");
      await new Promise((r) => setTimeout(r, 10));
      respondError(mockProc, 2, -32000, "Invalid API key");
      await expect(p).rejects.toThrow("Invalid API key");
      session.close();
    });
  });

  // --- Model switching ---

  describe("model switching failures", () => {
    it("setModel with unknown model returns error", async () => {
      const session = await startSession();
      const p = session.setModel("nonexistent-model");
      await new Promise((r) => setTimeout(r, 10));
      respondError(mockProc, 2, -32000, "Unknown model: nonexistent-model");
      await expect(p).rejects.toThrow("Unknown model");
      session.close();
    });

    it("listModels returns empty array", async () => {
      const session = await startSession();
      const p = session.listModels();
      await new Promise((r) => setTimeout(r, 10));
      respond(mockProc, 2, { models: [] });
      const result = await p;
      expect(result.models).toEqual([]);
      session.close();
    });

    it("setModel during active prompt — both resolve independently", async () => {
      const session = await startSession();

      // prompt() is an async generator — body runs lazily on iteration
      // Start iterating in background to trigger the request
      const events: Array<{ type: string }> = [];
      const promptDone = (async () => {
        for await (const event of session.prompt("test")) {
          events.push(event);
        }
      })();
      await new Promise((r) => setTimeout(r, 20));

      // Find and respond to the prompt request
      const parsed = writes.map((w) => {
        try {
          return JSON.parse(w.trim());
        } catch {
          return null;
        }
      });
      const promptReq = parsed.find((m) => m?.method === "agent/prompt");
      expect(promptReq).toBeDefined();
      respond(mockProc, promptReq!.id, {});
      await new Promise((r) => setTimeout(r, 10));

      // Now setModel concurrently
      const modelP = session.setModel("gpt-4o");
      await new Promise((r) => setTimeout(r, 10));
      const parsed2 = writes.map((w) => {
        try {
          return JSON.parse(w.trim());
        } catch {
          return null;
        }
      });
      const modelReq = parsed2.find((m) => m?.method === "model/set");
      expect(modelReq).toBeDefined();
      respond(mockProc, modelReq!.id, {
        model: { id: "gpt-4o", provider: "copilot", thinking_level: "off" },
      });

      const modelResult = await modelP;
      expect(modelResult.model.id).toBe("gpt-4o");

      // End the prompt stream
      mockProc.stdout.push(
        JSON.stringify({
          jsonrpc: "2.0",
          method: "agent/event",
          params: { type: "agent_end" },
        }) + "\n",
      );

      await promptDone;
      expect(events.some((e) => e.type === "agentEnd")).toBe(true);
      session.close();
    });
  });

  // --- Compaction failures ---

  describe("compaction failures", () => {
    it("compact returns error — surfaced to caller", async () => {
      const session = await startSession();
      const p = session.compact();
      await new Promise((r) => setTimeout(r, 10));
      respondError(mockProc, 2, -32000, "Compaction failed: no messages");
      await expect(p).rejects.toThrow("Compaction failed");
      session.close();
    });
  });

  // --- Settings failures ---

  describe("settings failures", () => {
    it("saveSettings failure is surfaced", async () => {
      const session = await startSession();
      const p = session.saveSettings({ model: "test" });
      await new Promise((r) => setTimeout(r, 10));
      respondError(mockProc, 2, -32000, "Disk full");
      await expect(p).rejects.toThrow("Disk full");
      session.close();
    });

    it("getSettings with empty result", async () => {
      const session = await startSession();
      const p = session.getSettings();
      await new Promise((r) => setTimeout(r, 10));
      respond(mockProc, 2, { settings: {} });
      const result = await p;
      expect(result.settings).toEqual({});
      session.close();
    });
  });

  // --- Opal config failures ---

  describe("opal config failures", () => {
    it("getOpalConfig failure is surfaced", async () => {
      const session = await startSession();
      const p = session.getOpalConfig();
      await new Promise((r) => setTimeout(r, 10));
      respondError(mockProc, 2, -32000, "Session not found");
      await expect(p).rejects.toThrow("Session not found");
      session.close();
    });

    it("setOpalConfig failure is surfaced", async () => {
      const session = await startSession();
      const p = session.setOpalConfig({
        features: { debug: true, mcp: true, skills: true, subAgents: true },
      });
      await new Promise((r) => setTimeout(r, 10));
      respondError(mockProc, 2, -32000, "Invalid config");
      await expect(p).rejects.toThrow("Invalid config");
      session.close();
    });
  });

  // --- Concurrent operations ---

  describe("concurrent operations", () => {
    it("multiple concurrent requests resolve independently", async () => {
      const session = await startSession();
      const p1 = session.getState();
      const p2 = session.listModels();
      const p3 = session.getSettings();

      await new Promise((r) => setTimeout(r, 10));

      // Respond out of order
      respond(mockProc, 4, { settings: { key: "val" } }); // id 4 = getSettings
      respond(mockProc, 2, { status: "idle", model: { id: "gpt-4" } }); // id 2 = getState
      respond(mockProc, 3, { models: [{ id: "gpt-4" }] }); // id 3 = listModels

      const [state, models, settings] = await Promise.all([p1, p2, p3]);
      expect(state.status).toBe("idle");
      expect(models.models).toHaveLength(1);
      expect(settings.settings.key).toBe("val");
      session.close();
    });

    it("request during event processing doesn't lose events", async () => {
      const session = await startSession();
      const events: unknown[] = [];
      session.on("messageDelta", (delta: string) => events.push(delta));

      // Send events while making a request
      mockProc.stdout.push(
        JSON.stringify({
          jsonrpc: "2.0",
          method: "agent/event",
          params: { type: "message_delta", delta: "hello" },
        }) + "\n",
      );

      const p = session.getState();
      await new Promise((r) => setTimeout(r, 10));
      respond(mockProc, 2, { status: "running" });
      await p;

      mockProc.stdout.push(
        JSON.stringify({
          jsonrpc: "2.0",
          method: "agent/event",
          params: { type: "message_delta", delta: " world" },
        }) + "\n",
      );
      await new Promise((r) => setTimeout(r, 10));

      expect(events).toEqual(["hello", " world"]);
      session.close();
    });
  });
});
