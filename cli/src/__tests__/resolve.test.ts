import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// Mock the modules that resolveServer depends on
vi.mock("node:child_process", () => ({
  execFileSync: vi.fn(),
}));

vi.mock("node:fs", () => ({
  existsSync: vi.fn(),
  readFileSync: vi.fn(),
}));

vi.mock("node:os", () => ({
  platform: vi.fn(),
  homedir: vi.fn(),
}));

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { platform, homedir } from "node:os";
import { join } from "node:path";

// We need to re-import resolveServer fresh for each test
// because it uses these at call time (not import time)
async function getResolveServer() {
  // Dynamic import to get fresh module
  const mod = await import("../sdk/resolve.js");
  return mod.resolveServer;
}

describe("resolveServer", () => {
  beforeEach(() => {
    vi.mocked(platform).mockReturnValue("darwin");
    vi.mocked(homedir).mockReturnValue("/home/testuser");
    vi.mocked(readFileSync).mockReturnValue(JSON.stringify({ version: "0.1.0" }));
    // Default: nothing found
    vi.mocked(execFileSync).mockImplementation(() => {
      throw new Error("not found");
    });
    vi.mocked(existsSync).mockReturnValue(false);
    // Mock process.platform for the `which` vs `where` check
    Object.defineProperty(process, "platform", { value: "darwin", writable: true });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("finds opal-server in PATH", async () => {
    vi.mocked(execFileSync).mockReturnValue("/usr/local/bin/opal-server\n");
    vi.mocked(existsSync).mockImplementation((path) => {
      return String(path).includes("opal-server");
    });

    const resolveServer = await getResolveServer();
    const result = resolveServer();
    expect(result.command).toContain("opal-server");
    expect(result.args).toEqual([]);
  });

  it("uses 'where' on win32", async () => {
    Object.defineProperty(process, "platform", { value: "win32", writable: true });
    vi.mocked(execFileSync).mockReturnValue("C:\\opal-server.exe\n");
    vi.mocked(existsSync).mockImplementation((path) => {
      return String(path).includes("opal-server");
    });

    const resolveServer = await getResolveServer();
    const result = resolveServer();
    expect(vi.mocked(execFileSync)).toHaveBeenCalledWith(
      "where",
      expect.any(Array),
      expect.any(Object),
    );
    expect(result.command).toContain("opal-server");
  });

  it("falls back to extracted OTP release", async () => {
    vi.mocked(existsSync).mockImplementation((path) => {
      return String(path).includes(join(".opal", "erts", "0.1.0", "bin", "opal_server"));
    });

    const resolveServer = await getResolveServer();
    const result = resolveServer();
    expect(result.command).toContain("opal_server");
    expect(result.args).toEqual(["start"]);
  });

  it("throws when nothing found", async () => {
    const resolveServer = await getResolveServer();
    expect(() => resolveServer()).toThrow("opal-server not found");
  });

  it("uses opal_server.bat on win32", async () => {
    vi.mocked(platform).mockReturnValue("win32");
    vi.mocked(existsSync).mockImplementation((path) => {
      return String(path).includes("opal_server.bat");
    });

    const resolveServer = await getResolveServer();
    const result = resolveServer();
    expect(result.command).toContain("opal_server.bat");
    expect(result.args).toEqual(["start"]);
  });

  it("detects monorepo and uses mise exec", async () => {
    vi.mocked(existsSync).mockImplementation((path) => {
      const p = String(path);
      if (p.includes(join("opal", "mix.exs"))) return true;
      if (p.includes(join("opal", "lib", "opal"))) return true;
      return false;
    });

    const resolveServer = await getResolveServer();
    const result = resolveServer();
    expect(result.command).toBe("mise");
    expect(result.args).toEqual(["exec", "--", "elixir", "-S", "mix", "run", "--no-halt"]);
    expect(result.cwd).toBeDefined();
    expect(result.cwd).toContain("opal");
  });

  it("prefers monorepo over opal-server in PATH", async () => {
    vi.mocked(execFileSync).mockReturnValue("/usr/local/bin/opal-server\n");
    vi.mocked(existsSync).mockImplementation((path) => {
      const p = String(path);
      if (p.includes(join("opal", "mix.exs"))) return true;
      if (p.includes(join("opal", "lib", "opal"))) return true;
      if (p.includes("opal-server")) return true;
      return false;
    });

    const resolveServer = await getResolveServer();
    const result = resolveServer();
    expect(result.command).toBe("mise");
  });
});
