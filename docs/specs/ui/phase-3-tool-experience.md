# Phase 3 — Tool Experience

> Rich tool rendering, file diffs, sub-agent views, and enhanced conversation display.

## Goal

Elevate tool outputs from plain text into rich, interactive displays. File edits show diffs, shell commands show formatted output, sub-agents are visible as nested work items, and the overall conversation rendering supports markdown. This is where the desktop app starts to shine compared to the terminal.

## Prerequisites

- Phase 2 complete (multi-session works)

## Scope

### In Scope

- Markdown rendering for assistant messages (with streaming support)
- Syntax-highlighted code blocks
- File diff visualization for `edit_file` and `write_file` tool results
- File content display for `read_file` with syntax highlighting
- Shell command output with ANSI color support
- `grep` results with file/line linking
- Sub-agent nested display (expand/collapse sub-agent work)
- Task tracker visualization (DAG view of tasks from the `tasks` tool)
- Inline images (if tool output includes image paths)
- Copy-to-clipboard for code blocks and tool outputs
- Tool execution timing display
- Collapsible tool groups (e.g., "5 file operations" collapsed into one)

### Out of Scope

- Settings and auth flows (Phase 4)
- Scheduling (Phase 5)

## Tool Rendering

### `read_file` — File Viewer

Display file contents with syntax highlighting in a code viewer component.

```
┌─ read_file: src/auth.ts (lines 1-45) ────────┐
│  1 │ import { hash } from "bcrypt";            │
│  2 │ import { sign } from "jsonwebtoken";       │
│  3 │                                            │
│  4 │ export async function login(              │
│  5 │   email: string,                           │
│  ...│                                           │
│ 45 │ }                                          │
├────────────────────────────────────────────────┤
│ TypeScript · 45 lines                    [Copy]│
└────────────────────────────────────────────────┘
```

- Syntax highlighting via **Shiki v4** (WASM-based, runs in the browser, requires Node.js 20+)
- Line numbers matching the hashline output
- Language auto-detected from file extension via Shiki's bundled grammar set
- Copy button for the full content
- Collapsed by default when output exceeds 30 lines

### `edit_file` — Diff View

Display edits as a unified diff with additions and deletions highlighted.

```
┌─ edit_file: src/auth.ts ──────────────────────┐
│  @@ lines 12-15 @@                            │
│  12 │   const token = sign(payload, secret);    │
│- 13 │   return token;                           │
│+ 13 │   return { token, expiresIn: 3600 };      │
│  14 │ }                                         │
├────────────────────────────────────────────────┤
│ 1 addition, 1 deletion                  [Copy] │
└────────────────────────────────────────────────┘
```

- Parse the edit tool's result to extract before/after
- Unified diff format (not side-by-side — too wide for the conversation column)
- Line-level highlighting: green for additions, red for deletions
- Collapsed by default; summary shows "N additions, M deletions"

### `write_file` — File Created/Overwritten

```
┌─ write_file: src/config.ts (new file) ────────┐
│  1 │ export const config = {                    │
│  2 │   port: 3000,                              │
│  3 │   database: "postgres://...",              │
│  4 │ };                                         │
├────────────────────────────────────────────────┤
│ TypeScript · 4 lines · new file         [Copy] │
└────────────────────────────────────────────────┘
```

- Full file content with syntax highlighting
- "new file" or "overwritten" indicator
- Collapsed by default for files > 20 lines

### `shell` — Command Output

```
┌─ shell: npm test ─────────────────────────────┐
│ $ npm test                                     │
│                                                │
│  PASS  src/auth.test.ts                        │
│  PASS  src/config.test.ts                      │
│                                                │
│  Tests: 12 passed, 12 total                    │
│  Time:  2.34s                                  │
├────────────────────────────────────────────────┤
│ exit 0 · 2.3s                           [Copy] │
└────────────────────────────────────────────────┘
```

- ANSI color code rendering (using something like `ansi-to-html`)
- Monospace font, terminal-like appearance
- Exit code and execution duration in footer
- Auto-collapsed for output > 25 lines, showing the last 5 lines as preview
- Non-zero exit codes highlighted

### `grep` — Search Results

```
┌─ grep: "authenticate" in src/**/*.ts ─────────┐
│ src/auth.ts                                    │
│   12 │ export async function authenticate(     │
│   45 │   return authenticate(token);            │
│ src/middleware.ts                               │
│   8  │ const user = await authenticate(req);    │
├────────────────────────────────────────────────┤
│ 3 matches in 2 files                    [Copy] │
└────────────────────────────────────────────────┘
```

- Results grouped by file
- Line numbers and match context
- Match text highlighted
- File names as headers

### `sub_agent` — Nested Agent View

Sub-agent work renders as a collapsible nested timeline within the parent conversation:

