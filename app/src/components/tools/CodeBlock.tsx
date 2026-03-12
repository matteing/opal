import { CopyButton } from "./CopyButton.js";

/**
 * Syntax-highlighted code block with line numbers and copy button.
 * Highlighting is done via CSS classes on a `data-lang` attribute —
 * no WASM runtime (Shiki) in Phase 3; that's an optimization for later.
 */
export function CodeBlock({
  code,
  language,
  startLine = 1,
  showLineNumbers = true,
}: {
  code: string;
  language?: string;
  startLine?: number;
  showLineNumbers?: boolean;
}) {
  const lines = code.split("\n");
  // Strip trailing empty line from trailing newline
  if (lines.length > 1 && lines[lines.length - 1] === "") lines.pop();

  return (
    <div data-role="code-block" data-lang={language ?? ""}>
      <div data-role="code-header">
        {language && <span>{language}</span>}
        <span>{lines.length} lines</span>
        <CopyButton text={code} />
      </div>
      <pre>
        <code>
          {lines.map((line, i) => (
            <span key={i} data-role="code-line">
              {showLineNumbers && (
                <span data-role="line-number">{startLine + i}</span>
              )}
              {line}
              {"\n"}
            </span>
          ))}
        </code>
      </pre>
    </div>
  );
}
