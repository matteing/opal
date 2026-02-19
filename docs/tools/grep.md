# grep

Cross-platform regex search across files with hashline-tagged output.

Returns matching lines in the same `N:hash|content` format as `read_file`, so results are immediately usable with `edit_file` anchors.

## Parameters

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `pattern` | string | yes | Regex pattern (Elixir/PCRE syntax) |
| `path` | string | no | File or directory to search (default: working dir) |
| `include` | string | no | Glob to filter filenames (e.g. `*.ex`, `*.{ex,exs}`) |
| `context_lines` | integer | no | Lines of surrounding context per match (default: 2) |
| `max_results` | integer | no | Cap on total matches returned (default: 50, max: 500) |
| `no_ignore` | boolean | no | When `true`, search files even if excluded by `.gitignore` (default: `false`) |

## Output Format

Results are grouped by file path. Each matching line includes context, all hashline-tagged:

```
## src/app.ex
10:a3|  defp helper do
11:f1|    :ok
12:0e|  end

## lib/config.ex
5:b2|  @default_timeout 30_000
```

Context ranges for adjacent matches are merged so lines aren't repeated.

When results are capped, a summary like `[Showing N matches. Results capped — refine pattern or path.]` is appended.

## Exclusions

The following directories are always skipped (even with `no_ignore`):

| Category | Directories |
|----------|-------------|
| Version control | `.git`, `.hg`, `.svn` |
| Build artifacts | `_build`, `deps`, `node_modules`, `vendor`, `.bundle` |
| Editor metadata | `.elixir_ls`, `.vscode`, `.idea` |
| Caches | `__pycache__`, `.mypy_cache`, `tmp` |

`.gitignore` patterns are respected by default. Set `no_ignore: true` to bypass `.gitignore` rules and search all non-binary files.

Binary files (containing null bytes in the first 8 KB) are silently skipped.

## Cross-Platform

This tool uses Elixir's `:re` engine (PCRE) and `File` APIs — no dependency on `grep`, `rg`, or any platform-specific binary. It works identically on macOS, Linux, and Windows.

For exotic searches (`ast-grep`, `rg --pcre2`, etc.), use the `shell` tool instead.

## Encoding

UTF-8 BOM is stripped before matching. CRLF line endings are normalized to LF for consistent hashline tagging.

## Path Safety

Paths are resolved through `Opal.FileIO.resolve_path/3` (which uses `Opal.Path.safe_relative/2`), same as `read_file` and `write_file`. Searches cannot escape the working directory or other explicitly allowed base directories.

## Truncation

Total output is capped at 50 KB. If exceeded, output is truncated at the last line boundary with a hint to narrow the pattern or path.

## Source

`lib/opal/tool/grep.ex`
