# Providers

The provider subsystem abstracts LLM APIs behind a common behaviour. The agent loop is provider-agnostic — it works with any model through the same interface.

## Provider Behaviour

```elixir
@callback stream(model, messages, tools) :: {:ok, Req.Response.t()} | {:error, term()}
@callback parse_stream_event(String.t()) :: [event]
@callback convert_messages([Opal.Message.t()], keyword()) :: [map()]
@callback convert_tools([module()]) :: [map()]
```

- `stream/3` — Initiates an async HTTP request. Returns a `Req.Response` whose body streams SSE chunks as Erlang messages into the calling process (the Agent GenServer).
- `parse_stream_event/1` — Parses one SSE data line into semantic events (`:text_delta`, `:tool_call_start`, etc.).
- `convert_messages/2` — Translates `Opal.Message` structs into the provider's wire format.
- `convert_tools/1` — Translates tool modules into the provider's function-calling schema.

## Copilot Provider

`Opal.Provider.Copilot` implements the behaviour for GitHub Copilot's API, which proxies multiple model families.

### Two API Variants

The provider auto-detects which API to use based on model ID:

| API | Models | Endpoint |
|-----|--------|----------|
| Chat Completions | Claude, Gemini, GPT-4o, Grok | `/chat/completions` |
| Responses API | GPT-5 family | `/responses` |

Detection: model IDs containing `gpt-5` or `o3` use Responses API; everything else uses Chat Completions.

### SSE Parsing

Both APIs stream Server-Sent Events, but with different JSON structures:

**Chat Completions:**
```json
{"choices": [{"delta": {"content": "Hello"}}]}
{"choices": [{"delta": {"tool_calls": [...]}}]}
{"usage": {"prompt_tokens": 1500, "completion_tokens": 200}}
```

**Responses API:**
```json
{"type": "response.output_text.delta", "delta": "Hello"}
{"type": "response.function_call_arguments.delta", "delta": "{\"path"}
{"type": "response.completed", "response": {"usage": {"input_tokens": 1500}}}
```

The `parse_stream_event/1` function normalizes both into the same semantic events:

| Semantic Event | Meaning |
|---------------|---------|
| `{:text_start}` | New text block began |
| `{:text_delta, "Hello"}` | Streaming text token |
| `{:thinking_start}` | Reasoning began |
| `{:thinking_delta, "..."}` | Reasoning token |
| `{:tool_call_start, id, name}` | Tool call began |
| `{:tool_call_delta, id, json}` | Tool call arguments chunk |
| `{:response_done, %{usage: ...}}` | Response complete |
| `{:usage, %{...}}` | Token usage report |

## Auth

`Opal.Auth` implements GitHub's device-code OAuth flow:

1. `start_device_flow()` — POST to `/login/device/code`, get a user code + verification URL
2. User visits the URL and enters the code
3. `poll_for_token()` — Poll until GitHub returns an access token (handles `authorization_pending` and `slow_down`)
4. `exchange_copilot_token()` — Exchange the GitHub token for a Copilot API token

Tokens are persisted to `~/.opal/auth.json`. `get_token/0` auto-refreshes expired tokens (5-minute buffer before expiry).

## Adding a Provider

To add a new LLM provider:

1. Create a module implementing `Opal.Provider`
2. Implement `stream/3` to return a `Req.Response` with async SSE streaming
3. Implement `parse_stream_event/1` to normalize your API's events
4. Implement `convert_messages/2` and `convert_tools/1` for your API's format
5. Set it in config: `%Opal.Config{provider: MyProvider}`

## Source

- `core/lib/opal/provider.ex` — Behaviour definition and event types
- `core/lib/opal/provider/copilot.ex` — GitHub Copilot implementation
- `core/lib/opal/auth.ex` — Device-code OAuth and token management
