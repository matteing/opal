import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  createMockProcess,
  respond,
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

describe("Session — extended coverage", () => {
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

  // --- Uncovered method param paths ---

  it("setModel without thinkingLevel omits it from params", async () => {
    const session = await startSession();
    const pending = session.setModel("gpt-4");
    await tick();
    respond(proc, 2, { model: { id: "gpt-4", provider: "copilot" } });
    await pending;

    expect(writes.lastRequest().params).not.toHaveProperty("thinking_level");
    session.close();
  });

  it("compact without keepRecent omits it from params", async () => {
    const session = await startSession();
    const pending = session.compact();
    await tick();
    respond(proc, 2, {});
    await pending;

    expect(writes.lastRequest().params).not.toHaveProperty("keep_recent");
    session.close();
  });

  it("authPoll sends deviceCode and interval", async () => {
    const session = await startSession();
    const pending = session.authPoll("dc-123", 5);
    await tick();
    respond(proc, 2, { authenticated: true });
    await pending;

    const params = writes.lastRequest().params as Record<string, unknown>;
    expect(params.device_code).toBe("dc-123");
    expect(params.interval).toBe(5);
    session.close();
  });

  // --- Uncovered dispatch branches ---

  it("dispatches thinkingStart event", async () => {
    const session = await startSession();
    const received: boolean[] = [];
    session.on("thinkingStart", () => received.push(true));

    sendEvent(proc, { type: "thinking_start" });
    await tick();

    expect(received).toHaveLength(1);
    session.close();
  });

  it("dispatches thinkingDelta event with delta", async () => {
    const session = await startSession();
    const deltas: string[] = [];
    session.on("thinkingDelta", (delta) => deltas.push(delta));

    sendEvent(proc, { type: "thinking_delta", delta: "I think..." });
    await tick();

    expect(deltas).toEqual(["I think..."]);
    session.close();
  });

  it("dispatches agentAbort event", async () => {
    const session = await startSession();
    const received: boolean[] = [];
    session.on("agentAbort", () => received.push(true));

    sendEvent(proc, { type: "agent_abort" });
    await tick();

    expect(received).toHaveLength(1);
    session.close();
  });

  it("dispatches agentEnd with usage data", async () => {
    const session = await startSession();
    const usages: unknown[] = [];
    session.on("agentEnd", (usage) => usages.push(usage));

    sendEvent(proc, {
      type: "agent_end",
      usage: {
        prompt_tokens: 100,
        completion_tokens: 50,
        total_tokens: 150,
        context_window: 128000,
        current_context_tokens: 200,
      },
    });
    await tick();

    expect(usages).toHaveLength(1);
    expect(usages[0]).toBeDefined();
    session.close();
  });

  it("dispatches agentEnd without usage", async () => {
    const session = await startSession();
    const usages: unknown[] = [];
    session.on("agentEnd", (usage) => usages.push(usage));

    sendEvent(proc, { type: "agent_end" });
    await tick();

    expect(usages).toHaveLength(1);
    expect(usages[0]).toBeUndefined();
    session.close();
  });

  it("dispatches messageStart event", async () => {
    const session = await startSession();
    const received: boolean[] = [];
    session.on("messageStart", () => received.push(true));

    sendEvent(proc, { type: "message_start" });
    await tick();

    expect(received).toHaveLength(1);
    session.close();
  });

  it("multiple handlers on same event are all called", async () => {
    const session = await startSession();
    const calls: number[] = [];
    session.on("agentStart", () => calls.push(1));
    session.on("agentStart", () => calls.push(2));

    sendEvent(proc, { type: "agent_start" });
    await tick();

    expect(calls).toEqual([1, 2]);
    session.close();
  });

  it("event with no listeners does not crash", async () => {
    const session = await startSession();
    sendEvent(proc, { type: "agent_start" });
    sendEvent(proc, { type: "message_delta", delta: "hello" });
    await tick();
    session.close();
  });

  it("unknown event type does not crash dispatch", async () => {
    const session = await startSession();
    sendEvent(proc, { type: "totally_unknown_event", data: "foo" });
    await tick();
    session.close();
  });
});
