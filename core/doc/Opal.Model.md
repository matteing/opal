# `Opal.Model`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/model.ex#L1)

A struct representing model configuration for an agent session.

Encapsulates the provider, model identifier, and optional thinking level
used when making requests to a language model API.

## Examples

    iex> Opal.Model.new(:copilot, "claude-sonnet-4-5")
    %Opal.Model{provider: :copilot, id: "claude-sonnet-4-5", thinking_level: :off}

    iex> Opal.Model.new(:copilot, "claude-sonnet-4-5", thinking_level: :high)
    %Opal.Model{provider: :copilot, id: "claude-sonnet-4-5", thinking_level: :high}

# `t`

```elixir
@type t() :: %Opal.Model{
  id: String.t(),
  provider: atom(),
  thinking_level: thinking_level()
}
```

# `thinking_level`

```elixir
@type thinking_level() :: :off | :low | :medium | :high
```

# `new`

```elixir
@spec new(atom(), String.t(), keyword()) :: t()
```

Creates a new model configuration.

## Parameters

  * `provider` — the provider atom (e.g. `:copilot`)
  * `id` — the model identifier string (e.g. `"claude-sonnet-4-5"`)
  * `opts` — optional keyword list:
    * `:thinking_level` — one of `:off`, `:low`, `:medium`, `:high` (default: `:off`)

## Examples

    iex> Opal.Model.new(:copilot, "claude-sonnet-4-5")
    %Opal.Model{provider: :copilot, id: "claude-sonnet-4-5", thinking_level: :off}

---

*Consult [api-reference.md](api-reference.md) for complete listing*
