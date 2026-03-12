import { CodeBlock } from "./CodeBlock.js";
import { CopyButton } from "./CopyButton.js";

/** Detect file extension → language name for display. */
function extToLang(path: string): string | undefined {
  const ext = path.split(".").pop()?.toLowerCase();
  const map: Record<string, string> = {
    ts: "TypeScript", tsx: "TypeScript", js: "JavaScript", jsx: "JavaScript",
    py: "Python", rb: "Ruby", rs: "Rust", go: "Go", ex: "Elixir",
    exs: "Elixir", erl: "Erlang", java: "Java", kt: "Kotlin", cs: "C#",
    cpp: "C++", c: "C", h: "C", md: "Markdown", json: "JSON", yaml: "YAML",
    yml: "YAML", toml: "TOML", html: "HTML", css: "CSS", sql: "SQL",
    sh: "Shell", bash: "Shell", zsh: "Shell", xml: "XML", swift: "Swift",
  };
  return ext ? map[ext] : undefined;
}

/** read_file result: file contents with syntax highlighting. */
export function FileViewer({
  name,
  output,
}: {
  name: string;
  output: string;
}) {
  // Parse the file path from the tool name or args
  const lang = extToLang(name);

  // Determine line count for auto-collapse
  const lineCount = output.split("\n").length;
  const defaultOpen = lineCount <= 30;

  return (
    <details data-role="file-viewer" open={defaultOpen || undefined}>
      <summary>
        📄 <strong>read_file</strong> <small>{name}</small>
      </summary>
      <CodeBlock code={output} language={lang} />
    </details>
  );
}

/** edit_file result: unified diff view with additions/deletions. */
export function DiffView({
  name,
  output,
}: {
  name: string;
  output: string;
}) {
  const lines = output.split("\n");
  let additions = 0;
  let deletions = 0;

  for (const line of lines) {
    if (line.startsWith("+") && !line.startsWith("+++")) additions++;
    if (line.startsWith("-") && !line.startsWith("---")) deletions++;
  }

  return (
    <details data-role="diff-view">
      <summary>
        ✏️ <strong>edit_file</strong> <small>{name}</small>
        <span data-role="diff-stats">
          {additions > 0 && <span data-diff="add">+{additions}</span>}
          {deletions > 0 && <span data-diff="del">-{deletions}</span>}
        </span>
      </summary>
      <pre data-role="diff-content">
        {lines.map((line, i) => {
          let type: string | undefined;
          if (line.startsWith("+") && !line.startsWith("+++")) type = "add";
          else if (line.startsWith("-") && !line.startsWith("---")) type = "del";

          return (
            <span key={i} data-diff={type}>
              {line}
              {"\n"}
            </span>
          );
        })}
      </pre>
      <div data-role="tool-footer">
        <span>{additions} addition{additions !== 1 ? "s" : ""}, {deletions} deletion{deletions !== 1 ? "s" : ""}</span>
        <CopyButton text={output} />
      </div>
    </details>
  );
}

/** write_file result: new/overwritten file display. */
export function WriteFileView({
  name,
  output,
}: {
  name: string;
  output: string;
}) {
  const lang = extToLang(name);
  const lineCount = output.split("\n").length;
  const defaultOpen = lineCount <= 20;

  return (
    <details data-role="file-viewer" open={defaultOpen || undefined}>
      <summary>
        📝 <strong>write_file</strong> <small>{name}</small>
      </summary>
      <CodeBlock code={output} language={lang} />
    </details>
  );
}
