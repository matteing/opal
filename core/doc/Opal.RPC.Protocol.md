# `Opal.RPC.Protocol`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/rpc/protocol.ex#L1)

Declarative protocol specification for the Opal JSON-RPC 2.0 API.

This module is the **single source of truth** for the Opal RPC protocol.
Every method, notification, event type, and server→client request is
defined here as structured data. The handler dispatches only methods
listed here; the stdio transport serializes only event types listed here.

## Design Goals

  * **Machine-readable** — the definitions are plain Elixir data structures
    that a code generator can traverse to produce TypeScript types, JSON
    Schema, or documentation.
  * **Self-documenting** — each definition carries its own description,
    required/optional params, and result shape.
  * **Single source of truth** — `Opal.RPC.Handler` and `Opal.RPC.Stdio`
    reference these definitions rather than embedding protocol knowledge.

## Usage

    # List all method names
    Opal.RPC.Protocol.method_names()

    # Get a specific method definition
    Opal.RPC.Protocol.method("agent/prompt")

    # List all event types
    Opal.RPC.Protocol.event_types()

    # List server→client request methods
    Opal.RPC.Protocol.server_request_names()

    # Full spec for export/codegen
    Opal.RPC.Protocol.spec()

# `event_type_def`

```elixir
@type event_type_def() :: %{
  type: String.t(),
  description: String.t(),
  fields: [result_field()]
}
```

A server→client notification event type.

# `method_def`

```elixir
@type method_def() :: %{
  method: String.t(),
  direction: :client_to_server,
  description: String.t(),
  params: [param()],
  result: [result_field()]
}
```

A client→server method definition.

# `param`

```elixir
@type param() :: %{
  name: String.t(),
  type: String.t(),
  required: boolean(),
  description: String.t()
}
```

A parameter field definition.

# `result_field`

```elixir
@type result_field() :: %{name: String.t(), type: String.t(), description: String.t()}
```

A result field definition.

# `server_request_def`

```elixir
@type server_request_def() :: %{
  method: String.t(),
  direction: :server_to_client,
  description: String.t(),
  params: [param()],
  result: [result_field()]
}
```

A server→client request definition.

# `event_type`

```elixir
@spec event_type(String.t()) :: event_type_def() | nil
```

Returns the definition for a specific event type, or nil.

# `event_type_names`

```elixir
@spec event_type_names() :: [String.t()]
```

Returns all event type name strings.

# `event_types`

```elixir
@spec event_types() :: [event_type_def()]
```

Returns all event type definitions.

# `known_event_type?`

```elixir
@spec known_event_type?(String.t()) :: boolean()
```

Returns true if the given event type is a known event.

# `known_method?`

```elixir
@spec known_method?(String.t()) :: boolean()
```

Returns true if the given method name is a known client→server method.

# `method`

```elixir
@spec method(String.t()) :: method_def() | nil
```

Returns the definition for a specific method, or nil.

# `method_names`

```elixir
@spec method_names() :: [String.t()]
```

Returns all client→server method name strings.

# `methods`

```elixir
@spec methods() :: [method_def()]
```

Returns all client→server method definitions.

# `notification_method`

```elixir
@spec notification_method() :: String.t()
```

The JSON-RPC method name used for all streaming event notifications.

# `required_params`

```elixir
@spec required_params(String.t()) :: [String.t()]
```

Returns the required param names for a given method.

# `server_request`

```elixir
@spec server_request(String.t()) :: server_request_def() | nil
```

Returns the definition for a specific server request, or nil.

# `server_request_names`

```elixir
@spec server_request_names() :: [String.t()]
```

Returns all server→client request method name strings.

# `server_requests`

```elixir
@spec server_requests() :: [server_request_def()]
```

Returns all server→client request definitions.

# `spec`

```elixir
@spec spec() :: map()
```

Returns the complete protocol specification as a single map.

Useful for serialization, export, or code generation.

## Structure

    %{
      version: "0.1.0",
      transport: "stdio",
      framing: "newline-delimited JSON",
      methods: [...],
      server_requests: [...],
      event_types: [...],
      notification_method: "agent/event"
    }

---

*Consult [api-reference.md](api-reference.md) for complete listing*
