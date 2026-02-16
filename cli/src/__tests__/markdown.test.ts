import { describe, it, expect } from "vitest";
import {
  renderMarkdown,
  shouldReuseRenderedMarkdown,
  type MarkdownRenderCache,
} from "../lib/markdown.js";

function stripAnsi(text: string): string {
  return text.replace(/\u001b\[[0-9;]*m/g, "");
}

describe("renderMarkdown", () => {
  it("renders bold markdown instead of raw markers", () => {
    const output = stripAnsi(renderMarkdown("**bold text**", 80));
    expect(output).toContain("bold text");
    expect(output).not.toContain("**bold text**");
  });

  it("renders GFM tables with terminal table output", () => {
    const output = stripAnsi(renderMarkdown("| a | b |\n| --- | --- |\n| 1 | 2 |", 80));
    expect(output).toContain("┌");
    expect(output).toContain("┐");
    expect(output).not.toContain("| a | b |");
  });

  it("reflows markdown to the requested width", () => {
    const output = stripAnsi(
      renderMarkdown(
        "This paragraph should wrap to fit the current terminal width when rendered.",
        24,
      ),
    );

    const maxLineLength = Math.max(...output.split("\n").map((line) => line.trimEnd().length));

    expect(maxLineLength).toBeLessThanOrEqual(24);
  });
});

describe("shouldReuseRenderedMarkdown", () => {
  const cache: MarkdownRenderCache = {
    content: "**same**",
    width: 80,
    rendered: "same",
  };

  it("returns true when content and width match", () => {
    expect(shouldReuseRenderedMarkdown(cache, "**same**", 80)).toBe(true);
  });

  it("returns false when width changes", () => {
    expect(shouldReuseRenderedMarkdown(cache, "**same**", 40)).toBe(false);
  });

  it("returns false when content changes", () => {
    expect(shouldReuseRenderedMarkdown(cache, "**different**", 80)).toBe(false);
  });
});
