import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { EventEmitter, Readable, Writable } from "node:stream";

vi.mock("node:child_process", () => ({ spawn: vi.fn() }));
vi.mock("../../sdk/resolve.js", () => ({
  resolveServer: () => ({ command: "/fake/opal-server", args: [] }),
}));

import { spawn } from "node:child_process";
import { createSession } from "../../sdk/session.js";
import type { AgentEvent } from "../../sdk/protocol.js";

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

// ── Helpers ──────────────────────────────────────────────────────────

let mockProc: ReturnType<typeof createMockProcess>;
let writes: string[];

function captureWrites() {
  writes = [];
  mockProc.stdin.write = function (chunk: unknown, ...args: unknown[]) {
    writes.push(String(chunk));
    const cb = args.find((a) => typeof a === "function") as (() => void) | undefined;
    cb?.();
    return true;
  } as never;
}

function respondNext(result: unknown) {
  setTimeout(() => {
    const lastWrite = writes[writes.length - 1];
    const msg = JSON.parse(lastWrite.replace("\n", ""));
    mockProc.stdout.push(JSON.stringify({ jsonrpc: "2.0", id: msg.id, result }) + "\n");
  }, 5);
}

function sendEvent(type: string, extra: Record<string, unknown> = {}) {
  mockProc.stdout.push(
    JSON.stringify({
      jsonrpc: "2.0",
      method: "agent/event",
      params: { type, ...extra },
    }) + "\n",
  );
}

// ── Setup / Teardown ─────────────────────────────────────────────────

beforeEach(() => {
  mockProc = createMockProcess();
  vi.mocked(spawn).mockReturnValue(mockProc as never);
  captureWrites();
});

afterEach(() => {
  vi.restoreAllMocks();
});

// ── Start helper ─────────────────────────────────────────────────────

const SESSION_START_RESULT = {
  session_id: "s1",
  session_dir: "/tmp/s1",
  context_files: ["AGENTS.md"],
  available_skills: ["git"],
  mcp_servers: [],
  node_name: "opal@localhost",
  auth: { status: "ready", provider: "copilot", providers: [] },
};

async function startSession(opts = {}) {
  const p = createSession({ workingDir: "/test", ...opts });
  await new Promise((r) => setTimeout(r, 10));
  const startReq = JSON.parse(writes[writes.length - 1].replace("\n", ""));
  mockProc.stdout.push(
    JSON.stringify({ jsonrpc: "2.0", id: startReq.id, result: SESSION_START_RESULT }) + "\n",
  );
  return p;
}

// ── Tests ────────────────────────────────────────────────────────────

