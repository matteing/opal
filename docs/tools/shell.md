# shell

Executes shell commands in the session's working directory with streaming output.

## Parameters

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `command` | string | yes | Shell command to execute |
| `timeout` | integer | no | Timeout in ms (default: 30,000) |

## Behavior

The tool detects the shell from the session config (sh, bash, zsh, cmd, powershell) and falls back to platform defaults. The command runs as a child process with stdout and stderr combined.

Output is streamed back in real-time via an `emit` callback, so the CLI shows progress as commands run. When the command completes, the full output is returned as the tool result.

## Truncation

Output is **tail-truncated** (opposite of `read_file`) — the last 2,000 lines or 50 KB are kept. Error output and final status are at the end, so tail-truncation preserves the most useful information.

When truncated, full output is saved to a temp file (`/tmp/opal-shell-*.log`) and the path is included in the result.

## Exit Codes

Non-zero exit codes produce an error result containing the output and the exit code. The LLM sees the error and can decide how to proceed.

## Source

`core/lib/opal/tool/shell.ex`
