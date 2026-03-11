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
/**
 * Exhaustive event matcher — compile error if any event type is missing.
 *
 * Dispatches to the handler matching `event.type` and returns its result.
 */
export function matchEvent(event, visitor) {
    const handler = visitor[event.type];
    return handler(event);
}
/**
 * Partial event matcher — unhandled types fall through to the `_` default.
 */
export function matchEventPartial(event, visitor) {
    const handler = visitor[event.type];
    return handler ? handler(event) : visitor._(event);
}
/** Type predicate that narrows an `AgentEvent` to a specific variant. */
export function isEventType(event, type) {
    return event.type === type;
}
/** Exhaustive-check helper — call in the `default` branch of a switch. */
export function assertNever(x) {
    throw new Error(`Unexpected value: ${JSON.stringify(x)}`);
}
//# sourceMappingURL=match.js.map