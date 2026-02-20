import { describe, it, expect } from "vitest";
import path from "node:path";
import { formatTokens, toRootRelativePath } from "../lib/formatting.js";

describe("formatTokens", () => {
  it("returns '0' for undefined", () => {
    expect(formatTokens(undefined)).toBe("0");
  });

  it("returns number as string below 1000", () => {
    expect(formatTokens(500)).toBe("500");
    expect(formatTokens(0)).toBe("0");
    expect(formatTokens(999)).toBe("999");
  });

  it("formats 1000+ as 'Nk'", () => {
    expect(formatTokens(1000)).toBe("1k");
    expect(formatTokens(1500)).toBe("2k");
    expect(formatTokens(128000)).toBe("128k");
  });

  it("rounds correctly", () => {
    expect(formatTokens(1499)).toBe("1k");
    expect(formatTokens(1501)).toBe("2k");
    expect(formatTokens(2500)).toBe("3k");
  });
});

describe("toRootRelativePath", () => {
  it("returns a root-relative path when file is under root", () => {
    const root = path.resolve("repo-root");
    const file = path.join(root, "AGENTS.md");
    expect(toRootRelativePath(file, root)).toBe("AGENTS.md");
  });

  it("uses relative path when file is outside root", () => {
    const root = path.resolve("repo-root");
    const outside = path.resolve("outside", "AGENTS.md");
    expect(toRootRelativePath(outside, root)).toBe("../outside/AGENTS.md");
  });

  it("keeps relative paths unchanged", () => {
    expect(toRootRelativePath("docs/guide.md", path.resolve("repo-root"))).toBe("docs/guide.md");
  });
});
