# `Opal.Message`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/message.ex#L1)

A struct representing messages in an agent conversation.

Messages flow through the agent loop and carry content between the user,
assistant, and tool executions. Each message has a role that determines
its semantics:

  * `:user` — a user-originated message with text content
  * `:assistant` — an assistant response with text and optional tool calls
  * `:tool_call` — a tool invocation specifying name, call ID, and arguments
  * `:tool_result` — the result of a tool execution, keyed by call ID

Every message is assigned a unique ID at construction time.

# `role`

```elixir
@type role() :: :user | :assistant | :tool_call | :tool_result
```

# `t`

```elixir
@type t() :: %Opal.Message{
  call_id: String.t() | nil,
  content: String.t() | nil,
  id: String.t(),
  is_error: boolean(),
  name: String.t() | nil,
  parent_id: String.t() | nil,
  role: role(),
  tool_calls: [tool_call()] | nil
}
```

# `tool_call`

```elixir
@type tool_call() :: %{call_id: String.t(), name: String.t(), arguments: map()}
```

# `assistant`

```elixir
@spec assistant(String.t() | nil, [tool_call()]) :: t()
```

Creates an assistant message with text content and optional tool calls.

## Examples

    iex> msg = Opal.Message.assistant("Sure, let me check.", [])
    iex> msg.role
    :assistant

# `tool_call`

```elixir
@spec tool_call(String.t(), String.t(), map()) :: t()
```

Creates a tool call message representing a tool invocation.

## Parameters

  * `call_id` — unique identifier linking this call to its result
  * `name` — the tool name to invoke
  * `arguments` — a map of arguments to pass to the tool

# `tool_result`

```elixir
@spec tool_result(String.t(), String.t(), boolean()) :: t()
```

Creates a tool result message with the output of a tool execution.

## Parameters

  * `call_id` — the call ID this result corresponds to
  * `output` — the string output produced by the tool
  * `is_error` — whether the tool execution resulted in an error (default: `false`)

# `user`

```elixir
@spec user(String.t()) :: t()
```

Creates a user message with the given text content.

## Examples

    iex> msg = Opal.Message.user("Hello")
    iex> msg.role
    :user

---

*Consult [api-reference.md](api-reference.md) for complete listing*
