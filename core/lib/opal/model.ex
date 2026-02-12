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

    * `provider` — the provider atom (e.g. `:copilot`)
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
end
