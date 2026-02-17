import { Marked, type MarkedExtension } from "marked";
import { markedTerminal } from "marked-terminal";

export interface MarkdownRenderCache {
  content: string;
  width: number;
  rendered: string;
}

let cachedWidth = 0;
let cachedMarkdown: Marked | null = null;

function getRenderer(width: number): Marked {
  if (cachedMarkdown && cachedWidth === width) return cachedMarkdown;
  cachedWidth = width;

  const ext = markedTerminal({
    width,
    reflowText: true,
    tableOptions: { wordWrap: true, wrapOnWordBoundary: true },
  }) as MarkedExtension;

  // marked-terminal's `text` renderer ignores inline tokens (strong, codespan,
  // etc.) and returns the raw `.text` string.  This means bold, code, and other
  // inline formatting inside list items is never rendered.
  //
  // The extension wrapper calls `r[func](...args)` where `r` is the internal
  // Renderer instance.  `this` inside the wrapper points to the marked-internal
  // renderer context which carries `this.parser`.  We grab the original wrapper
  // so we can fall back to it for plain strings, and replace it with one that
  // delegates to `parseInline` when inline tokens exist.
  const renderers = (ext as { renderer?: Record<string, (...args: unknown[]) => string> }).renderer;
  if (renderers) {
    const origText = renderers.text;

    renderers.text = function (
      this: { parser: { parseInline: (t: unknown[]) => string } },
      token: unknown,
    ): string {
      if (
        typeof token === "object" &&
        token !== null &&
        "tokens" in token &&
        Array.isArray((token as { tokens: unknown[] }).tokens) &&
        (token as { tokens: unknown[] }).tokens.length > 0
      ) {
        return this.parser.parseInline((token as { tokens: unknown[] }).tokens);
      }
      return origText.call(this, token);
    } as (...args: unknown[]) => string;
  }

  cachedMarkdown = new Marked(ext);
  return cachedMarkdown;
}

/**
 * Close unclosed inline markers so partial streaming content renders
 * correctly instead of showing raw `**`, `` ` ``, etc.
 */
function closeOpenMarkers(text: string): string {
  // Count unmatched ``` (fenced code blocks)
  const fenceCount = (text.match(/```/g) || []).length;
  if (fenceCount % 2 !== 0) text += "\n```";

  // Count unmatched backticks (inline code) — after fences are closed
  const backtickCount = (text.match(/(?<!`)`(?!`)/g) || []).length;
  if (backtickCount % 2 !== 0) text += "`";

  // For asterisk counting, strip list markers (lines starting with * or - )
  // so they aren't mistaken for inline emphasis/bold markers.
  const inlineText = text.replace(/^[ \t]*[*\-+] /gm, "  ");

  // Bold/italic markers — close innermost first
  const tripleCount = (inlineText.match(/\*\*\*/g) || []).length;
  if (tripleCount % 2 !== 0) text += "***";

  const doubleCount = (inlineText.match(/\*\*/g) || []).length;
  if (doubleCount % 2 !== 0) text += "**";

  const singleCount = (inlineText.match(/(?<!\*)\*(?!\*)/g) || []).length;
  if (singleCount % 2 !== 0) text += "*";

  return text;
}

export function renderMarkdown(text: string, width: number): string {
  const closed = closeOpenMarkers(text);
  const result = getRenderer(width).parse(closed);
  return typeof result === "string" ? result.trimEnd() : text;
}

export function shouldReuseRenderedMarkdown(
  cache: MarkdownRenderCache,
  content: string,
  width: number,
): boolean {
  return cache.content === content && cache.width === width;
}
