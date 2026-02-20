import { describe, it, expect, vi } from "vitest";
import { createMemoryTransport } from "../../sdk/transport/memory.js";

const tick = () => new Promise<void>((r) => setTimeout(r, 0));

describe("createMemoryTransport", () => {
  it("creates a linked pair in open state", () => {
    const [a, b] = createMemoryTransport();
    expect(a.state).toBe("open");
    expect(b.state).toBe("open");
  });

  it("delivers messages A→B", async () => {
    const [a, b] = createMemoryTransport();
    const handler = vi.fn();
    b.onMessage(handler);
    a.send("hello");
    await tick();
    expect(handler).toHaveBeenCalledWith("hello");
  });

  it("delivers messages B→A", async () => {
    const [a, b] = createMemoryTransport();
    const handler = vi.fn();
    a.onMessage(handler);
    b.send("world");
    await tick();
    expect(handler).toHaveBeenCalledWith("world");
  });

  it("delivers messages asynchronously via queueMicrotask", () => {
    const [a, b] = createMemoryTransport();
    const handler = vi.fn();
    b.onMessage(handler);
    a.send("sync-check");
    // Handler should NOT have been called synchronously
    expect(handler).not.toHaveBeenCalled();
  });

  it("notifies multiple handlers", async () => {
    const [a, b] = createMemoryTransport();
    const h1 = vi.fn();
    const h2 = vi.fn();
    b.onMessage(h1);
    b.onMessage(h2);
    a.send("multi");
    await tick();
    expect(h1).toHaveBeenCalledWith("multi");
    expect(h2).toHaveBeenCalledWith("multi");
  });

  it("dispose removes a handler", async () => {
    const [a, b] = createMemoryTransport();
    const h1 = vi.fn();
    const h2 = vi.fn();
    const sub = b.onMessage(h1);
    b.onMessage(h2);
    sub.dispose();
    a.send("after-dispose");
    await tick();
    expect(h1).not.toHaveBeenCalled();
    expect(h2).toHaveBeenCalledWith("after-dispose");
  });

  it("close closes both sides", () => {
    const [a, b] = createMemoryTransport();
    a.close();
    expect(a.state).toBe("closed");
    expect(b.state).toBe("closed");
  });

  it("close fires onClose handlers on both sides", () => {
    const [a, b] = createMemoryTransport();
    const onCloseA = vi.fn();
    const onCloseB = vi.fn();
    a.onClose(onCloseA);
    b.onClose(onCloseB);
    a.close();
    expect(onCloseA).toHaveBeenCalledTimes(1);
    expect(onCloseB).toHaveBeenCalledTimes(1);
  });

  it("send after close throws", () => {
    const [a] = createMemoryTransport();
    a.close();
    expect(() => a.send("nope")).toThrow(/Cannot send/);
  });

  it("close is idempotent", () => {
    const [a, _b] = createMemoryTransport();
    const onCloseA = vi.fn();
    a.onClose(onCloseA);
    a.close();
    a.close();
    expect(onCloseA).toHaveBeenCalledTimes(1);
  });

  it("Symbol.dispose calls close", () => {
    const [a, b] = createMemoryTransport();
    a[Symbol.dispose]();
    expect(a.state).toBe("closed");
    expect(b.state).toBe("closed");
  });
});
