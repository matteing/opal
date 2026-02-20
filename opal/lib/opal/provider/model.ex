defmodule Opal.Provider.Model do
  @moduledoc """
  Model configuration for an agent session.

  Ties together the provider (always `:copilot`), a model ID string,
  and an optional thinking level.

  Thinking-capable models (Claude, GPT-5, o3, o4) default to `:high`.
  Non-thinking models default to `:off`.

  ## Examples

      iex> Opal.Provider.Model.new("claude-sonnet-4-5")
      %Opal.Provider.Model{provider: :copilot, id: "claude-sonnet-4-5", thinking_level: :high}

      iex> Opal.Provider.Model.new("gpt-4o")
      %Opal.Provider.Model{provider: :copilot, id: "gpt-4o", thinking_level: :off}
  """

  @type thinking_level :: :off | :low | :medium | :high | :max

  @type t :: %__MODULE__{
          provider: :copilot,
          id: String.t(),
          thinking_level: thinking_level()
        }

  @enforce_keys [:id]
  defstruct [:id, provider: :copilot, thinking_level: :off]

  @thinking_levels ~w(off low medium high max)a

  @thinking_prefixes ~w(gpt-5 claude-sonnet-4 claude-opus-4 claude-haiku-4.5 o3 o4)

  # ── Constructors ───────────────────────────────────────────────────

  @doc """
  Creates a model with the given ID. Provider is always `:copilot`.

  Thinking-capable models default to `:high` when no level is specified.

  ## Options

    * `:thinking_level` — one of #{inspect(@thinking_levels)}
      (defaults to `:high` for thinking-capable models, `:off` otherwise)
  """
  @spec new(String.t(), keyword()) :: t()
  def new(id) when is_binary(id), do: new(id, [])

  def new(id, opts) when is_binary(id) and is_list(opts) do
    thinking =
      case Keyword.fetch(opts, :thinking_level) do
        {:ok, level} -> level
        :error -> default_thinking(id)
      end

    thinking in @thinking_levels ||
      raise ArgumentError,
            "invalid thinking_level: #{inspect(thinking)}, expected one of #{inspect(@thinking_levels)}"

    %__MODULE__{id: id, thinking_level: thinking}
  end

  # Backwards-compat: accept and ignore provider atom
  @doc false
  def new(provider, id) when is_atom(provider) and is_binary(id), do: new(id, [])

  @doc false
  def new(provider, id, opts)
      when is_atom(provider) and is_binary(id) and is_list(opts),
      do: new(id, opts)

  @doc """
  Parses a model ID string. Always produces a `:copilot` model.

  ## Examples

      iex> Opal.Provider.Model.parse("claude-sonnet-4-5")
      %Opal.Provider.Model{provider: :copilot, id: "claude-sonnet-4-5", thinking_level: :high}
  """
  @spec parse(String.t(), keyword()) :: t()
  def parse(spec) when is_binary(spec), do: new(spec, [])
  def parse(spec, opts) when is_binary(spec), do: new(spec, opts)

  # ── Coercion ───────────────────────────────────────────────────────

  @doc """
  Normalizes any model spec into a `%Model{}`.

  Accepted inputs:

    * `%Model{}` — returned as-is
    * `"model_id"` string — parsed via `parse/2`
    * `{:copilot, model_id}` tuple
  """
  @spec coerce(t() | String.t() | {atom(), String.t()}, keyword()) :: t()
  def coerce(spec, opts \\ [])
  def coerce(%__MODULE__{} = model, _opts), do: model
  def coerce(spec, opts) when is_binary(spec), do: new(spec, opts)

  def coerce({_provider, id}, opts) when is_binary(id),
    do: new(id, opts)

  def coerce({_provider, id, thinking}, opts)
      when is_binary(id) and is_atom(thinking),
      do: new(id, Keyword.put(opts, :thinking_level, thinking))

  # ── Thinking Capability ──────────────────────────────────────────

  @doc """
  Returns `true` if the model ID is known to support extended thinking.

  Detected by prefix match: #{inspect(@thinking_prefixes)}.
  """
  @spec thinking_capable?(String.t()) :: boolean()
  def thinking_capable?(id) when is_binary(id) do
    Enum.any?(@thinking_prefixes, &String.starts_with?(id, &1))
  end

  @doc """
  Returns the default thinking level for a model ID.

  Thinking-capable models default to `:high`; others to `:off`.
  """
  @spec default_thinking(String.t()) :: thinking_level()
  def default_thinking(id) when is_binary(id) do
    if thinking_capable?(id), do: :high, else: :off
  end
end
