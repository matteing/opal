# write_file

Creates or overwrites a file with the given content.

## Parameters

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `path` | string | yes | File path (relative to working directory) |
| `content` | string | yes | Full file content |

## Behavior

- Parent directories are created automatically (`mkdir -p`).
- Path must resolve within the session's working directory (no traversal).

## Encoding Preservation

When overwriting an existing file, the tool detects its encoding and applies it to the new content:

- **UTF-8 BOM** — If the file had a BOM, the new content gets one too.
- **CRLF line endings** — If the file used `\r\n`, new content is converted from `\n` to `\r\n`.

This prevents silent encoding corruption when the LLM writes content without `\r` or BOM bytes. New files use platform defaults (LF, no BOM).

## Source

`core/lib/opal/tool/write.ex`, `core/lib/opal/tool/file_helper.ex`