```
┌─ sub_agent: "Research auth patterns" ─────────┐
│ ▸ Status: completed                            │
│                                                │
│   ┌ Sub-agent timeline (collapsed) ──────────┐ │
│   │ ● read_file src/auth.ts                  │ │
│   │ ● grep "jwt" in src/                     │ │
│   │ ● read_file src/middleware.ts             │ │
│   │                                           │ │
│   │ "The auth module uses JWT tokens with..." │ │
│   └───────────────────────────────────────────┘ │
├────────────────────────────────────────────────┤
│ 4 tool calls · 12.3s                          │
└────────────────────────────────────────────────┘
```

- Sub-agent events come via `subAgentEvent` — each contains a nested `AgentEvent`
- Timeline is rendered recursively using the same components
- Collapsed by default with a summary line
- Expand to see full sub-agent work including its tools and messages
- Status indicator: running spinner, completed checkmark, or error icon

### `tasks` — Task Tracker

When the agent uses the `tasks` tool, render the task DAG visually:

```
┌─ Task Plan ───────────────────────────────────┐
│ ✓ Set up project structure                     │
│ ✓ Create database schema                       │
│ ● Implement auth endpoints        (in progress)│
│   → depends on: database schema                │
│ ○ Write auth tests                   (blocked) │
│   → depends on: auth endpoints                 │
│ ○ Add middleware                      (pending) │
├────────────────────────────────────────────────┤
│ 2/5 complete                                   │
└────────────────────────────────────────────────┘
```

- Visual status: ✓ done, ● in progress, ○ pending, ✗ blocked
- Dependencies shown as indented "depends on" lines
- Progress bar or fraction at the bottom
- Updated in real-time as the agent completes tasks

## Markdown Rendering

### Streaming Markdown

Rendering markdown while streaming is tricky because partial markdown (e.g., an unclosed code fence) produces broken output. The approach:

1. **Buffer approach**: Accumulate the full text and re-render on each delta. Use a fast markdown parser (e.g., `marked` or `markdown-it`) that handles partial input gracefully.
2. **Code fence detection**: Track whether we're inside a code fence. If yes, render the in-progress block as a code block with a "streaming" indicator.
3. **Debounce rendering**: Don't re-parse on every single character. Batch deltas and re-render every 50-100ms.

```typescript
// Simplified streaming markdown approach
function StreamingMarkdown({ text, isStreaming }: Props) {
  const html = useMemo(() => {
    let input = text;
    // If streaming and inside an unclosed code fence, close it temporarily
    if (isStreaming && (input.match(/```/g) || []).length % 2 !== 0) {
      input += "\n```";
    }
    return marked.parse(input);
  }, [text, isStreaming]);

  return <div dangerouslySetInnerHTML={{ __html: html }} />;
}
```

### Code Blocks

Code blocks within markdown get the same syntax highlighting treatment as `read_file` output:

- Language detection from the fence tag (` ```typescript `)
- Copy button on hover
- Line numbers for blocks > 5 lines

## Component Inventory (New/Updated)

| Component | Purpose |
|-----------|---------|
| `MarkdownRenderer` | Streaming-aware markdown to HTML |
| `CodeBlock` | Syntax-highlighted code with copy button |
| `DiffView` | Unified diff display for file edits |
| `FileViewer` | Syntax-highlighted file content display |
| `ShellOutput` | ANSI-aware terminal output |
| `GrepResults` | Grouped search results with highlighting |
| `SubAgentTimeline` | Nested collapsible sub-agent work |
| `TaskTracker` | DAG task visualization |
| `CopyButton` | Copy-to-clipboard for any content block |
| `ToolGroup` | Collapse multiple consecutive tools into a summary |

## Tool Output Collapsing

When the agent runs many tools in sequence, the conversation can get long. Tool groups collapse consecutive tool calls:

- **Auto-collapse**: If ≥ 3 consecutive tools of the same type run, collapse them into a summary: "5 file reads" or "3 shell commands"
- **Expand**: Click to see individual tool outputs
- **Always show errors**: Failed tools are never auto-collapsed

## Dependencies (Phase 3 Additions)

```json
{
  "dependencies": {
    "shiki": "^4.0",
    "marked": "^17",
    "ansi-to-html": "^0.7"
  }
}
```

> **Version notes**:
> - Shiki 4.0 drops Node.js 18 support (Electron 40 ships Node.js 24, so this is fine). Use the browser/WASM bundle for the renderer.
> - `marked` for markdown parsing — lightweight, streaming-friendly, actively maintained.
> - `ansi-to-html` for converting ANSI escape codes in shell output to styled HTML.

## Acceptance Criteria

1. Assistant messages render as formatted markdown with syntax-highlighted code blocks
2. `read_file` results display with syntax highlighting and line numbers
3. `edit_file` results show a unified diff with additions/deletions highlighted
4. `write_file` results show the created file with syntax highlighting
5. `shell` results render ANSI colors and show exit code + duration
6. `grep` results group by file with highlighted matches
7. Sub-agent work renders as a collapsible nested timeline
8. Task tracker renders the DAG with status indicators
9. Code blocks and tool outputs have copy-to-clipboard buttons
10. Long tool outputs are collapsed by default with a preview
11. Consecutive similar tools are grouped when there are 3+
12. Markdown renders correctly while streaming (no broken fences)
