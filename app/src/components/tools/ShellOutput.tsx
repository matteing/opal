import { useMemo } from "react";
import AnsiToHtml from "ansi-to-html";
import { CopyButton } from "./CopyButton.js";

const converter = new AnsiToHtml({ fg: "#ccc", bg: "#111", newline: true });

/** shell command output with ANSI color rendering. */
export function ShellOutput({
  command,
  output,
}: {
  command: string;
  output: string;
}) {
  const html = useMemo(() => converter.toHtml(output), [output]);

  // Extract exit code if present (opal shell tool appends it)
  const exitMatch = output.match(/\[exit (\d+)\]/);
  const exitCode = exitMatch ? parseInt(exitMatch[1], 10) : null;

  const lineCount = output.split("\n").length;
  const defaultOpen = lineCount <= 25;

  return (
    <details data-role="shell-output" data-exit={exitCode} open={defaultOpen || undefined}>
      <summary>
        💻 <strong>shell</strong>{" "}
        <small>{command.length > 60 ? command.slice(0, 57) + "…" : command}</small>
        {exitCode !== null && exitCode !== 0 && (
          <span data-role="exit-error">exit {exitCode}</span>
        )}
      </summary>
      <pre dangerouslySetInnerHTML={{ __html: html }} />
      <div data-role="tool-footer">
        {exitCode !== null && <span>exit {exitCode}</span>}
        <CopyButton text={output} />
      </div>
    </details>
  );
}
