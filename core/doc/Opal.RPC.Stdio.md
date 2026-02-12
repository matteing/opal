# `Opal.RPC.Stdio`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/rpc/stdio.ex#L1)

JSON-RPC 2.0 transport over stdin/stdout.

Reads newline-delimited JSON from stdin, dispatches via `Opal.RPC.Handler`,
writes responses to stdout. Subscribes to `Opal.Events` and emits
notifications for streaming events.

The set of supported methods, event types, and server→client requests
are declared in `Opal.RPC.Protocol` — the single source of truth for
the Opal RPC specification.

## Server → Client Requests

The server can send requests to the client (e.g., for user confirmations)
via `request_client/3`. The response is delivered asynchronously when the
client sends back a JSON-RPC response with the matching `id`.

## Wire Format

Each message is a single JSON object followed by `\n` on stdin/stdout.
This matches the MCP stdio transport convention. All logging goes to stderr.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `notify`

```elixir
@spec notify(String.t(), map()) :: :ok
```

Sends a notification to the connected client.

Fire-and-forget — no response expected.

# `request_client`

```elixir
@spec request_client(String.t(), map(), timeout()) ::
  {:ok, term()} | {:error, :timeout}
```

Sends a request to the connected client and waits for a response.

Used for server→client requests like user confirmations and input prompts.
The request ID is auto-generated with the `s2c-` prefix.

## Examples

    {:ok, result} = Opal.RPC.Stdio.request_client("client/confirm", %{
      session_id: "abc123",
      title: "Execute shell command?",
      message: "rm -rf node_modules/",
      actions: ["allow", "deny", "allow_session"]
    })

# `start_link`

```elixir
@spec start_link(keyword()) :: GenServer.on_start()
```

Starts the stdio transport GenServer.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
