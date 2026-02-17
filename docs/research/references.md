# References

Compiled from `## References` sections across the docs.

## Projects & Inspiration

- [Pi](https://pi.dev) — The best open-source harness, huge source of inspiration. ([README](../../README.md))
- [oh-my-pi](https://github.com/can1357/oh-my-pi) — An awesome customization of Pi with so many goodies and tricks. ([README](../../README.md))

## Edit Formats & Benchmarks

- [The Harness Problem](https://blog.can.ac/2026/02/12/the-harness-problem/) — Can Bölük, 2026. Benchmark of edit formats across 16 models showing hashline outperforms str_replace and patch. ([edit](../tools/edit.md))
- [oh-my-pi react-edit-benchmark](https://github.com/can1357/oh-my-pi/tree/main/packages/react-edit-benchmark) — Benchmark code and per-run reports. ([edit](../tools/edit.md))
- [Diff-XYZ benchmark](https://arxiv.org/abs/2510.12487) — JetBrains. No single edit format dominates across models and use cases. ([edit](../tools/edit.md))
- [EDIT-Bench](https://arxiv.org/abs/2511.04486) — Only one model achieves over 60% pass@1 on realistic editing tasks. ([edit](../tools/edit.md))
- [Aider benchmarks](https://aider.chat/docs/benchmarks.html) — Format choice swung GPT-4 Turbo from 26% to 59%. ([edit](../tools/edit.md))
- [Cursor Instant Apply](https://cursor.com/blog/instant-apply) — Fine-tuned 70B model for edit application; full rewrite outperforms diffs for files under 400 lines. ([edit](../tools/edit.md))

## OTP & Erlang

- [Erlang `gen_statem`](https://www.erlang.org/doc/man/gen_statem.html) — OTP state machine behaviour used by `Opal.Agent`. ([agent-loop](../agent-loop.md))
- [Elixir `GenServer`](https://hexdocs.pm/elixir/GenServer.html) — Messaging model still used by sibling subsystems and APIs around the loop. ([agent-loop](../agent-loop.md))
- [Erlang/OTP Supervisor Principles](https://www.erlang.org/doc/design_principles/sup_princ.html) — Supervision strategy used by session-local processes and tool tasks. ([agent-loop](../agent-loop.md))
- [Erlang Distribution Protocol](https://www.erlang.org/doc/system/distributed.html) — Official docs covering node naming, cookies, and EPMD. ([erlang](../erlang.md))
- [Erlang Distribution Security Guide](https://www.erlang.org/doc/system/ssl_distribution.html) — How to enable TLS for inter-node traffic. ([erlang](../erlang.md))

## LLM Providers & Models

- [ReqLLM](https://github.com/agentjido/req_llm) — Composable Elixir LLM library built on Req. Powers the LLM provider with support for 45+ providers and 665+ models. ([providers](../providers.md))
- [ReqLLM StreamResponse](https://hexdocs.pm/req_llm/ReqLLM.StreamResponse.html) — Streaming API used by the bridge layer. ([providers](../providers.md))
- [LLMDB](https://hexdocs.pm/llmdb) — Model database bundled with ReqLLM. Powers auto-discovery of models, context windows, and capabilities. ([providers](../providers.md))
- [ReqLLM (doughsay)](https://github.com/doughsay/req_llm) — The library powering the generic LLM provider. ([installing](../installing.md))

## Reasoning & Thinking

- [OpenAI Reasoning Guide](https://developers.openai.com/api/docs/guides/reasoning) — Official docs for `reasoning.effort` and `reasoning.summary` parameters on the Responses API. ([reasoning](../reasoning.md))
- [Anthropic Extended Thinking](https://platform.claude.com/docs/en/build-with-claude/extended-thinking) — Official docs for budget-based and adaptive thinking modes, including `output_config.effort` levels. ([reasoning](../reasoning.md))
- [opencode#6864](https://github.com/anomalyco/opencode/issues/6864) — Confirms the Copilot proxy does not return `reasoning_content` for Claude models. Other tools experience the same limitation. ([reasoning](../reasoning.md))

## User Interaction & Planning

- [Handle approvals and user input](https://platform.claude.com/docs/en/agent-sdk/user-input) — Anthropic, 2025. Claude Agent SDK documentation for surfacing approval requests and clarifying questions. Informed the `ask_user` tool design and the planning approach. ([user-input](../tools/user-input.md), [planning](../planning.md))

## Auth & Standards

- [RFC 8628 — OAuth 2.0 Device Authorization Grant](https://datatracker.ietf.org/doc/html/rfc8628) — GitHub device-code OAuth flow used by Opal. ([installing](../installing.md))

## Context Files & Agent Instructions

- [Evaluating AGENTS.md: Are Repository-Level Context Files Helpful for Coding Agents?](https://arxiv.org/abs/2602.11988) — Gloaguen et al., 2026. Finds that AGENTS.md context files tend to reduce task success rates while increasing inference cost by 20%+; recommends minimal requirements only. (arxiv)

---

## TODO

Papers and resources to review and potentially integrate:

- [LCM: Lossless Context Management](https://papers.voltropy.com/LCM) — "We introduce Lossless Context Management (LCM), a deterministic architecture for LLM memory that outperforms Claude Code on long-context tasks. When benchmarked using Opus 4.6, our LCM-augmented coding agent, Volt, achieves higher scores than Claude Code on the OOLONG long-context eval, including at every context length between 32K and 1M tokens."
- [Playwright MCP](https://github.com/microsoft/playwright-mcp) — Microsoft's Playwright tooling for agents; rationale for CLI-based tools over MCP servers — simpler, stateless, composable. Relevant to evaluating whether Opal should move away from MCP toward skills + CLIs. (todo)
