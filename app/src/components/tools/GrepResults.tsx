import { CopyButton } from "./CopyButton.js";

/** grep results grouped by file with highlighted matches. */
export function GrepResults({
  output,
}: {
  output: string;
}) {
  const lines = output.split("\n").filter(Boolean);

  // Group lines by file header (lines without leading whitespace are file paths)
  const groups: { file: string; matches: string[] }[] = [];
  let current: { file: string; matches: string[] } | null = null;

  for (const line of lines) {
    // Hashline-tagged output: "file.ts:12:#abc123: content"
    // Or plain: "file.ts:12: content"
    const fileMatch = line.match(/^(\S+?):(\d+):/);
    if (fileMatch) {
      const file = fileMatch[1];
      if (!current || current.file !== file) {
        current = { file, matches: [] };
        groups.push(current);
      }
      current.matches.push(line);
    } else {
      // Context line or other — add to current group
      if (current) current.matches.push(line);
    }
  }

  const totalMatches = groups.reduce((sum, g) => sum + g.matches.length, 0);

  return (
    <details data-role="grep-results">
      <summary>
        🔍 <strong>grep</strong>{" "}
        <small>{totalMatches} match{totalMatches !== 1 ? "es" : ""} in {groups.length} file{groups.length !== 1 ? "s" : ""}</small>
      </summary>
      <div>
        {groups.map((group) => (
          <div key={group.file} data-role="grep-group">
            <strong>{group.file}</strong>
            <pre>
              {group.matches.map((m, i) => (
                <span key={i}>
                  {m}
                  {"\n"}
                </span>
              ))}
            </pre>
          </div>
        ))}
      </div>
      <div data-role="tool-footer">
        <span>{totalMatches} match{totalMatches !== 1 ? "es" : ""} in {groups.length} file{groups.length !== 1 ? "s" : ""}</span>
        <CopyButton text={output} />
      </div>
    </details>
  );
}
