/**
 * In-memory transport pair for deterministic testing.
 *
 * Messages sent on one side appear on the other via queueMicrotask,
 * giving async-like ordering without real I/O.
 */
import type { Transport } from "./transport.js";
/**
 * Create a linked pair of in-memory transports.
 * Messages sent on one appear on the other. Synchronous, deterministic.
 */
export declare function createMemoryTransport(): [Transport, Transport];
//# sourceMappingURL=memory.d.ts.map