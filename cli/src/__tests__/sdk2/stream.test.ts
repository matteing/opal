import { describe, it, expect, vi } from "vitest";
import { AgentStream } from "../../sdk/stream.js";
import type { AgentEvent } from "../../sdk/protocol.js";

const start: AgentEvent = { type: "agentStart" } as AgentEvent;
const delta = (text: string): AgentEvent => ({ type: "messageDelta", delta: text }) as AgentEvent;
const end: AgentEvent = { type: "agentEnd" } as AgentEvent;
const abort: AgentEvent = { type: "agentAbort" } as AgentEvent;
const error: AgentEvent = {
  type: "error",
  reason: "something broke",
} as AgentEvent;

async function collect(stream: AgentStream): Promise<AgentEvent[]> {
  const events: AgentEvent[] = [];
  for await (const e of stream) events.push(e);
  return events;
}

describe("AgentStream", () => {
  it("iterates pushed events in order", async () => {
    const stream = new AgentStream();
    queueMicrotask(() => {
      stream.push(start);
      stream.push(delta("hello"));
      stream.push(delta(" world"));
      stream.push(end);
    });
    const events = await collect(stream);
    expect(events).toHaveLength(4);
    expect(events.map((e) => e.type)).toEqual([
      "agentStart",
      "messageDelta",
      "messageDelta",
      "agentEnd",
    ]);
  });

  it("terminates on agentEnd and ignores later pushes", async () => {
    const stream = new AgentStream();
    queueMicrotask(() => {
      stream.push(start);
      stream.push(end);
      stream.push(delta("too late"));
    });
    const events = await collect(stream);
    expect(events).toHaveLength(2);
    expect(events[1].type).toBe("agentEnd");
  });

  it("terminates on agentAbort", async () => {
    const stream = new AgentStream();
    queueMicrotask(() => {
      stream.push(abort);
    });
    const events = await collect(stream);
    expect(events).toHaveLength(1);
    expect(events[0].type).toBe("agentAbort");
  });

  it("terminates on error event (yielded, not thrown)", async () => {
    const stream = new AgentStream();
    queueMicrotask(() => {
      stream.push(error);
    });
    const events = await collect(stream);
    expect(events).toHaveLength(1);
    expect(events[0].type).toBe("error");
  });

  it("throw() terminates iteration with an exception", async () => {
    const stream = new AgentStream();
    queueMicrotask(() => {
      stream.throw(new Error("fail"));
    });
    await expect(collect(stream)).rejects.toThrow("fail");
  });

  it("finalMessage() concatenates deltas", async () => {
    const stream = new AgentStream();
    const usage = {
      completionTokens: 10,
      promptTokens: 5,
      totalTokens: 15,
      contextWindow: 128000,
      currentContextTokens: 100,
    };
    queueMicrotask(() => {
      stream.push(start);
      stream.push(delta("hello"));
      stream.push(delta(" world"));
      stream.push({ type: "agentEnd", usage } as AgentEvent);
    });
    const result = await stream.finalMessage();
    expect(result.text).toBe("hello world");
    expect(result.usage).toEqual(usage);
    expect(result.aborted).toBe(false);
  });

  it("finalMessage() with abort", async () => {
    const stream = new AgentStream();
    queueMicrotask(() => {
      stream.push(start);
      stream.push(delta("partial"));
      stream.push(abort);
    });
    const result = await stream.finalMessage();
    expect(result.text).toBe("partial");
    expect(result.aborted).toBe(true);
    expect(result.usage).toBeUndefined();
  });

  it("abort() calls the abort function", async () => {
    const abortFn = vi.fn().mockResolvedValue(undefined);
    const stream = new AgentStream(abortFn);
    await stream.abort();
    expect(abortFn).toHaveBeenCalledOnce();
  });

  it("toReadableStream() yields the same events", async () => {
    const stream = new AgentStream();
    queueMicrotask(() => {
      stream.push(start);
      stream.push(delta("hi"));
      stream.push(end);
    });
    const reader = stream.toReadableStream().getReader();
    const events: AgentEvent[] = [];
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      events.push(value);
    }
    expect(events).toHaveLength(3);
    expect(events[0].type).toBe("agentStart");
    expect(events[2].type).toBe("agentEnd");
  });

  it("buffers events pushed before iteration starts", async () => {
    const stream = new AgentStream();
    stream.push(start);
    stream.push(delta("a"));
    stream.push(delta("b"));
    stream.push(delta("c"));
    stream.push(end);
    const events = await collect(stream);
    expect(events).toHaveLength(5);
    expect(events[0].type).toBe("agentStart");
    expect(events[4].type).toBe("agentEnd");
  });
});
