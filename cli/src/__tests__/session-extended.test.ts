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

describe("Session — extended coverage", () => {
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

  // --- Uncovered method param paths ---

  it("setModel without thinkingLevel omits it from params", async () => {
    const session = await startSession();
    const p = session.setModel("gpt-4");
    await new Promise((r) => setTimeout(r, 10));
    respond(mockProc, 2, { model: { id: "gpt-4", provider: "copilot" } });
    await p;

    const msg = JSON.parse(writes[writes.length - 1].replace("\n", ""));
    expect(msg.params.thinking_level).toBeUndefined();
    session.close();
  });

  it("compact without keepRecent omits it from params", async () => {
    const session = await startSession();
    const p = session.compact();
    await new Promise((r) => setTimeout(r, 10));
    respond(mockProc, 2, {});
    await p;

    const msg = JSON.parse(writes[writes.length - 1].replace("\n", ""));
    expect(msg.params.keep_recent).toBeUndefined();
    session.close();
  });

  it("authPoll sends deviceCode and interval", async () => {
    const session = await startSession();
    const p = session.authPoll("dc-123", 5);
    await new Promise((r) => setTimeout(r, 10));
    respond(mockProc, 2, { authenticated: true });
    await p;

    const msg = JSON.parse(writes[writes.length - 1].replace("\n", ""));
    expect(msg.params.device_code).toBe("dc-123");
    expect(msg.params.interval).toBe(5);
    session.close();
  });

  // --- Uncovered dispatch branches ---

  it("dispatches thinkingStart event", async () => {
    const session = await startSession();
    const starts: boolean[] = [];
    session.on("thinkingStart", () => starts.push(true));

    sendEvent(mockProc, { type: "thinking_start" });
    await new Promise((r) => setTimeout(r, 10));

    expect(starts).toHaveLength(1);
    session.close();
  });

  it("dispatches thinkingDelta event with delta", async () => {
    const session = await startSession();
    const deltas: string[] = [];
    session.on("thinkingDelta", (delta) => deltas.push(delta));

    sendEvent(mockProc, { type: "thinking_delta", delta: "I think..." });
    await new Promise((r) => setTimeout(r, 10));

    expect(deltas).toEqual(["I think..."]);
    session.close();
  });

  it("dispatches agentAbort event", async () => {
    const session = await startSession();
    const aborts: boolean[] = [];
    session.on("agentAbort", () => aborts.push(true));

    sendEvent(mockProc, { type: "agent_abort" });
    await new Promise((r) => setTimeout(r, 10));

    expect(aborts).toHaveLength(1);
    session.close();
  });

  it("dispatches agentEnd with usage data", async () => {
    const session = await startSession();
    const usages: unknown[] = [];
    session.on("agentEnd", (usage) => usages.push(usage));

    sendEvent(mockProc, {
      type: "agent_end",
      usage: {
        prompt_tokens: 100,
        completion_tokens: 50,
        total_tokens: 150,
        context_window: 128000,
        current_context_tokens: 200,
      },
    });
    await new Promise((r) => setTimeout(r, 10));

    expect(usages).toHaveLength(1);
    expect(usages[0]).toBeDefined();
    session.close();
  });

  it("dispatches agentEnd without usage", async () => {
    const session = await startSession();
    const usages: unknown[] = [];
    session.on("agentEnd", (usage) => usages.push(usage));

    sendEvent(mockProc, { type: "agent_end" });
    await new Promise((r) => setTimeout(r, 10));

    expect(usages).toHaveLength(1);
    expect(usages[0]).toBeUndefined();
    session.close();
  });

  it("dispatches messageStart event", async () => {
    const session = await startSession();
    const starts: boolean[] = [];
    session.on("messageStart", () => starts.push(true));

    sendEvent(mockProc, { type: "message_start" });
    await new Promise((r) => setTimeout(r, 10));

    expect(starts).toHaveLength(1);
    session.close();
  });

  it("multiple handlers on same event — all called", async () => {
    const session = await startSession();
    const calls: number[] = [];
    session.on("agentStart", () => calls.push(1));
    session.on("agentStart", () => calls.push(2));

    sendEvent(mockProc, { type: "agent_start" });
    await new Promise((r) => setTimeout(r, 10));

    expect(calls).toEqual([1, 2]);
    session.close();
  });

  it("event with no listeners does not crash", async () => {
    const session = await startSession();
    // No listeners registered — just send event
    sendEvent(mockProc, { type: "agent_start" });
    sendEvent(mockProc, { type: "message_delta", delta: "hello" });
    await new Promise((r) => setTimeout(r, 10));
    // No crash
    session.close();
  });

  it("unknown event type does not crash dispatch", async () => {
    const session = await startSession();
    // Send an event type that doesn't exist in the switch
    sendEvent(mockProc, { type: "totally_unknown_event", data: "foo" });
    await new Promise((r) => setTimeout(r, 10));
    // Should not crash
    session.close();
  });
});
