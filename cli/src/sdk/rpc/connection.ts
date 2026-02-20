/**
 * Bidirectional JSON-RPC 2.0 connection.
 *
 * Wraps a Transport with request/response id correlation, typed notification
 * dispatch, and server-initiated method handling. Case transforms (snake↔camel)
 * are applied at the boundary so all SDK code operates in camelCase.
 */

import type { Transport, Disposable } from "../transport/transport.js";
import type { JsonRpcErrorData } from "./types.js";
import { ErrorCodes } from "./types.js";
import { snakeToCamel, camelToSnake } from "../transforms.js";
import { TimeoutError, RpcError } from "../errors.js";

/** Pending request tracking. */
interface PendingRequest {
  method: string;
  resolve: (result: unknown) => void;
  reject: (error: Error) => void;
  timer?: ReturnType<typeof setTimeout>;
}

/** Handler for a server-initiated RPC method. */
export type MethodHandler = (params: unknown) => Promise<unknown>;

/** Handler for a notification. */
export type NotificationHandler = (method: string, params: unknown) => void;

/** Callback for observing raw RPC traffic. */
export interface RpcObserver {
  onOutgoing?: (message: unknown) => void;
  onIncoming?: (message: unknown) => void;
}

export class RpcConnection {
  readonly #transport: Transport;
  readonly #pending = new Map<number, PendingRequest>();
  readonly #methods = new Map<string, MethodHandler>();
  readonly #notificationHandlers = new Set<NotificationHandler>();
  readonly #observer: RpcObserver | undefined;
  readonly #transportSub: Disposable;
  readonly #closeSub: Disposable;
  #nextId = 0;
  #closed = false;

  constructor(transport: Transport, observer?: RpcObserver) {
    this.#transport = transport;
    this.#observer = observer;

    this.#transportSub = transport.onMessage((line) =>
      this.#handleMessage(line),
    );

    this.#closeSub = transport.onClose((reason) => {
      this.#closed = true;
      const msg = reason?.message ?? "Transport closed";
      this.#rejectAll(msg);
    });
  }

  /** Send a JSON-RPC request and await the response. */
  async request(
    method: string,
    params?: unknown,
    timeoutMs?: number,
  ): Promise<unknown> {
    if (this.#closed) {
      throw new RpcError(
        method,
        ErrorCodes.INTERNAL_ERROR,
        "Connection is closed",
      );
    }

    const id = ++this.#nextId;
    const message = { jsonrpc: "2.0" as const, id, method, params };

    return new Promise<unknown>((resolve, reject) => {
      const entry: PendingRequest = { method, resolve, reject };

      if (timeoutMs != null && timeoutMs > 0) {
        entry.timer = setTimeout(() => {
          this.#pending.delete(id);
          reject(new TimeoutError(method, timeoutMs));
        }, timeoutMs);
      }

      this.#pending.set(id, entry);
      this.#send(message);
    });
  }

  /** Register a handler for a server→client method. */
  addMethod(method: string, handler: MethodHandler): Disposable {
    this.#methods.set(method, handler);
    return { dispose: () => this.#methods.delete(method) };
  }

  /** Register a handler for notifications. */
  onNotification(handler: NotificationHandler): Disposable {
    this.#notificationHandlers.add(handler);
    return { dispose: () => this.#notificationHandlers.delete(handler) };
  }

  /** Whether the connection is closed. */
  get closed(): boolean {
    return this.#closed;
  }

  /** Close the connection and reject pending requests. */
  close(): void {
    if (this.#closed) return;
    this.#closed = true;
    this.#rejectAll("Connection closed");
    this.#transportSub.dispose();
    this.#closeSub.dispose();
  }

  [Symbol.dispose](): void {
    this.close();
  }

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  /** Serialize and send a message, applying camelCase→snake_case transform. */
  #send(msg: unknown): void {
    const wire = camelToSnake(msg);
    this.#observer?.onOutgoing?.(wire);
    this.#transport.send(JSON.stringify(wire));
  }

  /** Parse and route an incoming message line. */
  #handleMessage(line: string): void {
    let raw: Record<string, unknown>;
    try {
      raw = JSON.parse(line) as Record<string, unknown>;
    } catch {
      return; // silently ignore parse errors
    }

    this.#observer?.onIncoming?.(raw);

    const hasMethod = typeof raw.method === "string";
    const hasId = "id" in raw;

    // Notification (method + no id)
    if (hasMethod && !hasId) {
      const params = snakeToCamel(raw.params ?? {});
      for (const handler of this.#notificationHandlers) {
        handler(raw.method as string, params);
      }
      return;
    }

    // Response (has id, no method) — match to pending request
    if (hasId && !hasMethod) {
      const id = raw.id as number;
      const entry = this.#pending.get(id);
      if (!entry) return; // stale response

      this.#pending.delete(id);
      if (entry.timer) clearTimeout(entry.timer);

      if (raw.error) {
        const err = raw.error as JsonRpcErrorData;
        entry.reject(
          new RpcError(entry.method, err.code, err.message, err.data),
        );
      } else {
        entry.resolve(snakeToCamel(raw.result));
      }
      return;
    }

    // Server→client request (has method + id) — dispatch to registered handler
    if (hasMethod && hasId) {
      const method = raw.method as string;
      const id = raw.id as number;
      const handler = this.#methods.get(method);

      if (!handler) {
        this.#send({
          jsonrpc: "2.0",
          id,
          error: {
            code: ErrorCodes.METHOD_NOT_FOUND,
            message: `No handler for ${method}`,
          },
        });
        return;
      }

      const params = snakeToCamel(raw.params ?? {});
      handler(params)
        .then((result) => {
          this.#send({ jsonrpc: "2.0", id, result: result ?? {} });
        })
        .catch((err: unknown) => {
          const message = err instanceof Error ? err.message : String(err);
          this.#send({
            jsonrpc: "2.0",
            id,
            error: { code: ErrorCodes.INTERNAL_ERROR, message },
          });
        });
    }
  }

  /** Reject all pending requests with a reason. */
  #rejectAll(reason: string): void {
    for (const [, entry] of this.#pending) {
      if (entry.timer) clearTimeout(entry.timer);
      entry.reject(
        new RpcError(entry.method, ErrorCodes.INTERNAL_ERROR, reason),
      );
    }
    this.#pending.clear();
  }
}
