defmodule Opal.Agent.Smoosh.Compressor do
  @moduledoc """
  Compresses tool output using a lightweight sub-agent.

  Spawns a child agent with no tools (pure summarization) and a focused
  system prompt. The raw tool output is sent as the prompt and the
  sub-agent's response is the compressed summary.

  The sub-agent ensures the raw output never enters the parent agent's
  context window — only the distilled summary does.
  """

  require Logger
  alias Opal.Agent.{Spawner, State}

  @compressor_prompt """
  You are a context compression agent. Your job is to distill tool output into
  the minimum information needed for a coding task.

  Rules:
  - Preserve ALL: error messages, stack traces, file paths, line numbers,
    code snippets, version numbers, command outputs that indicate success/failure.
  - Summarize: repetitive data, verbose logs, large API responses, HTML content.
  - Format: use structured output (bullet points, key-value pairs). No prose.
  - Never fabricate data. If you're unsure whether something is important, keep it.
  - Be as concise as possible while preserving all actionable information.
  """

  @doc """
  Compresses a raw tool output string using a sub-agent summarizer.

  Returns `{:ok, compressed}` on success, `{:error, reason}` on failure.
  On failure the caller should fall back to using the raw output.
  """
  @spec compress(String.t(), String.t(), State.t()) :: {:ok, String.t()} | {:error, term()}
  def compress(raw_output, tool_name, %State{} = parent_state) do
    overrides = %{
      system_prompt: @compressor_prompt,
      tools: [],
      model: pick_model(parent_state)
    }

    with {:ok, sub} <- Spawner.spawn_from_state(parent_state, overrides),
         {:ok, compressed} <- Spawner.run(sub, prompt(tool_name, raw_output), 30_000) do
      Spawner.stop(sub)

      if compressed == "" do
        Logger.warning("Smoosh compressor returned empty for #{tool_name}")
        {:error, :empty_compression}
      else
        {:ok, compressed}
      end
    else
      {:error, reason} = err ->
        Logger.warning("Smoosh compressor failed for #{tool_name}: #{inspect(reason)}")
        err
    end
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp prompt(tool_name, raw_output) do
    """
    Compress the following `#{tool_name}` output. Return only the compressed summary.

    <tool-output>
    #{raw_output}
    </tool-output>
    """
  end

  # Prefer the cheapest model available. If a compressor_model is configured,
  # use that. Otherwise inherit the parent's model — in the future we can
  # add haiku-class auto-selection here.
  defp pick_model(%State{config: %{features: %{smoosh: %{compressor_model: nil}}}} = state) do
    state.model
  end

  defp pick_model(%State{config: %{features: %{smoosh: %{compressor_model: model}}}}) do
    Opal.Provider.Model.coerce(model)
  end
end
