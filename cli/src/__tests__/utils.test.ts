import { describe, it, expect, vi, afterEach } from "vitest";

// Mock dependencies before importing
vi.mock("open", () => ({
  default: vi.fn(),
}));
vi.mock("clipboardy", () => ({
  default: { writeSync: vi.fn() },
}));

import clipboard from "clipboardy";
import { openUrl, copyToClipboard } from "../lib/desktop.js";

describe("openUrl", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("delegates to open package", async () => {
    const open = (await import("open")).default;
    openUrl("https://example.com");
    expect(open).toHaveBeenCalledWith("https://example.com");
  });
});

describe("copyToClipboard", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("returns true on success", () => {
    const result = copyToClipboard("test text");
    expect(result).toBe(true);
    expect(vi.mocked(clipboard).writeSync).toHaveBeenCalledWith("test text");
  });

  it("returns false when clipboard fails", () => {
    vi.mocked(clipboard).writeSync.mockImplementation(() => {
      throw new Error("clipboard unavailable");
    });
    const result = copyToClipboard("test text");
    expect(result).toBe(false);
  });
});
