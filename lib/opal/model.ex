defmodule Opal.Model do
  @moduledoc """
  Model configuration for an agent session.

  Ties together a provider (`:copilot`, `:anthropic`, `:openai`, …), a model
  ID string, and an optional thinking level.

  ## Examples

      Opal.Model.new(:copilot, "claude-sonnet-4-5")
      Opal.Model.new(:anthropic, "claude-sonnet-4-5", thinking_level: :high)
      Opal.Model.parse("anthropic:claude-sonnet-4-5")
      Opal.Model.coerce({:openai, "gpt-4o"})
  """

  @type thinking_level :: :off | :low | :medium | :high | :max

  @type t :: %__MODULE__{
          provider: atom(),
          id: String.t(),
          thinking_level: thinking_level()
        }

  @enforce_keys [:provider, :id]
  defstruct [:provider, :id, thinking_level: :off]

  @thinking_levels ~w(off low medium high max)a

  # -------------------------------------------------------------------
  # Constructors
  # -------------------------------------------------------------------

  @doc """
  Creates a model from an explicit provider atom and model ID.

  ## Options

    * `:thinking_level` — one of #{inspect(~w(off low medium high max)a)} (default `:off`)

  ## Examples

      iex> Opal.Model.new(:copilot, "claude-sonnet-4-5")
      %Opal.Model{provider: :copilot, id: "claude-sonnet-4-5", thinking_level: :off}
  """
  @spec new(atom(), String.t(), keyword()) :: t()
  def new(provider, id, opts \\ [])
      when is_atom(provider) and is_binary(id) do
    thinking = Keyword.get(opts, :thinking_level, :off)

    thinking in @thinking_levels ||
      raise ArgumentError,
            "invalid thinking_level: #{inspect(thinking)}, expected one of #{inspect(@thinking_levels)}"

    %__MODULE__{provider: provider, id: id, thinking_level: thinking}
  end

  @doc """
  Parses a `"provider:model_id"` string. Bare model IDs default to `:copilot`.

  ## Examples

      iex> Opal.Model.parse("anthropic:claude-sonnet-4-5")
      %Opal.Model{provider: :anthropic, id: "claude-sonnet-4-5", thinking_level: :off}

      iex> Opal.Model.parse("claude-sonnet-4-5")
      %Opal.Model{provider: :copilot, id: "claude-sonnet-4-5", thinking_level: :off}
  """
  @spec parse(String.t(), keyword()) :: t()
  def parse(spec, opts \\ []) when is_binary(spec) do
    {provider, id} =
      case String.split(spec, ":", parts: 2) do
        [provider_str, model_id] -> {to_provider_atom!(provider_str), model_id}
        [model_id] -> {:copilot, model_id}
      end

    new(provider, id, opts)
  end

  # -------------------------------------------------------------------
  # Coercion
  # -------------------------------------------------------------------

  @doc """
  Normalizes any model spec into an `%Opal.Model{}`.

  Accepted inputs:

    * `%Opal.Model{}` — returned as-is
    * `"provider:model_id"` or bare `"model_id"` — parsed via `parse/2`
    * `{provider, model_id}` tuple — provider may be atom or string

  ## Examples

      iex> Opal.Model.coerce("anthropic:claude-sonnet-4-5")
      %Opal.Model{provider: :anthropic, id: "claude-sonnet-4-5", thinking_level: :off}

      iex> Opal.Model.coerce({:openai, "gpt-4o"})
      %Opal.Model{provider: :openai, id: "gpt-4o", thinking_level: :off}

      iex> model = Opal.Model.new(:copilot, "gpt-5")
      iex> Opal.Model.coerce(model)
      %Opal.Model{provider: :copilot, id: "gpt-5", thinking_level: :off}
  """
  @spec coerce(t() | String.t() | {atom() | String.t(), String.t()}, keyword()) :: t()
  def coerce(spec, opts \\ [])
  def coerce(%__MODULE__{} = model, _opts), do: model
  def coerce(spec, opts) when is_binary(spec), do: parse(spec, opts)

  def coerce({provider, id}, opts) when is_atom(provider) and is_binary(id),
    do: new(provider, id, opts)

  def coerce({provider, id}, opts) when is_binary(provider) and is_binary(id),
    do: new(to_provider_atom!(provider), id, opts)

  # -------------------------------------------------------------------
  # Provider helpers
  # -------------------------------------------------------------------

  @doc """
  Returns the provider module for a model.

  `:copilot` maps to `Opal.Provider.Copilot`; everything else uses `Opal.Provider.LLM`.

  ## Examples

      iex> Opal.Model.new(:copilot, "gpt-5") |> Opal.Model.provider_module()
      Opal.Provider.Copilot

      iex> Opal.Model.new(:anthropic, "claude-sonnet-4-5") |> Opal.Model.provider_module()
      Opal.Provider.LLM
  """
  @spec provider_module(t()) :: module()
  def provider_module(%__MODULE__{provider: :copilot}), do: Opal.Provider.Copilot
  def provider_module(%__MODULE__{}), do: Opal.Provider.LLM

  @doc """
  Formats as a `"provider:model_id"` string for ReqLLM.

  ## Examples

      iex> Opal.Model.new(:anthropic, "claude-sonnet-4-5") |> Opal.Model.to_req_llm_spec()
      "anthropic:claude-sonnet-4-5"
  """
  @spec to_req_llm_spec(t()) :: String.t()
  def to_req_llm_spec(%__MODULE__{provider: provider, id: id}), do: "#{provider}:#{id}"

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------

  defp to_provider_atom!(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> raise ArgumentError, "unknown provider: #{inspect(name)}"
  end
end
