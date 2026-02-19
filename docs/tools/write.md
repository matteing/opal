# write_file

Creates or overwrites a file with the given content.

## Parameters

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `path` | string | yes | File path to write (under working directory, or in configured Opal data dir) |
| `content` | string | yes | Full file content |

## Behavior

- Parent directories are created automatically (`mkdir -p`).
- Path must resolve within the session's working directory or configured Opal data directory (no traversal).

## Encoding Preservation

When overwriting an existing file, the tool detects its encoding and applies it to the new content:

- **UTF-8 BOM** — If the file had a BOM, the new content gets one too.
- **CRLF line endings** — If the file used `\r\n`, new content is converted from `\n` to `\r\n`.

This prevents silent encoding corruption when the LLM writes content without `\r` or BOM bytes. New files keep provided content as-is (typically LF, no BOM).

## Source

`lib/opal/tool/write_file.ex`, `lib/opal/util/file_io.ex`
