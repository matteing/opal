/**
 * AgentStream — async iterable of agent events with convenience accessors.
 *
 * Bridges push-based event delivery into a pull-based `for await...of`
 * iteration. Provides `.finalMessage()` for one-shot consumption and
 * `.toReadableStream()` for Web Streams API interop.
 *
 * @example Iterate events
 * ```ts
 * const stream = session.prompt("Hello");
 * for await (const event of stream) {
 *   if (event.type === "messageDelta") process.stdout.write(event.delta);
 * }
 * ```
 *
 * @example Collect final response
 * ```ts
 * const { text, usage } = await session.prompt("Explain").finalMessage();
 * ```
 */

import type { AgentEvent, TokenUsage } from "../sdk/protocol.js";

/** Result of consuming the full stream. */
export interface FinalMessage {
  /** The concatenated assistant message text. */
  text: string;
  /** Token usage for this turn (from the final agentEnd event). */
  usage: TokenUsage | undefined;
  /** Whether the agent was aborted. */
  aborted: boolean;
}

/**
 * Async iterable stream of agent events.
 *
 * Created by `session.prompt()` — do not construct directly.
 * The stream terminates when an `agentEnd`, `agentAbort`, or `error` event
 * is received.
 */
export class AgentStream implements AsyncIterable<AgentEvent> {
  readonly #events: AgentEvent[] = [];
  #done = false;
  #error: Error | undefined;
  #resolve: (() => void) | null = null;
  #abortFn: (() => Promise<void>) | undefined;

  /**
   * @param abortFn - Called by `.abort()` to cancel the agent run.
   * @internal
   */
  constructor(abortFn?: () => Promise<void>) {
    this.#abortFn = abortFn;
  }

  /** Push an event into the stream (called by Session internals). */
  push(event: AgentEvent): void {
    this.#events.push(event);
    if (
      event.type === "agentEnd" ||
      event.type === "agentAbort" ||
      event.type === "error"
    ) {
      this.#done = true;
    }
    this.#resolve?.();
  }

  /** Signal an error that terminates the stream. */
  throw(error: Error): void {
    this.#error = error;
    this.#done = true;
    this.#resolve?.();
  }

  /** Abort the agent run. */
  async abort(): Promise<void> {
    await this.#abortFn?.();
  }

  /**
   * Consume the entire stream and return the final message.
   * Concatenates all `messageDelta` events into a single text string.
   */
  async finalMessage(): Promise<FinalMessage> {
    let text = "";
    let usage: TokenUsage | undefined;
    let aborted = false;

    for await (const event of this) {
      switch (event.type) {
        case "messageDelta":
          text += event.delta;
          break;
        case "agentEnd":
          usage = event.usage as TokenUsage | undefined;
          break;
        case "agentAbort":
          aborted = true;
          break;
      }
    }

    return { text, usage, aborted };
  }

  /** Convert to a Web ReadableStream for interop. */
  toReadableStream(): ReadableStream<AgentEvent> {
    const iterator = this[Symbol.asyncIterator]();
    return new ReadableStream<AgentEvent>({
      async pull(controller) {
        const result = await iterator.next();
        if (result.done) {
          controller.close();
        } else {
          controller.enqueue(result.value);
        }
      },
      cancel() {
        void iterator.return?.();
      },
    });
  }

  /** Async iterator implementation. */
  async *[Symbol.asyncIterator](): AsyncIterator<AgentEvent> {
    try {
      while (true) {
        // Drain buffered events
        while (this.#events.length > 0) {
          const event = this.#events.shift()!;
          yield event;
          if (
            event.type === "agentEnd" ||
            event.type === "agentAbort" ||
            event.type === "error"
          ) {
            return;
          }
        }

        // Check for errors
        if (this.#error) throw this.#error;

        // All done
        if (this.#done) return;

        // Wait for next event
        await new Promise<void>((r) => {
          this.#resolve = r;
        });
        this.#resolve = null;
      }
    } finally {
      this.#resolve = null;
    }
  }
}
