# `Opal.RPC.Handler`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/rpc/handler.ex#L1)

Dispatches JSON-RPC methods to Opal library functions.

Pure dispatch layer — receives a method name and params map, calls into
the Opal public API, and returns a result tuple. Has no transport awareness
and no side effects beyond the Opal calls themselves.

The set of supported methods, their params, and result shapes are
declared in `Opal.RPC.Protocol` — the single source of truth for
the Opal RPC specification.

## Return Values

  * `{:ok, result}` — success, `result` is serialized as `"result"` in the response
  * `{:error, code, message, data}` — failure, serialized as a JSON-RPC error

# `result`

```elixir
@type result() :: {:ok, map()} | {:error, integer(), String.t(), term()}
```

# `handle`

```elixir
@spec handle(String.t(), map()) :: result()
```

Dispatches a JSON-RPC method call to the appropriate Opal API function.

Only methods declared in `Opal.RPC.Protocol.methods/0` are handled.
See `Opal.RPC.Protocol` for the full protocol specification.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
