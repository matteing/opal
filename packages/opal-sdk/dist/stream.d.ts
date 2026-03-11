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
import type { AgentEvent, TokenUsage } from "./protocol.js";
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
export declare class AgentStream implements AsyncIterable<AgentEvent> {
    #private;
    /**
     * @param abortFn - Called by `.abort()` to cancel the agent run.
     * @internal
     */
    constructor(abortFn?: () => Promise<void>);
    /** Push an event into the stream (called by Session internals). */
    push(event: AgentEvent): void;
    /** Signal an error that terminates the stream. */
    throw(error: Error): void;
    /** Abort the agent run. */
    abort(): Promise<void>;
    /**
     * Consume the entire stream and return the final message.
     * Concatenates all `messageDelta` events into a single text string.
     */
    finalMessage(): Promise<FinalMessage>;
    /** Convert to a Web ReadableStream for interop. */
    toReadableStream(): ReadableStream<AgentEvent>;
    /** Async iterator implementation. */
    [Symbol.asyncIterator](): AsyncIterator<AgentEvent>;
}
//# sourceMappingURL=stream.d.ts.map