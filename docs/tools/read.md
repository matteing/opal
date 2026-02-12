# read_file

Reads file contents with hashline-tagged output for use with `edit_file`.

## Parameters

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `path` | string | yes | File path (relative to working directory) |
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
| > 2,000 lines | Show first 2,000 with `[Use offset=N to continue]` |
| > 50 KB | Truncate at last line boundary before 50 KB |
| Single line > 50 KB | Suggest `head -c` shell command instead |

Head-truncation is intentional — file structure, imports, and module definitions are at the top.

## Encoding

UTF-8 BOM is stripped before output. The LLM never sees it, preventing invisible mismatches in subsequent edits. CRLF normalization is not applied to read output (only to edit matching).

## Source

`core/lib/opal/tool/read.ex`
