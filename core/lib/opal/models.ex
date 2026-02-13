defmodule Opal.Models do
  @moduledoc """
  Model discovery backed by LLMDB.

  Provides auto-discovery of available models from LLMDB's database, which
  includes metadata like context windows, aliases, and capabilities. This
  replaces hardcoded model lists and context window pattern matching.

  ## Copilot Naming Quirks

  The Copilot API uses its own model ID scheme that differs from upstream
  providers. Notably, Copilot uses dots where upstream uses dashes:

  | Copilot ID | Upstream ID |
  |------------|-------------|
  | `claude-opus-4.6` | `claude-opus-4-6` |
  | `claude-sonnet-4.5` | `claude-sonnet-4-5-20250929` |
  | `claude-haiku-4.5` | `claude-haiku-4-5-20251001` |

  LLMDB's `github_copilot` provider maps these correctly, so callers don't
  need to worry about the translation.
  """

  @default_context_window 128_000

  @doc """
  Lists models available via GitHub Copilot.

  Returns a list of `%{id, name, supports_thinking}` maps sourced from LLMDB's
  `github_copilot` provider. Falls back to an empty list if LLMDB is unavailable.
  """
  @spec list_copilot() :: [%{id: String.t(), name: String.t(), supports_thinking: boolean()}]
  def list_copilot do
    LLMDB.models()
    |> Enum.filter(&(&1.provider == :github_copilot and not &1.deprecated and not &1.retired))
    |> Enum.map(&to_model_info/1)
    |> Enum.sort_by(& &1.id)
  rescue
    _ -> []
  end

  @doc """
  Lists models available for a direct provider (e.g., `:anthropic`, `:openai`).

  Only returns models with chat capability. Returns a list of `%{id, name, supports_thinking}` maps.
  """
  @spec list_provider(atom()) :: [
          %{id: String.t(), name: String.t(), supports_thinking: boolean()}
        ]
  def list_provider(provider) when is_atom(provider) do
    LLMDB.models()
    |> Enum.filter(fn m ->
      m.provider == provider and
        not m.deprecated and
        not m.retired and
        get_in(m.capabilities, [:chat]) == true
    end)
    |> Enum.map(&to_model_info/1)
    |> Enum.sort_by(& &1.id)
  rescue
    _ -> []
  end

  @doc """
  Returns the context window size for a model.

  Looks up the model in LLMDB by provider and ID. For Copilot models,
  queries the `github_copilot` provider. Falls back to #{@default_context_window}
  if the model is not found.

  ## Examples

      iex> Opal.Models.context_window(%Opal.Model{provider: :copilot, id: "claude-opus-4.6"})
      128_000

      iex> Opal.Models.context_window(%Opal.Model{provider: :anthropic, id: "claude-sonnet-4-5"})
      200_000
  """
  @spec context_window(Opal.Model.t()) :: pos_integer()
  def context_window(%{provider: provider, id: id}) do
    llmdb_provider = if provider == :copilot, do: :github_copilot, else: provider

    case LLMDB.model("#{llmdb_provider}:#{id}") do
      {:ok, %{limits: %{context: ctx}}} when is_integer(ctx) and ctx > 0 -> ctx
      _ -> @default_context_window
    end
  rescue
    _ -> @default_context_window
  end

  @doc """
  Resolves a model spec to its LLMDB metadata.

  Returns `{:ok, model}` with full LLMDB model data, or `{:error, :not_found}`.
  Useful for checking aliases, capabilities, and other metadata.
  """
  @spec resolve(Opal.Model.t()) :: {:ok, LLMDB.Model.t()} | {:error, :not_found}
  def resolve(%{provider: provider, id: id}) do
    llmdb_provider = if provider == :copilot, do: :github_copilot, else: provider

    case LLMDB.model("#{llmdb_provider}:#{id}") do
      {:ok, _model} = result -> result
      _ -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  # Supported thinking levels per model family.
  # OpenAI: low/medium/high per their reasoning docs.
  # Anthropic: low/medium/high mapped to budget_tokens by ReqLLM.
  # Anthropic Opus 4.6+: low/medium/high/max via adaptive thinking.
  @standard_thinking_levels ["low", "medium", "high"]
  @max_thinking_levels ["low", "medium", "high", "max"]

  # Opus 4.6+ supports adaptive thinking with "max" effort level
  defp supports_max_thinking?(id) do
    String.contains?(id, "opus-4.6") or String.contains?(id, "opus-4-6")
  end

  defp to_model_info(m) do
    supports_thinking = get_in(m.capabilities, [:reasoning, :enabled]) == true

    thinking_levels =
      cond do
        not supports_thinking -> []
        supports_max_thinking?(m.id) -> @max_thinking_levels
        true -> @standard_thinking_levels
      end

    %{
      id: m.id,
      name: m.name,
      supports_thinking: supports_thinking,
      thinking_levels: thinking_levels
    }
  end
end
