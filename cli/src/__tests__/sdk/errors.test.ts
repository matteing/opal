import { describe, expect, it } from "vitest";
import {
  OpalError,
  ConnectionError,
  TimeoutError,
  RpcError,
  AbortError,
  ClientClosedError,
  isOpalError,
  isErrorCode,
} from "../../sdk/errors.js";

describe("error hierarchy", () => {
  it("ConnectionError stores fields and has correct identity", () => {
    const err = new ConnectionError(1, "SIGTERM", "boom");
    expect(err.code).toBe("CONNECTION_LOST");
    expect(err.name).toBe("ConnectionError");
    expect(err.exitCode).toBe(1);
    expect(err.signal).toBe("SIGTERM");
    expect(err.stderr).toBe("boom");
    expect(err).toBeInstanceOf(OpalError);
    expect(err).toBeInstanceOf(Error);
  });

  it("TimeoutError stores fields", () => {
    const err = new TimeoutError("agent/prompt", 5000);
    expect(err.code).toBe("TIMEOUT");
    expect(err.name).toBe("TimeoutError");
    expect(err.method).toBe("agent/prompt");
    expect(err.timeoutMs).toBe(5000);
  });

  it("RpcError stores fields", () => {
    const err = new RpcError("rpc/call", -32600, "Invalid", { detail: "x" });
    expect(err.code).toBe("SERVER_ERROR");
    expect(err.name).toBe("RpcError");
    expect(err.method).toBe("rpc/call");
    expect(err.rpcCode).toBe(-32600);
    expect(err.data).toEqual({ detail: "x" });
  });

  it("AbortError has default message", () => {
    const err = new AbortError();
    expect(err.code).toBe("ABORTED");
    expect(err.message).toBe("Operation aborted");
  });

  it("ClientClosedError has fixed message", () => {
    const err = new ClientClosedError();
    expect(err.code).toBe("CLIENT_CLOSED");
    expect(err.message).toBe("Client is closed");
  });
});

describe("type predicates", () => {
  it("isOpalError returns true for subclasses, false for plain Error", () => {
    expect(isOpalError(new AbortError())).toBe(true);
    expect(isOpalError(new ConnectionError(null, null, ""))).toBe(true);
    expect(isOpalError(new Error("plain"))).toBe(false);
    expect(isOpalError("string")).toBe(false);
  });

  it("isErrorCode narrows correctly", () => {
    const err = new TimeoutError("m", 100);
    expect(isErrorCode(err, "TIMEOUT")).toBe(true);
    expect(isErrorCode(err, "ABORTED")).toBe(false);
    expect(isErrorCode(new Error(), "TIMEOUT")).toBe(false);
  });
});

describe("OpalError with cause", () => {
  it("chains errors via cause", () => {
    const cause = new Error("root");
    const err = new OpalError("ABORTED", "wrapper", { cause });
    expect(err.cause).toBe(cause);
  });
});
