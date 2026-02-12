# `Opal.Provider`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/provider.ex#L1)

Behaviour for LLM provider implementations.

Each provider must implement streaming, SSE event parsing, and conversion
of internal message/tool representations to the provider's wire format.

# `stream_event`

```elixir
@type stream_event() ::
  {:text_start, map()}
  | {:text_delta, String.t()}
  | {:text_done, String.t()}
  | {:thinking_start, map()}
  | {:thinking_delta, String.t()}
  | {:tool_call_start, map()}
  | {:tool_call_delta, String.t()}
  | {:tool_call_done, map()}
  | {:response_done, map()}
  | {:usage, map()}
  | {:error, term()}
```

# `convert_messages`

```elixir
@callback convert_messages(model :: Opal.Model.t(), messages :: [Opal.Message.t()]) :: [
  map()
]
```

Converts internal `Opal.Message` structs to the provider's wire format.

# `convert_tools`

```elixir
@callback convert_tools(tools :: [module()]) :: [map()]
```

Converts tool modules implementing `Opal.Tool` to the provider's wire format.

# `parse_stream_event`

```elixir
@callback parse_stream_event(data :: String.t()) :: [stream_event()]
```

Parses a raw SSE data line into a list of stream events.

Returns an empty list for events that should be ignored.

# `stream`

```elixir
@callback stream(
  model :: Opal.Model.t(),
  messages :: [Opal.Message.t()],
  tools :: [module()],
  opts :: keyword()
) :: {:ok, Req.Response.t()} | {:error, term()}
```

Initiates a streaming request to the LLM provider.

Returns `{:ok, resp}` where `resp` can be used with `Req.parse_message/2`
to iterate over SSE chunks arriving in the calling process's mailbox.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
