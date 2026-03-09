defmodule Opal.Provider.Registry do
  @moduledoc """
  Hardcoded model registry for Snow Leopard edition.

  Replaces LLMDB with a static map of Copilot models and their metadata.
  """

  @default_context_window 128_000

  @models %{
    "claude-sonnet-4.5" => %{context: 200_000, thinking: true, name: "Claude Sonnet 4.5"},
    "claude-sonnet-4" => %{context: 200_000, thinking: true, name: "Claude Sonnet 4"},
    "claude-opus-4.6" => %{context: 200_000, thinking: true, name: "Claude Opus 4.6"},
    "claude-haiku-4.5" => %{context: 200_000, thinking: true, name: "Claude Haiku 4.5"},
    "gpt-4o" => %{context: 128_000, thinking: false, name: "GPT-4o"},
    "gpt-4.1" => %{context: 128_000, thinking: false, name: "GPT-4.1"},
    "gpt-5" => %{context: 200_000, thinking: true, name: "GPT-5"},
    "gpt-5.1" => %{context: 200_000, thinking: true, name: "GPT-5.1"},
    "gpt-5.2" => %{context: 200_000, thinking: true, name: "GPT-5.2"},
    "o3" => %{context: 200_000, thinking: true, name: "o3"},
    "o4-mini" => %{context: 200_000, thinking: true, name: "o4-mini"},
    "gemini-2.5-pro" => %{context: 1_000_000, thinking: true, name: "Gemini 2.5 Pro"}
  }

  @standard_thinking_levels ["low", "medium", "high"]
  @max_thinking_levels ["low", "medium", "high", "max"]

  def list_copilot do
    @models
    |> Enum.map(fn {id, m} ->
      %{
        id: id,
        name: m.name,
        supports_thinking: m.thinking,
        thinking_levels: thinking_levels(id, m.thinking)
      }
    end)
    |> Enum.sort_by(& &1.id)
  end

  def list_provider(_provider), do: list_copilot()

  def context_window(%{id: id}) do
    case Map.get(@models, id) do
      %{context: ctx} -> ctx
      nil -> @default_context_window
    end
  end

  def resolve(%{id: id}) do
    case Map.get(@models, id) do
      nil -> {:error, :not_found}
      m -> {:ok, m}
    end
  end

  defp thinking_levels(id, true) do
    if String.contains?(id, "opus-4.6") or String.contains?(id, "opus-4-6"),
      do: @max_thinking_levels,
      else: @standard_thinking_levels
  end

  defp thinking_levels(_id, false), do: []
end
