/** Lifecycle state of a transport connection. */
export type TransportState = "connecting" | "open" | "closed";

/** Callback cleanup handle. */
export interface Disposable {
  dispose(): void;
}

/**
 * Bidirectional message channel for JSON-RPC communication.
 *
 * Implementations handle framing (newline-delimited JSON for stdio,
 * WebSocket frames, etc). Consumers send and receive raw JSON strings.
 */
export interface Transport {
  /** Current connection state. */
  readonly state: TransportState;

  /** Send a serialized message string. Throws if not open. */
  send(data: string): void;

  /** Register a handler for incoming messages. Returns cleanup handle. */
  onMessage(handler: (data: string) => void): Disposable;

  /** Register a handler for transport close. Fires once. */
  onClose(handler: (reason?: Error) => void): Disposable;

  /** Register a handler for non-fatal errors (parse failures, etc). */
  onError(handler: (error: Error) => void): Disposable;

  /** Gracefully shut down. Idempotent. */
  close(): void;

  /** Symbol.dispose support for `using` syntax. */
  [Symbol.dispose](): void;
}
