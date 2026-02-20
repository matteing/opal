defmodule Opal.Provider.Model do
  @moduledoc """
  Model configuration for an agent session.

  Ties together the provider (always `:copilot`), a model ID string,
  and an optional thinking level.

  ## Examples

      iex> Opal.Provider.Model.new("claude-sonnet-4-5")
      %Opal.Provider.Model{provider: :copilot, id: "claude-sonnet-4-5", thinking_level: :off}

      iex> Opal.Provider.Model.parse("claude-sonnet-4-5")
      %Opal.Provider.Model{provider: :copilot, id: "claude-sonnet-4-5", thinking_level: :off}
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

  # ── Constructors ───────────────────────────────────────────────────

  @doc """
  Creates a model with the given ID. Provider is always `:copilot`.

  ## Options

    * `:thinking_level` — one of #{inspect(@thinking_levels)} (default `:off`)
  """
  @spec new(String.t(), keyword()) :: t()
  def new(id) when is_binary(id), do: new(id, [])

  def new(id, opts) when is_binary(id) and is_list(opts) do
    thinking = Keyword.get(opts, :thinking_level, :off)

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
      %Opal.Provider.Model{provider: :copilot, id: "claude-sonnet-4-5", thinking_level: :off}
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
end
