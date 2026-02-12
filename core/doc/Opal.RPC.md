# `Opal.RPC`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/rpc/rpc.ex#L1)

JSON-RPC 2.0 encoding/decoding. Transport-agnostic.

Used by `Opal.RPC.Stdio` today; could be used by a WebSocket or HTTP
transport later. All functions are stateless — pure encode/decode.

## Wire Format

Messages are JSON objects conforming to the
[JSON-RPC 2.0 spec](https://www.jsonrpc.org/specification).

### Message Types

  * **Request** — `{jsonrpc, id, method, params}` — expects a response
  * **Response** — `{jsonrpc, id, result}` — success reply
  * **Error Response** — `{jsonrpc, id, error}` — failure reply
  * **Notification** — `{jsonrpc, method, params}` — fire-and-forget (no `id`)

## Error Codes

Standard JSON-RPC 2.0 error codes:

  | Code    | Constant           | Meaning                |
  | ------- | ------------------ | ---------------------- |
  | -32700  | `parse_error`      | Invalid JSON           |
  | -32600  | `invalid_request`  | Not a valid request    |
  | -32601  | `method_not_found` | Method does not exist  |
  | -32602  | `invalid_params`   | Invalid method params  |
  | -32603  | `internal_error`   | Internal server error  |

# `decoded`

```elixir
@type decoded() ::
  {:request, id(), String.t(), params()}
  | {:response, id(), term()}
  | {:error_response, id() | nil, map()}
  | {:notification, String.t(), params()}
  | {:error, :parse_error | :invalid_request}
```

# `error`

```elixir
@type error() :: %{code: integer(), message: String.t(), data: term() | nil}
```

# `error_response`

```elixir
@type error_response() :: %{jsonrpc: String.t(), id: id() | nil, error: error()}
```

# `id`

```elixir
@type id() :: integer() | String.t()
```

# `message`

```elixir
@type message() :: request() | response() | error_response() | notification()
```

# `notification`

```elixir
@type notification() :: %{jsonrpc: String.t(), method: String.t(), params: params()}
```

# `params`

```elixir
@type params() :: map()
```

# `request`

```elixir
@type request() :: %{
  jsonrpc: String.t(),
  id: id(),
  method: String.t(),
  params: params()
}
```

# `response`

```elixir
@type response() :: %{jsonrpc: String.t(), id: id(), result: term()}
```

# `decode`

```elixir
@spec decode(String.t()) :: decoded()
```

Decodes a JSON string into a tagged message tuple.

Returns one of:

  * `{:request, id, method, params}` — client or server request
  * `{:response, id, result}` — success response
  * `{:error_response, id, error_map}` — error response
  * `{:notification, method, params}` — fire-and-forget
  * `{:error, :parse_error}` — invalid JSON
  * `{:error, :invalid_request}` — valid JSON but not JSON-RPC 2.0

## Examples

    iex> Opal.RPC.decode(~s({"jsonrpc":"2.0","id":1,"method":"ping","params":{}}))
    {:request, 1, "ping", %{}}

    iex> Opal.RPC.decode(~s({"jsonrpc":"2.0","method":"notify","params":{}}))
    {:notification, "notify", %{}}

    iex> Opal.RPC.decode("not json")
    {:error, :parse_error}

# `encode_error`

```elixir
@spec encode_error(id() | nil, integer(), String.t(), term()) :: String.t()
```

Encodes a JSON-RPC 2.0 error response.

## Examples

    iex> Opal.RPC.encode_error(1, -32601, "Method not found")
    ~s({"error":{"code":-32601,"message":"Method not found"},"id":1,"jsonrpc":"2.0"})

# `encode_notification`

```elixir
@spec encode_notification(String.t(), params()) :: String.t()
```

Encodes a JSON-RPC 2.0 notification (no `id`).

## Examples

    iex> Opal.RPC.encode_notification("agent/event", %{type: "token"})
    ~s({"jsonrpc":"2.0","method":"agent/event","params":{"type":"token"}})

# `encode_request`

```elixir
@spec encode_request(id(), String.t(), params()) :: String.t()
```

Encodes a JSON-RPC 2.0 request.

## Examples

    iex> Opal.RPC.encode_request(1, "agent/prompt", %{text: "hello"})
    ~s({"id":1,"jsonrpc":"2.0","method":"agent/prompt","params":{"text":"hello"}})

# `encode_response`

```elixir
@spec encode_response(id(), term()) :: String.t()
```

Encodes a JSON-RPC 2.0 success response.

## Examples

    iex> Opal.RPC.encode_response(1, %{ok: true})
    ~s({"id":1,"jsonrpc":"2.0","result":{"ok":true}})

# `internal_error`

```elixir
@spec internal_error() :: integer()
```

Internal error code (-32603).

# `invalid_params`

```elixir
@spec invalid_params() :: integer()
```

Invalid params code (-32602).

# `invalid_request`

```elixir
@spec invalid_request() :: integer()
```

Invalid request code (-32600).

# `method_not_found`

```elixir
@spec method_not_found() :: integer()
```

Method not found code (-32601).

# `parse_error`

```elixir
@spec parse_error() :: integer()
```

Parse error code (-32700).

---

*Consult [api-reference.md](api-reference.md) for complete listing*
