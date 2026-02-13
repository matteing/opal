# Installing

Opal can be installed as a **CLI tool via npm** for interactive use, or as an **Elixir dependency** for embedding in your own application.

## CLI (npm)

Requires Node.js ≥ 22.

```bash
npm i -g @unfinite/opal
opal
```

On first launch, if no other provider API key is set, Opal will prompt you to authenticate with GitHub Copilot (see [Authentication](#authentication) below). Once authenticated, you're ready to go.

## Elixir library

Add Opal to your `mix.exs`:

```elixir
defp deps do
  [{:opal, "~> 0.1"}]
end
```

Then start it under your supervision tree or use the API directly. See the [SDK docs](sdk.md) for the full integration guide.

## Authentication

Opal needs access to an LLM provider. There are two paths depending on which provider you want to use.

### GitHub Copilot (default)

If you have a GitHub Copilot subscription (individual, business, or enterprise), Opal can authenticate using GitHub's device-code OAuth flow.

**First-time setup:**

1. Launch `opal`. It will detect that you're not authenticated and start the device-code flow.
2. A URL and a one-time code are displayed in your terminal.
3. Open the URL in your browser, enter the code, and authorize the app.
4. Opal exchanges the GitHub token for a Copilot API token automatically.

That's it. Tokens are persisted to `~/.opal/auth.json` and refreshed automatically when they expire. You won't need to re-authenticate unless you revoke access.

**GitHub Enterprise:**

If you're on GitHub Enterprise Server, set the domain before launching:

```bash
OPAL_COPILOT_DOMAIN=github.mycompany.com opal
```

Or in your Elixir config:

```elixir
config :opal, copilot: [domain: "github.mycompany.com"]
```

### Other providers (Anthropic, OpenAI, Google, etc.)

Opal's second provider uses [ReqLLM](https://github.com/doughsay/req_llm), which supports Anthropic, OpenAI, Google, Groq, OpenRouter, xAI, AWS Bedrock, and more. These providers authenticate via API keys.

Set the appropriate environment variable for your provider:

```bash
# Anthropic
export ANTHROPIC_API_KEY=sk-ant-...

# OpenAI
export OPENAI_API_KEY=sk-...

# Google
export GOOGLE_API_KEY=...

# Groq
export GROQ_API_KEY=...

# OpenRouter
export OPENROUTER_API_KEY=...
```

Then launch Opal with the `--model` flag specifying `provider/model`:

```bash
opal --model anthropic/claude-sonnet-4
opal --model openai/gpt-4o
opal --model google/gemini-2.5-pro
```

When using Opal as a library, you can also set keys programmatically:

```elixir
ReqLLM.put_key(:anthropic_api_key, "sk-ant-...")
```

See the [Providers docs](providers.md) for the full list of supported providers, model discovery, and how auto-selection works.

## Configuration

Opal stores its data in `~/.opal/` (or `%APPDATA%/opal` on Windows). This includes:

| Path | Purpose |
|------|---------|
| `~/.opal/auth.json` | Copilot OAuth tokens |
| `~/.opal/settings.json` | Persistent user preferences (e.g. default model) |
| `~/.opal/sessions/` | Saved conversation sessions (JSONL) |
| `~/.opal/logs/` | Log files |

### Environment variables

| Variable | Description |
|----------|-------------|
| `OPAL_DATA_DIR` | Override the data directory (default: `~/.opal`) |
| `OPAL_SHELL` | Shell to use for the `shell` tool (`bash`, `zsh`, `sh`, `cmd`, `powershell`) |
| `OPAL_COPILOT_DOMAIN` | GitHub domain for Copilot auth (default: `github.com`) |
| `ANTHROPIC_API_KEY` | Anthropic API key (for ReqLLM provider) |
| `OPENAI_API_KEY` | OpenAI API key (for ReqLLM provider) |
| `GOOGLE_API_KEY` | Google API key (for ReqLLM provider) |

### Elixir application config

When using Opal as a library, you can configure it via application config:

```elixir
# config/config.exs
config :opal,
  data_dir: "/custom/path",
  shell: :zsh,
  copilot: [domain: "github.mycompany.com"]
```

## References

- [Providers](providers.md) — full provider docs, model discovery, behaviour spec
- [SDK](sdk.md) — embedding Opal in your Elixir app
- [ReqLLM](https://github.com/doughsay/req_llm) — the library powering the generic LLM provider
- GitHub device-code OAuth flow: [RFC 8628](https://datatracker.ietf.org/doc/html/rfc8628)
