# `Opal.Config.Copilot`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/config.ex#L1)

Copilot-specific configuration: OAuth client ID and GitHub domain.

## Fields

  * `:client_id` — OAuth App client ID for the Copilot device-code flow.
    Default: `"Iv1.b507a08c87ecfe98"` (the VS Code Copilot Chat extension's ID).

  * `:domain` — GitHub domain for authentication endpoints.
    Default: `"github.com"`. Change for GitHub Enterprise Server instances.

# `t`

```elixir
@type t() :: %Opal.Config.Copilot{client_id: String.t(), domain: String.t()}
```

# `new`

```elixir
@spec new(keyword() | map()) :: t()
```

Builds from a keyword list or map.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
