# Engineering TODO

- [ ] Shell tool: some sort of proactivity for terminal commands — agent loop can look at output and terminate accordingly, or set higher timeouts
- [ ] Compaction: figure out whether it works fully, do analysis into state dumps
- [ ] Agent loop: mid-execution observation and steering, tool output back to agent not just UI
- [ ] CLI: fix the damn inputs
- [ ] Evaluate moving away from MCP toward skills + CLIs — industry trending this direction; the Playwright rationale is compelling (tools as focused CLI binaries rather than long-running servers). See https://github.com/microsoft/playwright-mcp. Skills already work well for us; MCP bridge may be unnecessary complexity
