import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { EventEmitter, Readable, Writable } from "node:stream";

// Mock child_process and resolve before importing Session
vi.mock("node:child_process", () => ({
  spawn: vi.fn(),
}));

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

function respondToRequest(
  mockProc: ReturnType<typeof createMockProcess>,
  id: number,
  result: unknown,
) {
  mockProc.stdout.push(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
}

function sendNotification(
  mockProc: ReturnType<typeof createMockProcess>,
  method: string,
  params: unknown,
) {
  mockProc.stdout.push(JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n");
}

describe("Session", () => {
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

  async function startSession(opts = {}) {
    const p = Session.start(opts);
    // Wait for the session/start request to be written
    await new Promise((r) => setTimeout(r, 10));
    // Respond to session/start
    respondToRequest(mockProc, 1, {
      session_id: "test-session",
      session_dir: "/tmp/sessions/test",
      context_files: ["AGENTS.md"],
      available_skills: ["git"],
      mcp_servers: [],
      node_name: "opal@test",
      auth: { provider: "copilot", providers: [], status: "ready" },
    });
    return p;
  }

  it("start() creates session and stores metadata", async () => {
    const session = await startSession();
    expect(session.sessionId).toBe("test-session");
    expect(session.sessionDir).toBe("/tmp/sessions/test");
    expect(session.contextFiles).toEqual(["AGENTS.md"]);
    expect(session.availableSkills).toEqual(["git"]);
    expect(session.nodeName).toBe("opal@test");
    session.close();
  });

  it("prompt() sends agent/prompt and yields events", async () => {
    const session = await startSession();
    const events: AgentEvent[] = [];

    // Respond to agent/prompt right when it arrives
    mockProc.stdin.write = function (this: void, chunk: unknown, ...args: unknown[]) {
      const str = String(chunk);
      writes.push(str);
      const msg = JSON.parse(str.replace("\n", ""));
      if (msg.method === "agent/prompt") {
        // Respond immediately, then send events
        setTimeout(() => {
          respondToRequest(mockProc, msg.id, {});
          sendNotification(mockProc, "agent/event", { type: "agent_start" });
          sendNotification(mockProc, "agent/event", { type: "message_delta", delta: "Hi" });
          sendNotification(mockProc, "agent/event", { type: "agent_end" });
        }, 5);
      }
      const cb = args.find((a) => typeof a === "function") as (() => void) | undefined;
      cb?.();
      return true;
    } as never;

    for await (const event of session.prompt("Hello")) {
      events.push(event);
    }

    expect(events).toHaveLength(3);
    expect(events[0].type).toBe("agentStart");
    expect(events[2].type).toBe("agentEnd");
    session.close();
  });

  it("sendPrompt() sends agent/prompt without event stream", async () => {
    const session = await startSession();
    const p = session.sendPrompt("Focus on tests");
    await new Promise((r) => setTimeout(r, 10));
    respondToRequest(mockProc, 2, { queued: true });
    const result = await p;

    const msg = JSON.parse(writes[writes.length - 1].replace("\n", ""));
    expect(msg.method).toBe("agent/prompt");
    expect(msg.params.text).toBe("Focus on tests");
    expect(result).toEqual({ queued: true });
    session.close();
  });

  it("abort() sends agent/abort", async () => {
    const session = await startSession();
    const p = session.abort();
    await new Promise((r) => setTimeout(r, 10));
    respondToRequest(mockProc, 2, {});
    await p;

    const msg = JSON.parse(writes[writes.length - 1].replace("\n", ""));
    expect(msg.method).toBe("agent/abort");
    session.close();
  });

  it("getState() sends agent/state", async () => {
    const session = await startSession();
    const p = session.getState();
    await new Promise((r) => setTimeout(r, 10));
    respondToRequest(mockProc, 2, { state: "idle", messages: [] });
    const result = await p;
    expect(result).toBeDefined();
    session.close();
  });

  it("listModels() sends models/list", async () => {
    const session = await startSession();
    const p = session.listModels();
    await new Promise((r) => setTimeout(r, 10));
    respondToRequest(mockProc, 2, { models: [{ id: "gpt-4", name: "GPT-4" }] });
    const result = await p;
    expect(result.models).toHaveLength(1);
    session.close();
  });

  it("setModel() sends model/set", async () => {
    const session = await startSession();
    const p = session.setModel("claude-sonnet-4", "high");
    await new Promise((r) => setTimeout(r, 10));
    respondToRequest(mockProc, 2, {
      model: { id: "claude-sonnet-4", provider: "copilot", thinking_level: "high" },
    });
    await p;

    const msg = JSON.parse(writes[writes.length - 1].replace("\n", ""));
    expect(msg.params.model_id).toBe("claude-sonnet-4");
    expect(msg.params.thinking_level).toBe("high");
    session.close();
  });

  it("compact() sends session/compact", async () => {
    const session = await startSession();
    const p = session.compact(5);
    await new Promise((r) => setTimeout(r, 10));
    respondToRequest(mockProc, 2, {});
    await p;

    const msg = JSON.parse(writes[writes.length - 1].replace("\n", ""));
    expect(msg.params.keep_recent).toBe(5);
    session.close();
  });

  it("on() dispatches typed events correctly", async () => {
    const session = await startSession();

    const starts: unknown[] = [];
    const deltas: string[] = [];
    const tools: [string, string][] = [];

    session.on("agentStart", () => starts.push(true));
    session.on("messageDelta", (delta) => deltas.push(delta));
    session.on("toolExecutionStart", (tool, callId) => tools.push([tool, callId]));

    sendNotification(mockProc, "agent/event", { type: "agent_start" });
    sendNotification(mockProc, "agent/event", { type: "message_delta", delta: "Hello" });
    sendNotification(mockProc, "agent/event", {
      type: "tool_execution_start",
      tool: "read_file",
      call_id: "c1",
      args: {},
      meta: "",
    });
    await new Promise((r) => setTimeout(r, 20));

    expect(starts).toHaveLength(1);
    expect(deltas).toEqual(["Hello"]);
    expect(tools).toEqual([["read_file", "c1"]]);
    session.close();
  });

  it("on() dispatches error events", async () => {
    const session = await startSession();
    const errors: string[] = [];
    session.on("error", (reason) => errors.push(reason));

    sendNotification(mockProc, "agent/event", { type: "error", reason: "API failure" });
    await new Promise((r) => setTimeout(r, 10));

    expect(errors).toEqual(["API failure"]);
    session.close();
  });

  it("on() dispatches subAgentEvent", async () => {
    const session = await startSession();
    const events: [string, string, Record<string, unknown>][] = [];
    session.on("subAgentEvent", (parentCallId, subSessionId, inner) =>
      events.push([parentCallId, subSessionId, inner]),
    );

    sendNotification(mockProc, "agent/event", {
      type: "sub_agent_event",
      parent_call_id: "p1",
      sub_session_id: "sub1",
      inner: { type: "agent_start" },
    });
    await new Promise((r) => setTimeout(r, 10));

    expect(events).toHaveLength(1);
    expect(events[0][0]).toBe("p1");
    expect(events[0][1]).toBe("sub1");
    session.close();
  });

  it("handles onConfirm callback", async () => {
    const onConfirm = vi.fn().mockResolvedValue("allow");
    const p = Session.start({ onConfirm });
    await new Promise((r) => setTimeout(r, 10));

    // Server sends a confirm request
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

    expect(onConfirm).toHaveBeenCalled();
    const response = JSON.parse(writes[writes.length - 1].replace("\n", ""));
    expect(response.id).toBe(50);
    expect(response.result.action).toBe("allow");

    // Now respond to session/start to complete
    respondToRequest(mockProc, 1, {
      session_id: "s1",
      session_dir: "/tmp",
      context_files: [],
      available_skills: [],
      mcp_servers: [],
      node_name: "opal@test",
      auth: { provider: "copilot", providers: [], status: "ready" },
    });
    const session = await p;
    session.close();
  });

  it("autoConfirm returns 'allow' without onConfirm", async () => {
    const p = Session.start({ autoConfirm: true });
    await new Promise((r) => setTimeout(r, 10));

    mockProc.stdout.push(
      JSON.stringify({
        jsonrpc: "2.0",
        id: 50,
        method: "client/confirm",
        params: { session_id: "s1", title: "Run?", message: "", actions: ["allow", "deny"] },
      }) + "\n",
    );
    await new Promise((r) => setTimeout(r, 20));

    const response = JSON.parse(writes[writes.length - 1].replace("\n", ""));
    expect(response.result.action).toBe("allow");

    respondToRequest(mockProc, 1, {
      session_id: "s1",
      session_dir: "/tmp",
      context_files: [],
      available_skills: [],
      mcp_servers: [],
      node_name: "opal@test",
      auth: { provider: "copilot", providers: [], status: "ready" },
    });
    const session = await p;
    session.close();
  });

  it("ping() delegates to client.ping()", async () => {
    const session = await startSession();
    const p = session.ping(100);
    await new Promise((r) => setTimeout(r, 10));
    respondToRequest(mockProc, 2, {});
    await p;
    session.close();
  });

  it("close() kills server process", async () => {
    const session = await startSession();
    session.close();
    expect(mockProc.kill).toHaveBeenCalled();
  });

  it("authStatus() sends auth/status", async () => {
    const session = await startSession();
    const p = session.authStatus();
    await new Promise((r) => setTimeout(r, 10));
    respondToRequest(mockProc, 2, {
      authenticated: true,
      auth: { provider: "copilot", providers: [], status: "ready" },
    });
    const result = await p;
    expect(result.authenticated).toBe(true);
    session.close();
  });

  it("authLogin() sends auth/login", async () => {
    const session = await startSession();
    const p = session.authLogin();
    await new Promise((r) => setTimeout(r, 10));
    respondToRequest(mockProc, 2, {
      user_code: "ABCD-1234",
      verification_uri: "https://github.com/login/device",
      device_code: "dc123",
      interval: 5,
    });
    const result = await p;
    expect(result.userCode).toBe("ABCD-1234");
    session.close();
  });

  it("getSettings() sends settings/get", async () => {
    const session = await startSession();
    const p = session.getSettings();
    await new Promise((r) => setTimeout(r, 10));
    respondToRequest(mockProc, 2, { settings: { model: "gpt-4" } });
    const result = await p;
    expect(result.settings.model).toBe("gpt-4");
    session.close();
  });

  it("saveSettings() sends settings/save", async () => {
    const session = await startSession();
    const p = session.saveSettings({ model: "claude-sonnet-4" });
    await new Promise((r) => setTimeout(r, 10));
    respondToRequest(mockProc, 2, { settings: { model: "claude-sonnet-4" } });
    const result = await p;
    expect(result.settings.model).toBe("claude-sonnet-4");
    session.close();
  });

  it("getOpalConfig() sends opal/config/get", async () => {
    const session = await startSession();
    const p = session.getOpalConfig();
    await new Promise((r) => setTimeout(r, 10));
    respondToRequest(mockProc, 2, {
      features: { debug: false, mcp: true, skills: true, sub_agents: true },
      tools: { all: ["read_file"], enabled: ["read_file"], disabled: [] },
    });
    const result = await p;
    expect(result.features).toBeDefined();
    session.close();
  });

  it("setOpalConfig() sends opal/config/set", async () => {
    const session = await startSession();
    const p = session.setOpalConfig({
      features: { debug: true, mcp: true, skills: true, subAgents: true },
    });
    await new Promise((r) => setTimeout(r, 10));
    respondToRequest(mockProc, 2, {
      features: { debug: true, mcp: true, skills: true, sub_agents: true },
      tools: { all: [], enabled: [], disabled: [] },
    });
    await p;

    const msg = JSON.parse(writes[writes.length - 1].replace("\n", ""));
    expect(msg.params.features.debug).toBe(true);
    session.close();
  });

  it("setThinkingLevel() sends thinking/set", async () => {
    const session = await startSession();
    const p = session.setThinkingLevel("high");
    await new Promise((r) => setTimeout(r, 10));
    respondToRequest(mockProc, 2, { thinking_level: "high" });
    const result = await p;
    expect(result.thinkingLevel).toBe("high");
    session.close();
  });

  it("on() dispatches skillLoaded events", async () => {
    const session = await startSession();
    const skills: [string, string][] = [];
    session.on("skillLoaded", (name, description) => skills.push([name, description]));

    sendNotification(mockProc, "agent/event", {
      type: "skill_loaded",
      name: "git",
      description: "Git operations",
    });
    await new Promise((r) => setTimeout(r, 10));

    expect(skills).toEqual([["git", "Git operations"]]);
    session.close();
  });

  it("on() dispatches contextDiscovered events", async () => {
    const session = await startSession();
    const contexts: string[][] = [];
    session.on("contextDiscovered", (files) => contexts.push(files));

    sendNotification(mockProc, "agent/event", {
      type: "context_discovered",
      files: ["AGENTS.md", "README.md"],
    });
    await new Promise((r) => setTimeout(r, 10));

    expect(contexts).toEqual([["AGENTS.md", "README.md"]]);
    session.close();
  });

  it("denies confirmation when no onConfirm and not autoConfirm", async () => {
    const p = Session.start({});
    await new Promise((r) => setTimeout(r, 10));

    mockProc.stdout.push(
      JSON.stringify({
        jsonrpc: "2.0",
        id: 50,
        method: "client/confirm",
        params: { session_id: "s1", title: "Run?", message: "", actions: ["allow", "deny"] },
      }) + "\n",
    );
    await new Promise((r) => setTimeout(r, 20));

    const response = JSON.parse(writes[writes.length - 1].replace("\n", ""));
    expect(response.result.action).toBe("deny");

    respondToRequest(mockProc, 1, {
      session_id: "s1",
      session_dir: "/tmp",
      context_files: [],
      available_skills: [],
      mcp_servers: [],
      node_name: "opal@test",
      auth: { provider: "copilot", providers: [], status: "ready" },
    });
    const session = await p;
    session.close();
  });

  it("handles client/input with onInput", async () => {
    const onInput = vi.fn().mockResolvedValue("user-input");
    const p = Session.start({ onInput });
    await new Promise((r) => setTimeout(r, 10));

    mockProc.stdout.push(
      JSON.stringify({
        jsonrpc: "2.0",
        id: 51,
        method: "client/input",
        params: { session_id: "s1", prompt: "Enter API key", sensitive: true },
      }) + "\n",
    );
    await new Promise((r) => setTimeout(r, 20));

    expect(onInput).toHaveBeenCalled();
    const response = JSON.parse(writes[writes.length - 1].replace("\n", ""));
    expect(response.result.text).toBe("user-input");

    respondToRequest(mockProc, 1, {
      session_id: "s1",
      session_dir: "/tmp",
      context_files: [],
      available_skills: [],
      mcp_servers: [],
      node_name: "opal@test",
      auth: { provider: "copilot", providers: [], status: "ready" },
    });
    const session = await p;
    session.close();
  });

  it("handles client/ask_user with onAskUser", async () => {
    const onAskUser = vi.fn().mockResolvedValue("choice A");
    const p = Session.start({ onAskUser });
    await new Promise((r) => setTimeout(r, 10));

    mockProc.stdout.push(
      JSON.stringify({
        jsonrpc: "2.0",
        id: 52,
        method: "client/ask_user",
        params: { session_id: "s1", question: "Which?", choices: ["A", "B"] },
      }) + "\n",
    );
    await new Promise((r) => setTimeout(r, 20));

    expect(onAskUser).toHaveBeenCalled();
    const response = JSON.parse(writes[writes.length - 1].replace("\n", ""));
    expect(response.result.answer).toBe("choice A");

    respondToRequest(mockProc, 1, {
      session_id: "s1",
      session_dir: "/tmp",
      context_files: [],
      available_skills: [],
      mcp_servers: [],
      node_name: "opal@test",
      auth: { provider: "copilot", providers: [], status: "ready" },
    });
    const session = await p;
    session.close();
  });

  it("calls onStderr callback", async () => {
    const stderrChunks: string[] = [];
    const p = Session.start({ onStderr: (data) => stderrChunks.push(data) });
    await new Promise((r) => setTimeout(r, 10));

    mockProc.stderr.push("debug info\n");
    await new Promise((r) => setTimeout(r, 10));

    expect(stderrChunks).toHaveLength(1);
    expect(stderrChunks[0]).toContain("debug info");

    respondToRequest(mockProc, 1, {
      session_id: "s1",
      session_dir: "/tmp",
      context_files: [],
      available_skills: [],
      mcp_servers: [],
      node_name: "opal@test",
      auth: { provider: "copilot", providers: [], status: "ready" },
    });
    const session = await p;
    session.close();
  });

  it("on() dispatches toolExecutionEnd events", async () => {
    const session = await startSession();
    const toolEnds: [string, string][] = [];
    session.on("toolExecutionEnd", (tool, callId) => toolEnds.push([tool, callId]));

    sendNotification(mockProc, "agent/event", {
      type: "tool_execution_end",
      tool: "shell",
      call_id: "c1",
      result: { ok: true, output: "done" },
    });
    await new Promise((r) => setTimeout(r, 10));

    expect(toolEnds).toEqual([["shell", "c1"]]);
    session.close();
  });

  it("on() dispatches turnEnd events", async () => {
    const session = await startSession();
    const messages: string[] = [];
    session.on("turnEnd", (msg) => messages.push(msg));

    sendNotification(mockProc, "agent/event", {
      type: "turn_end",
      message: "Task complete",
    });
    await new Promise((r) => setTimeout(r, 10));

    expect(messages).toEqual(["Task complete"]);
    session.close();
  });

  it("on() dispatches usageUpdate events", async () => {
    const session = await startSession();
    const usages: unknown[] = [];
    session.on("usageUpdate", (usage) => usages.push(usage));

    sendNotification(mockProc, "agent/event", {
      type: "usage_update",
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
    session.close();
  });

  it("on() dispatches statusUpdate events", async () => {
    const session = await startSession();
    const statuses: string[] = [];
    session.on("statusUpdate", (msg) => statuses.push(msg));

    sendNotification(mockProc, "agent/event", {
      type: "status_update",
      message: "Compacting...",
    });
    await new Promise((r) => setTimeout(r, 10));

    expect(statuses).toEqual(["Compacting..."]);
    session.close();
  });

  it("on() dispatches agentRecovered events", async () => {
    const session = await startSession();
    const recovered: boolean[] = [];
    session.on("agentRecovered", () => recovered.push(true));

    sendNotification(mockProc, "agent/event", { type: "agent_recovered" });
    await new Promise((r) => setTimeout(r, 10));

    expect(recovered).toHaveLength(1);
    session.close();
  });

  it("prompt() terminates on error event", async () => {
    const session = await startSession();
    const events: AgentEvent[] = [];

    mockProc.stdin.write = function (chunk: unknown, ...args: unknown[]) {
      const str = String(chunk);
      writes.push(str);
      const msg = JSON.parse(str.replace("\n", ""));
      if (msg.method === "agent/prompt") {
        setTimeout(() => {
          respondToRequest(mockProc, msg.id, {});
          sendNotification(mockProc, "agent/event", { type: "error", reason: "API crash" });
        }, 5);
      }
      const cb = args.find((a) => typeof a === "function") as (() => void) | undefined;
      cb?.();
      return true;
    } as never;

    for await (const event of session.prompt("Hello")) {
      events.push(event);
    }

    expect(events).toHaveLength(1);
    expect(events[0].type).toBe("error");
    session.close();
  });

  it("prompt() terminates on agentAbort event", async () => {
    const session = await startSession();
    const events: AgentEvent[] = [];

    mockProc.stdin.write = function (chunk: unknown, ...args: unknown[]) {
      const str = String(chunk);
      writes.push(str);
      const msg = JSON.parse(str.replace("\n", ""));
      if (msg.method === "agent/prompt") {
        setTimeout(() => {
          respondToRequest(mockProc, msg.id, {});
          sendNotification(mockProc, "agent/event", { type: "agent_abort" });
        }, 5);
      }
      const cb = args.find((a) => typeof a === "function") as (() => void) | undefined;
      cb?.();
      return true;
    } as never;

    for await (const event of session.prompt("Hello")) {
      events.push(event);
    }

    expect(events).toHaveLength(1);
    expect(events[0].type).toBe("agentAbort");
    session.close();
  });
});
