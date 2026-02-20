/**
 * Type-safe event matching utilities for AgentEvent.
 *
 * @example Exhaustive matching
 * ```ts
 * const label = matchEvent(event, {
 *   agentStart:         () => "Starting...",
 *   messageDelta:       (e) => e.delta,
 *   toolExecutionStart: (e) => `⚙ ${e.tool}`,
 *   // ... all 19 types must be handled — compile error if any missing
 * });
 * ```
 *
 * @example Partial matching with default
 * ```ts
 * const text = matchEventPartial(event, {
 *   messageDelta:  (e) => e.delta,
 *   thinkingDelta: (e) => `💭 ${e.delta}`,
 *   _:             () => null,  // default for unhandled types
 * });
 * ```
 *
 * @example Type predicate
 * ```ts
 * if (isEventType(event, "messageDelta")) {
 *   event.delta; // fully narrowed to MessageDeltaEvent
 * }
 * ```
 */

import type { AgentEvent } from "../sdk/protocol.js";

/** Union of all event type discriminator strings. */
export type AgentEventType = AgentEvent["type"];

/** Extract a specific event interface by its type string. */
export type EventOfType<T extends AgentEventType> = Extract<AgentEvent, { type: T }>;

/** A visitor requiring a handler for every event type. */
export type AgentEventVisitor<R> = {
  [T in AgentEventType]: (event: EventOfType<T>) => R;
};

/** A partial visitor with a required `_` default for unhandled types. */
export type PartialVisitor<R> = Partial<AgentEventVisitor<R>> & {
  _: (event: AgentEvent) => R;
};

/**
 * Exhaustive event matcher — compile error if any event type is missing.
 *
 * Dispatches to the handler matching `event.type` and returns its result.
 */
export function matchEvent<R>(event: AgentEvent, visitor: AgentEventVisitor<R>): R {
  const handler = (visitor as Record<string, (event: AgentEvent) => R>)[event.type];
  return handler(event);
}

/**
 * Partial event matcher — unhandled types fall through to the `_` default.
 */
export function matchEventPartial<R>(event: AgentEvent, visitor: PartialVisitor<R>): R {
  const handler = (visitor as Record<string, ((event: AgentEvent) => R) | undefined>)[event.type];
  return handler ? handler(event) : visitor._(event);
}

/** Type predicate that narrows an `AgentEvent` to a specific variant. */
export function isEventType<T extends AgentEventType>(
  event: AgentEvent,
  type: T,
): event is EventOfType<T> {
  return event.type === type;
}

/** Exhaustive-check helper — call in the `default` branch of a switch. */
export function assertNever(x: never): never {
  throw new Error(`Unexpected value: ${JSON.stringify(x)}`);
}
