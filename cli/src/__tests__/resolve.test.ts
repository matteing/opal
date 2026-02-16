import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// Mock the modules that resolveServer depends on
vi.mock("node:child_process", () => ({
  execFileSync: vi.fn(),
}));

vi.mock("node:fs", () => ({
  existsSync: vi.fn(),
}));

vi.mock("node:os", () => ({
  platform: vi.fn(),
  arch: vi.fn(),
}));

import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { platform, arch } from "node:os";
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
    vi.mocked(arch).mockReturnValue("arm64");
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

  it("falls back to bundled binary", async () => {
    vi.mocked(existsSync).mockImplementation((path) => {
      return String(path).includes("opal_server_darwin_arm64");
    });

    const resolveServer = await getResolveServer();
    const result = resolveServer();
    expect(result.command).toContain("opal_server_darwin_arm64");
  });

  it("throws when nothing found", async () => {
    const resolveServer = await getResolveServer();
    expect(() => resolveServer()).toThrow("opal-server not found");
  });

  it("returns correct platform binary name for linux-x64", async () => {
    vi.mocked(platform).mockReturnValue("linux");
    vi.mocked(arch).mockReturnValue("x64");
    vi.mocked(existsSync).mockImplementation((path) => {
      return String(path).includes("opal_server_linux_x64");
    });

    const resolveServer = await getResolveServer();
    const result = resolveServer();
    expect(result.command).toContain("opal_server_linux_x64");
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
