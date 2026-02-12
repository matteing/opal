defmodule Opal.Model do
  @moduledoc """
  A struct representing model configuration for an agent session.

  Encapsulates the provider, model identifier, and optional thinking level
  used when making requests to a language model API.

  ## Examples

      iex> Opal.Model.new(:copilot, "claude-sonnet-4-5")
      %Opal.Model{provider: :copilot, id: "claude-sonnet-4-5", thinking_level: :off}

      iex> Opal.Model.new(:copilot, "claude-sonnet-4-5", thinking_level: :high)
      %Opal.Model{provider: :copilot, id: "claude-sonnet-4-5", thinking_level: :high}
  """

  @type thinking_level :: :off | :low | :medium | :high

  @type t :: %__MODULE__{
          provider: atom(),
          id: String.t(),
          thinking_level: thinking_level()
        }

  @enforce_keys [:provider, :id]
  defstruct [:provider, :id, thinking_level: :off]

  @valid_thinking_levels [:off, :low, :medium, :high]

  @doc """
  Creates a new model configuration.

  ## Parameters

    * `provider` — the provider atom (e.g. `:copilot`, `:anthropic`, `:openai`)
    * `id` — the model identifier string (e.g. `"claude-sonnet-4-5"`)
    * `opts` — optional keyword list:
      * `:thinking_level` — one of `:off`, `:low`, `:medium`, `:high` (default: `:off`)

  ## Examples

      iex> Opal.Model.new(:copilot, "claude-sonnet-4-5")
      %Opal.Model{provider: :copilot, id: "claude-sonnet-4-5", thinking_level: :off}
  """
  @spec new(atom(), String.t(), keyword()) :: t()
  def new(provider, id, opts \\ [])
      when is_atom(provider) and is_binary(id) do
    thinking_level = Keyword.get(opts, :thinking_level, :off)

    unless thinking_level in @valid_thinking_levels do
      raise ArgumentError,
            "invalid thinking_level: #{inspect(thinking_level)}, " <>
              "expected one of #{inspect(@valid_thinking_levels)}"
    end

    %__MODULE__{provider: provider, id: id, thinking_level: thinking_level}
  end

  @doc """
  Parses a model specification string into an `Opal.Model`.

  Accepts `"provider:model_id"` format (e.g. `"anthropic:claude-sonnet-4-5"`).
  Also accepts a bare model ID, which defaults to the `:copilot` provider.

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
        [provider_str, model_id] -> {String.to_atom(provider_str), model_id}
        [model_id] -> {:copilot, model_id}
      end

    new(provider, id, opts)
  end

  @doc """
  Coerces a model specification into an `Opal.Model` struct.

  This is the single normalization entry point for model specs. It accepts:

    * An `%Opal.Model{}` struct (returned as-is)
    * A `"provider:model_id"` string (e.g. `"anthropic:claude-sonnet-4-5"`)
    * A bare model ID string (defaults to `:copilot` provider)
    * A `{provider, model_id}` tuple where provider is an atom or string

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

  def coerce({provider, id}, opts) when is_binary(id) do
    provider_atom = if is_atom(provider), do: provider, else: String.to_existing_atom(provider)
    new(provider_atom, id, opts)
  end

  @doc """
  Returns the provider module for the given model.

  Maps `:copilot` to `Opal.Provider.Copilot` and all other providers
  to `Opal.Provider.LLM`.

  ## Examples

      iex> model = Opal.Model.new(:copilot, "gpt-5")
      iex> Opal.Model.provider_module(model)
      Opal.Provider.Copilot

      iex> model = Opal.Model.new(:anthropic, "claude-sonnet-4-5")
      iex> Opal.Model.provider_module(model)
      Opal.Provider.LLM
  """
  @spec provider_module(t()) :: module()
  def provider_module(%__MODULE__{provider: :copilot}), do: Opal.Provider.Copilot
  def provider_module(%__MODULE__{}), do: Opal.Provider.LLM

  @doc """
  Returns the ReqLLM model specification string for this model.

  Only applicable for non-Copilot providers that use ReqLLM.

  ## Examples

      iex> model = Opal.Model.new(:anthropic, "claude-sonnet-4-5")
      iex> Opal.Model.to_req_llm_spec(model)
      "anthropic:claude-sonnet-4-5"
  """
  @spec to_req_llm_spec(t()) :: String.t()
  def to_req_llm_spec(%__MODULE__{provider: provider, id: id}) do
    "#{provider}:#{id}"
  end
end
