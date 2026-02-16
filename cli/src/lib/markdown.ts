import { Marked, type MarkedExtension } from "marked";
import { markedTerminal } from "marked-terminal";

export interface MarkdownRenderCache {
  content: string;
  width: number;
  rendered: string;
}

let cachedWidth = 0;
let cachedMarkdown: Marked | null = null;

function getMarkdownRenderer(width: number): Marked {
  if (cachedMarkdown && cachedWidth === width) return cachedMarkdown;
  cachedWidth = width;
  cachedMarkdown = new Marked(
    markedTerminal({ width, reflowText: true, tableOptions: {} }) as MarkedExtension,
  );
  return cachedMarkdown;
}

export function renderMarkdown(text: string, width: number): string {
  const result = getMarkdownRenderer(width).parse(text);
  return typeof result === "string" ? result.trimEnd() : text;
}

export function shouldReuseRenderedMarkdown(
  cache: MarkdownRenderCache,
  content: string,
  width: number,
): boolean {
  return cache.content === content && cache.width === width;
}
