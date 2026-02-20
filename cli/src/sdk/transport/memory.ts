/**
 * In-memory transport pair for deterministic testing.
 *
 * Messages sent on one side appear on the other via queueMicrotask,
 * giving async-like ordering without real I/O.
 */

import type { Transport, TransportState, Disposable } from "./transport.js";

/**
 * Create a linked pair of in-memory transports.
 * Messages sent on one appear on the other. Synchronous, deterministic.
 */
export function createMemoryTransport(): [Transport, Transport] {
  const a = new MemorySide();
  const b = new MemorySide();
  a.peer = b;
  b.peer = a;
  return [a, b];
}

class MemorySide implements Transport {
  readonly #messageHandlers = new Set<(data: string) => void>();
  readonly #closeHandlers = new Set<(reason?: Error) => void>();
  readonly #errorHandlers = new Set<(error: Error) => void>();
  #state: TransportState = "open";
  peer!: MemorySide;

  get state(): TransportState {
    return this.#state;
  }

  send(data: string): void {
    if (this.#state !== "open") {
      throw new Error(`Cannot send in "${this.#state}" state`);
    }
    const target = this.peer;
    queueMicrotask(() => {
      if (target.#state !== "open") return;
      for (const handler of target.#messageHandlers) {
        handler(data);
      }
    });
  }

  onMessage(handler: (data: string) => void): Disposable {
    this.#messageHandlers.add(handler);
    return { dispose: () => this.#messageHandlers.delete(handler) };
  }

  onClose(handler: (reason?: Error) => void): Disposable {
    this.#closeHandlers.add(handler);
    return { dispose: () => this.#closeHandlers.delete(handler) };
  }

  onError(handler: (error: Error) => void): Disposable {
    this.#errorHandlers.add(handler);
    return { dispose: () => this.#errorHandlers.delete(handler) };
  }

  close(): void {
    if (this.#state === "closed") return;
    this.#state = "closed";
    this.#fireClose();
    // Close the peer as well
    if (this.peer.#state !== "closed") {
      this.peer.#state = "closed";
      this.peer.#fireClose();
    }
  }

  [Symbol.dispose](): void {
    this.close();
  }

  #fireClose(reason?: Error): void {
    for (const handler of this.#closeHandlers) {
      handler(reason);
    }
    this.#closeHandlers.clear();
  }
}
