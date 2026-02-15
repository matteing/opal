import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// Mock dependencies before importing
vi.mock("node:fs", () => ({
  existsSync: vi.fn(),
}));
vi.mock("node:child_process", () => ({
  spawn: vi.fn().mockReturnValue({ unref: vi.fn() }),
  execSync: vi.fn(),
}));

import { existsSync } from "node:fs";
import { spawn, execSync } from "node:child_process";
import { openPlanInEditor } from "../open-editor.js";
import { openUrl, copyToClipboard } from "../open-url.js";

describe("openPlanInEditor", () => {
  beforeEach(() => {
    vi.mocked(existsSync).mockReturnValue(true);
    delete process.env.VISUAL;
    delete process.env.EDITOR;
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("returns early when sessionDir is empty", () => {
    openPlanInEditor("");
    expect(spawn).not.toHaveBeenCalled();
  });

  it("returns early when plan.md does not exist", () => {
    vi.mocked(existsSync).mockReturnValue(false);
    const stderrSpy = vi.spyOn(process.stderr, "write").mockReturnValue(true);
    openPlanInEditor("/tmp/session");
    expect(spawn).not.toHaveBeenCalled();
    stderrSpy.mockRestore();
  });

  it("uses $VISUAL when set", () => {
    process.env.VISUAL = "subl";
    openPlanInEditor("/tmp/session");
    expect(spawn).toHaveBeenCalledWith("subl", expect.any(Array), expect.any(Object));
  });

  it("uses $EDITOR when no $VISUAL", () => {
    process.env.EDITOR = "vim";
    openPlanInEditor("/tmp/session");
    expect(spawn).toHaveBeenCalledWith("vim", expect.any(Array), expect.any(Object));
  });

  it("spawns with detached + stdio ignore", () => {
    openPlanInEditor("/tmp/session");
    expect(spawn).toHaveBeenCalledWith(
      expect.any(String),
      expect.any(Array),
      expect.objectContaining({ detached: true, stdio: "ignore" }),
    );
  });
});

describe("openUrl", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("uses 'open' on darwin", () => {
    const origPlatform = process.platform;
    Object.defineProperty(process, "platform", { value: "darwin" });
    openUrl("https://example.com");
    expect(spawn).toHaveBeenCalledWith("open", ["https://example.com"], expect.any(Object));
    Object.defineProperty(process, "platform", { value: origPlatform });
  });

  it("spawns detached", () => {
    openUrl("https://example.com");
    expect(spawn).toHaveBeenCalledWith(
      expect.any(String),
      expect.any(Array),
      expect.objectContaining({ detached: true, stdio: "ignore" }),
    );
  });
});

describe("copyToClipboard", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("returns true on success", () => {
    vi.mocked(execSync).mockReturnValue(Buffer.from(""));
    const result = copyToClipboard("test text");
    expect(result).toBe(true);
  });

  it("returns false when command fails", () => {
    vi.mocked(execSync).mockImplementation(() => {
      throw new Error("command not found");
    });
    const result = copyToClipboard("test text");
    expect(result).toBe(false);
  });
});
