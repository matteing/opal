import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { EventEmitter, Readable, Writable } from "node:stream";

// Mock child_process and resolve before importing command modules
vi.mock("node:child_process", () => ({
  spawn: vi.fn(),
}));

vi.mock("../sdk/resolve.js", () => ({
  resolveServer: () => ({ command: "/usr/bin/fake-opal-server", args: [] }),
}));

import { spawn } from "node:child_process";

function createMockProcess() {
  const stdin = new Writable({
    write(_chunk, _enc, cb) {
      cb();
    },
  });
  const stdout = new Readable({ read() {} });
  const stderr = new Readable({ read() {} });
  const proc = new EventEmitter() as EventEmitter & {
    stdin: Writable;
    stdout: Readable;
    stderr: Readable;
    kill: ReturnType<typeof vi.fn>;
    pid: number;
  };
  proc.stdin = stdin;
  proc.stdout = stdout;
  proc.stderr = stderr;
  proc.kill = vi.fn();
  proc.pid = 12345;
  return proc;
}

function respondToRequest(
  mockProc: ReturnType<typeof createMockProcess>,
  id: number,
  result: unknown,
) {
  mockProc.stdout.push(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
}

describe("CLI Commands", () => {
  let mockProc: ReturnType<typeof createMockProcess>;
  const writes: string[] = [];
  let consoleLogSpy: ReturnType<typeof vi.spyOn>;
  let consoleErrorSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    mockProc = createMockProcess();
    writes.length = 0;
    mockProc.stdin.write = function (chunk: unknown, ...args: unknown[]) {
      const str = String(chunk);
      writes.push(str);

      // Auto-respond to requests
      try {
        const msg = JSON.parse(str.replace("\n", "")) as {
          id: number;
          method: string;
        };
        if (msg.method === "opal/ping") {
          setTimeout(() => respondToRequest(mockProc, msg.id, {}), 5);
        } else if (msg.method === "opal/version") {
          setTimeout(
            () =>
              respondToRequest(mockProc, msg.id, {
                server_version: "0.1.10",
                protocol_version: "0.1.0",
              }),
            5,
          );
        } else if (msg.method === "auth/status") {
          setTimeout(() => respondToRequest(mockProc, msg.id, { authenticated: true }), 5);
        } else if (msg.method === "session/list") {
          setTimeout(
            () =>
              respondToRequest(mockProc, msg.id, {
                sessions: [
                  { id: "abc123", title: "Test session", modified: "2026-01-01" },
                  { id: "def456", title: "Another session", modified: "2026-01-02" },
                ],
              }),
            5,
          );
        } else if (msg.method === "session/delete") {
          setTimeout(() => respondToRequest(mockProc, msg.id, { ok: true }), 5);
        }
      } catch {
        // Ignore parse errors
      }
      const cb = args.find((a) => typeof a === "function") as (() => void) | undefined;
      cb?.();
      return true;
    } as never;
    vi.mocked(spawn).mockReturnValue(mockProc as never);
    consoleLogSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  describe("runVersion", () => {
    it("prints CLI and server versions", async () => {
      const { runVersion } = await import("../commands/version.js");
      await runVersion();

      const logs = consoleLogSpy.mock.calls.map((c: unknown[]) => String(c[0]));
      expect(logs.some((l: string) => l.includes("opal"))).toBe(true);
    });
  });

  describe("runSessionList", () => {
    it("lists saved sessions", async () => {
      const { runSessionList } = await import("../commands/session.js");
      await runSessionList();

      const logs = consoleLogSpy.mock.calls.map((c: unknown[]) => String(c[0]));
      expect(logs.some((l: string) => l.includes("abc123"))).toBe(true);
      expect(logs.some((l: string) => l.includes("def456"))).toBe(true);
    });
  });

  describe("runSessionShow", () => {
    it("shows session details", async () => {
      const { runSessionShow } = await import("../commands/session.js");
      await runSessionShow("abc123");

      const logs = consoleLogSpy.mock.calls.map((c: unknown[]) => String(c[0]));
      expect(logs.some((l: string) => l.includes("abc123"))).toBe(true);
      expect(logs.some((l: string) => l.includes("Test session"))).toBe(true);
    });

    it("prints error for unknown session", async () => {
      const { runSessionShow } = await import("../commands/session.js");
      await runSessionShow("unknown-id");

      const errors = consoleErrorSpy.mock.calls.map((c: unknown[]) => String(c[0]));
      expect(errors.some((l: string) => l.includes("not found"))).toBe(true);
    });
  });

  describe("runSessionDelete", () => {
    it("deletes a session", async () => {
      const { runSessionDelete } = await import("../commands/session.js");
      await runSessionDelete("abc123");

      const logs = consoleLogSpy.mock.calls.map((c: unknown[]) => String(c[0]));
      expect(logs.some((l: string) => l.includes("Deleted"))).toBe(true);
      expect(logs.some((l: string) => l.includes("abc123"))).toBe(true);
    });
  });

  describe("runDoctor", () => {
    it("runs health checks and reports results", async () => {
      const { runDoctor } = await import("../commands/doctor.js");
      await runDoctor();

      const output = consoleLogSpy.mock.calls.map((c: unknown[]) => String(c[0]));
      // Should check server connection and version at minimum
      expect(output.some((l: string) => l.includes("✓"))).toBe(true);
    });
  });
});