describe("SDK2 Session", () => {
  it("createSession returns a session with correct properties", async () => {
    const session = await startSession();
    expect(session.id).toBe("s1");
    expect(session.dir).toBe("/tmp/s1");
    expect(session.contextFiles).toEqual(["AGENTS.md"]);
    expect(session.skills).toEqual(["git"]);
    expect(session.auth.status).toBe("ready");
    session.close();
  });

  it("prompt() streams events", async () => {
    const session = await startSession();
    const events: AgentEvent[] = [];

    mockProc.stdin.write = function (chunk: unknown, ...args: unknown[]) {
      const str = String(chunk);
      writes.push(str);
      const msg = JSON.parse(str.replace("\n", ""));
      if (msg.method === "agent/prompt") {
        setTimeout(() => {
          // Respond to the prompt request, then send events
          mockProc.stdout.push(JSON.stringify({ jsonrpc: "2.0", id: msg.id, result: {} }) + "\n");
          sendEvent("agent_start");
          sendEvent("message_delta", { delta: "Hi" });
          sendEvent("agent_end");
        }, 5);
      }
      const cb = args.find((a) => typeof a === "function") as (() => void) | undefined;
      cb?.();
      return true;
    } as never;

    for await (const event of session.prompt("hi")) {
      events.push(event);
    }

    expect(events).toHaveLength(3);
    expect(events[0].type).toBe("agentStart");
    expect(events[1].type).toBe("messageDelta");
    expect(events[2].type).toBe("agentEnd");
    session.close();
  });

  it("send() returns queued status", async () => {
    const session = await startSession();
    const p = session.send("focus on tests");
    await new Promise((r) => setTimeout(r, 10));
    respondNext({ queued: true });
    const result = await p;
    expect(result).toEqual({ queued: true });
    session.close();
  });

  it("abort() sends agent/abort", async () => {
    const session = await startSession();
    const p = session.abort();
    await new Promise((r) => setTimeout(r, 10));
    respondNext({});
    await p;

    const msg = JSON.parse(writes[writes.length - 1].replace("\n", ""));
    expect(msg.method).toBe("agent/abort");
    session.close();
  });

  it("state() returns agent state", async () => {
    const session = await startSession();
    const p = session.state();
    await new Promise((r) => setTimeout(r, 10));
    respondNext({ status: "idle", messages: [] });
    const result = await p;
    expect(result).toBeDefined();
    expect(result.status).toBe("idle");
    session.close();
  });

  it("models() returns model list", async () => {
    const session = await startSession();
    const p = session.models();
    await new Promise((r) => setTimeout(r, 10));
    respondNext({ models: [{ id: "gpt-4", name: "GPT-4" }] });
    const result = await p;
    expect(result.models).toHaveLength(1);
    expect(result.models[0].id).toBe("gpt-4");
    session.close();
  });

  it("setModel() with string sends model_id on wire", async () => {
    const session = await startSession();
    const p = session.setModel("gpt-4");
    await new Promise((r) => setTimeout(r, 10));
    respondNext({ model: { id: "gpt-4", provider: "copilot" } });
    await p;

    const msg = JSON.parse(writes[writes.length - 1].replace("\n", ""));
    expect(msg.method).toBe("model/set");
    expect(msg.params.model_id).toBe("gpt-4");
    session.close();
  });

  it("config.getRuntime() returns features and tools", async () => {
    const session = await startSession();
    const p = session.config.getRuntime();
    await new Promise((r) => setTimeout(r, 10));
    respondNext({
      features: { debug: false, mcp: true, skills: true, sub_agents: true },
      tools: { all: ["read_file"], enabled: ["read_file"], disabled: [] },
    });
    const result = await p;
    expect(result.features).toBeDefined();
    expect(result.tools.all).toEqual(["read_file"]);
    session.close();
  });

  it("auth_.login() returns login result", async () => {
    const session = await startSession();
    const p = session.auth_.login();
    await new Promise((r) => setTimeout(r, 10));
    respondNext({
      user_code: "ABCD-1234",
      verification_uri: "https://github.com/login/device",
      device_code: "dc123",
      interval: 5,
    });
    const result = await p;
    expect(result.userCode).toBe("ABCD-1234");
    expect(result.verificationUri).toBe("https://github.com/login/device");
    session.close();
  });

  it("close() terminates without throwing", async () => {
    const session = await startSession();
    expect(() => session.close()).not.toThrow();
  });

  it("autoConfirm sends allow", async () => {
    const p = createSession({ workingDir: "/test", autoConfirm: true });
    await new Promise((r) => setTimeout(r, 10));

    // Server sends a client/confirm request
    mockProc.stdout.push(
      JSON.stringify({
        jsonrpc: "2.0",
        id: 50,
        method: "client/confirm",
        params: {
          session_id: "s1",
          title: "Run shell?",
          message: "ls",
          actions: ["allow", "deny"],
        },
      }) + "\n",
    );
    await new Promise((r) => setTimeout(r, 20));

    const response = JSON.parse(writes[writes.length - 1].replace("\n", ""));
    expect(response.id).toBe(50);
    expect(response.result.action).toBe("allow");

    // Complete session/start
    const startReq = JSON.parse(writes[0].replace("\n", ""));
    mockProc.stdout.push(
      JSON.stringify({ jsonrpc: "2.0", id: startReq.id, result: SESSION_START_RESULT }) + "\n",
    );
    const session = await p;
    session.close();
  });

  it("callbacks.onConfirm is called and response is sent", async () => {
    const onConfirm = vi.fn().mockResolvedValue("allow");
    const p = createSession({
      workingDir: "/test",
      callbacks: { onConfirm },
    });
    await new Promise((r) => setTimeout(r, 10));

    mockProc.stdout.push(
      JSON.stringify({
        jsonrpc: "2.0",
        id: 51,
        method: "client/confirm",
        params: { session_id: "s1", title: "Run?", message: "cmd", actions: ["allow", "deny"] },
      }) + "\n",
    );
    await new Promise((r) => setTimeout(r, 20));

    expect(onConfirm).toHaveBeenCalled();
    const response = JSON.parse(writes[writes.length - 1].replace("\n", ""));
    expect(response.id).toBe(51);
    expect(response.result.action).toBe("allow");

    const startReq = JSON.parse(writes[0].replace("\n", ""));
    mockProc.stdout.push(
      JSON.stringify({ jsonrpc: "2.0", id: startReq.id, result: SESSION_START_RESULT }) + "\n",
    );
    const session = await p;
    session.close();
  });
});
