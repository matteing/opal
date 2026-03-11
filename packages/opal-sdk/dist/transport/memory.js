/**
 * In-memory transport pair for deterministic testing.
 *
 * Messages sent on one side appear on the other via queueMicrotask,
 * giving async-like ordering without real I/O.
 */
/**
 * Create a linked pair of in-memory transports.
 * Messages sent on one appear on the other. Synchronous, deterministic.
 */
export function createMemoryTransport() {
    const a = new MemorySide();
    const b = new MemorySide();
    a.peer = b;
    b.peer = a;
    return [a, b];
}
class MemorySide {
    #messageHandlers = new Set();
    #closeHandlers = new Set();
    #errorHandlers = new Set();
    #state = "open";
    peer;
    get state() {
        return this.#state;
    }
    send(data) {
        if (this.#state !== "open") {
            throw new Error(`Cannot send in "${this.#state}" state`);
        }
        const target = this.peer;
        queueMicrotask(() => {
            if (target.#state !== "open")
                return;
            for (const handler of target.#messageHandlers) {
                handler(data);
            }
        });
    }
    onMessage(handler) {
        this.#messageHandlers.add(handler);
        return { dispose: () => this.#messageHandlers.delete(handler) };
    }
    onClose(handler) {
        this.#closeHandlers.add(handler);
        return { dispose: () => this.#closeHandlers.delete(handler) };
    }
    onError(handler) {
        this.#errorHandlers.add(handler);
        return { dispose: () => this.#errorHandlers.delete(handler) };
    }
    close() {
        if (this.#state === "closed")
            return;
        this.#state = "closed";
        this.#fireClose();
        // Close the peer as well
        if (this.peer.#state !== "closed") {
            this.peer.#state = "closed";
            this.peer.#fireClose();
        }
    }
    [Symbol.dispose]() {
        this.close();
    }
    #fireClose(reason) {
        for (const handler of this.#closeHandlers) {
            handler(reason);
        }
        this.#closeHandlers.clear();
    }
}
//# sourceMappingURL=memory.js.map