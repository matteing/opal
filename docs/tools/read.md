# read_file

Reads file contents with hashline-tagged output for use with `edit_file`.

## Parameters

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `path` | string | yes | File path resolved under the working directory (or another allowed base directory) |
| `offset` | integer | no | 1-indexed start line |
| `limit` | integer | no | Max lines to return |

## Output Format

Every line is tagged with a hashline prefix `N:hash|content`:

```
1:a3|function hello() {
2:f1|  return "world";
3:0e|}
```

The hash is a 2-char hex digest of the trimmed line content. These tags are used by `edit_file` to reference lines without reproducing content.

When `offset`/`limit` are provided, only the requested range is returned (still tagged).

## Truncation

Large files are head-truncated to keep tool output within reasonable context limits:

| Condition | Behavior |
|-----------|----------|
| > 2,000 lines | Show first 2,000 with `[Showing lines S-E of T. Use offset=N to continue.]` |
| > 50 KB | Truncate at last line boundary before 50 KB |
| Single line > 50 KB | Return guidance to use `read_file` with `offset=1` and `limit=2000` (or split with a shell command) |

Head-truncation is intentional — file structure, imports, and module definitions are at the top.

## Encoding

UTF-8 BOM is stripped before output. The LLM never sees it, preventing invisible mismatches in subsequent edits. CRLF line endings are normalized to LF for consistent line splitting and hashline tagging.

## Source

`opal/lib/opal/tool/read_file.ex`, `opal/lib/opal/util/file_io.ex`, `opal/lib/opal/util/hashline.ex`
