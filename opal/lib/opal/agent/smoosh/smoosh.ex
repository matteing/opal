defmodule Opal.Agent.Smoosh do
  @moduledoc """
  Tool output compression for context window efficiency.

  Smoosh intercepts tool results after execution and either passes them
  through, compresses them via a sub-agent, or indexes them into the
  session knowledge base — depending on the tool's declared policy and
  the output size.

  ## Integration

  Called from `Opal.Agent.ToolRunner.collect_result/4` via `maybe_compress/3`.
  When disabled (the default), this is a no-op that returns the result unchanged.

  ## Policy

  Each tool can declare a compression policy via the optional `smoosh/0`
  callback on `Opal.Tool`:

    * `:auto` — compress if output exceeds the configured threshold (default)
    * `:skip` — never compress
    * `:always` — always compress regardless of size

  Tools that don't implement the callback default to `:auto`.
  """

  require Logger
  alias Opal.Agent.{Emitter, State}

  @type policy :: :pass_through | :compress | :index_only

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Post-processes a tool result, compressing if policy dictates.

  This is the single entry point called by ToolRunner. Returns the
  (possibly modified) result and updated state.

  When smoosh is disabled, returns the result unchanged (no-op).
  """
  @spec maybe_compress(module() | nil, Opal.Agent.ToolRunner.result(), State.t()) ::
          {Opal.Agent.ToolRunner.result(), State.t()}
  def maybe_compress(nil, result, state), do: {result, state}

  def maybe_compress(
        _tool_mod,
        result,
        %State{config: %{features: %{smoosh: %{enabled: false}}}} = state
      ) do
    {result, state}
  end

  def maybe_compress(tool_mod, {:ok, raw_output} = result, %State{} = state) do
    case classify(tool_mod, raw_output, state) do
      :pass_through ->
        {result, state}

      :compress ->
        case Opal.Agent.Smoosh.Compressor.compress(raw_output, tool_mod.name(), state) do
          {:ok, compressed} ->
            Emitter.broadcast(state, smoosh_event(tool_mod.name(), raw_output, compressed))
            {{:ok, compressed}, state}

          {:error, reason} ->
            Logger.warning("Smoosh compression failed for #{tool_mod.name()}: #{reason}")
            {result, state}
        end

      :index_only ->
        # Phase 2: knowledge base indexing will go here
        # For now, fall back to compression
        case Opal.Agent.Smoosh.Compressor.compress(raw_output, tool_mod.name(), state) do
          {:ok, compressed} ->
            Emitter.broadcast(state, smoosh_event(tool_mod.name(), raw_output, compressed))
            {{:ok, compressed}, state}

          {:error, _reason} ->
            {result, state}
        end
    end
  end

  def maybe_compress(_tool_mod, result, state), do: {result, state}

  @doc """
  Classifies a tool result into a compression policy.

  Rules (evaluated in order):

  1. Tool declares `smoosh: :skip` → `:pass_through`
  2. Tool declares `smoosh: :always` → `:compress`
  3. Output < threshold → `:pass_through`
  4. Output > hard limit → `:index_only`
  5. Otherwise → `:compress`
  """
  @spec classify(module(), String.t(), State.t()) :: policy()
  def classify(tool_mod, output, %State{config: %{features: %{smoosh: smoosh_config}}}) do
    case tool_policy(tool_mod) do
      :skip -> :pass_through
      :always -> :compress
      :auto -> classify_by_size(output, smoosh_config)
    end
  end

  # ── Private ─────────────────────────────────────────────────────────

  @spec tool_policy(module()) :: :auto | :skip | :always
  defp tool_policy(tool_mod) do
    if function_exported?(tool_mod, :smoosh, 0) do
      tool_mod.smoosh()
    else
      :auto
    end
  end

  @spec classify_by_size(String.t(), map()) :: policy()
  defp classify_by_size(output, %{threshold_bytes: threshold, hard_limit_bytes: hard_limit}) do
    size = byte_size(output)

    cond do
      size < threshold -> :pass_through
      size > hard_limit -> :index_only
      true -> :compress
    end
  end

  defp smoosh_event(tool_name, raw, compressed) do
    {:smoosh_compress,
     %{
       tool: tool_name,
       raw_bytes: byte_size(raw),
       compressed_bytes: byte_size(compressed)
     }}
  end
end
