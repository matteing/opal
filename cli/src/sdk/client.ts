/**
 * OpalClient — Typed, bidirectional JSON-RPC 2.0 client for opal-server.
 *
 * Provides fully typed `request<M>()` with inference from the protocol's
 * `MethodTypes` map. Server→client callbacks and agent event streaming
 * are wired through the underlying RpcConnection.
 */

import { RpcConnection } from "./rpc/connection.js";
import { ClientClosedError } from "./errors.js";
import type { Disposable } from "./transport/transport.js";
import type { MethodTypes, AgentEvent } from "../sdk/protocol.js";

// ---------------------------------------------------------------------------
// Type-level helpers
// ---------------------------------------------------------------------------

/** Server→client method names (we handle these). */
type IncomingMethod = "client/confirm" | "client/input" | "client/ask_user";

/** Client→server method names (we send these). */
type OutgoingMethod = Exclude<keyof MethodTypes, IncomingMethod>;

/** Typed handler for a server→client method. */
export type ServerMethodHandler<M extends IncomingMethod> = (
  params: MethodTypes[M]["params"],
) => Promise<MethodTypes[M]["result"]>;

/** Handler for incoming agent events. */
export type AgentEventHandler = (event: AgentEvent) => void;

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

export class OpalClient {
  readonly #rpc: RpcConnection;
  readonly #eventHandlers = new Set<AgentEventHandler>();
  readonly #notifSub: Disposable;

  constructor(rpc: RpcConnection) {
    this.#rpc = rpc;

    // Route agent/event notifications to event handlers
    this.#notifSub = rpc.onNotification((method, params) => {
      if (method === "agent/event") {
        const raw = params as Record<string, unknown>;
        const wireType = raw.type as string;
        const camelType = wireType.replace(/_([a-z])/g, (_, c: string) =>
          c.toUpperCase(),
        );
        const event = { ...raw, type: camelType } as unknown as AgentEvent;
        for (const handler of this.#eventHandlers) {
          handler(event);
        }
      }
    });
  }

  /**
   * Send a typed JSON-RPC request to the server.
   *
   * Params and result types are inferred from the method string.
   * For methods with empty params (e.g., "opal/ping"), params can be omitted.
   */
  async request<M extends OutgoingMethod>(
    method: M,
    ...args: MethodTypes[M]["params"] extends Record<string, never>
      ? [params?: MethodTypes[M]["params"], timeoutMs?: number]
      : [params: MethodTypes[M]["params"], timeoutMs?: number]
  ): Promise<MethodTypes[M]["result"]> {
    if (this.#rpc.closed) throw new ClientClosedError();
    const [params, timeoutMs] = args;
    return this.#rpc.request(method, params ?? {}, timeoutMs) as Promise<
      MethodTypes[M]["result"]
    >;
  }

  /** Register a handler for incoming agent events. Returns cleanup handle. */
  onEvent(handler: AgentEventHandler): Disposable {
    this.#eventHandlers.add(handler);
    return { dispose: () => this.#eventHandlers.delete(handler) };
  }

  /** Register a typed handler for a server→client method. */
  addServerMethod<M extends IncomingMethod>(
    method: M,
    handler: ServerMethodHandler<M>,
  ): Disposable {
    return this.#rpc.addMethod(method, (params) =>
      handler(params as MethodTypes[M]["params"]),
    );
  }

  /** Liveness check — resolves if the server responds within the timeout. */
  async ping(timeoutMs = 5000): Promise<void> {
    await this.request(
      "opal/ping",
      {} as MethodTypes["opal/ping"]["params"],
      timeoutMs,
    );
  }

  /** Whether the client is closed. */
  get closed(): boolean {
    return this.#rpc.closed;
  }

  /** Close the client and release resources. */
  close(): void {
    this.#notifSub.dispose();
    this.#eventHandlers.clear();
    this.#rpc.close();
  }

  [Symbol.dispose](): void {
    this.close();
  }
}
