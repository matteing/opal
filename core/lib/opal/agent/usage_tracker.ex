defmodule Opal.Agent.UsageTracker do
  @moduledoc """
  Token usage tracking and estimation for the Agent loop.

  Manages token counting, overflow detection, and hybrid estimation that
  combines actual usage reports from providers with heuristic estimates
  for messages added since the last report.
  """

  require Logger
  alias Opal.Agent.State

  # Threshold ratio for auto-compaction when estimated tokens exceed this percentage of context window
  @auto_compact_threshold 0.80

  @doc """
  Compacts the conversation if estimated context usage exceeds the threshold.

  Uses hybrid token estimation: combines the last actual usage
  report with heuristic estimates for messages added since. This catches
  growth *between* turns that the lagging `last_prompt_tokens` would miss.
  """
  @spec maybe_auto_compact(State.t()) :: State.t()
  def maybe_auto_compact(%State{session: session, model: model} = state)
      when is_pid(session) do
    context_window = model_context_window(model)

    # Build hybrid estimate: actual usage base + heuristic for trailing messages
    estimated_tokens = estimate_current_tokens(state, context_window)
    ratio = estimated_tokens / context_window

    if ratio >= @auto_compact_threshold do
      Logger.info(
        "Auto-compacting: ~#{estimated_tokens} estimated tokens / #{context_window} context (#{Float.round(ratio * 100, 1)}%)"
      )

      broadcast(state, {:compaction_start, length(state.messages)})

      case Opal.Session.Compaction.compact(session,
             provider: state.provider,
             model: state.model,
             keep_recent_tokens: div(context_window, 4)
           ) do
        :ok ->
          new_path = Opal.Session.get_path(session)
          broadcast(state, {:compaction_end, length(state.messages), length(new_path)})

          %{
            state
            | messages: Enum.reverse(new_path),
              last_prompt_tokens: 0,
              last_usage_msg_index: 0
          }

        {:error, reason} ->
          Logger.warning("Auto-compaction failed: #{inspect(reason)}")
          state
      end
    else
      state
    end
  end

  def maybe_auto_compact(state), do: state

  @doc """
  Builds a token estimate using the hybrid approach.

  - If we have a recent usage report, use it as a calibrated base and add
    heuristic estimates for messages added since.
  - If no usage data yet, fall back to full heuristic estimation.
  """
  @spec estimate_current_tokens(State.t(), pos_integer()) :: non_neg_integer()
  def estimate_current_tokens(%State{} = state, _context_window) do
    if state.last_prompt_tokens > 0 do
      # Messages added after the last usage report
      messages_since =
        Enum.take(state.messages, length(state.messages) - state.last_usage_msg_index)

      Opal.Token.hybrid_estimate(state.last_prompt_tokens, messages_since)
    else
      # No usage data yet — estimate the full context heuristically
      # This calls back to the main Agent module for proper message building
      all_messages = Opal.Agent.build_messages_for_usage(state)
      Opal.Token.estimate_context(all_messages)
    end
  end

  @doc """
  Handles overflow compaction without a session process.

  Without a session process we can't compact — surface the raw error.
  """
  @spec handle_overflow_compaction(State.t(), term()) :: {:noreply, State.t()}
  def handle_overflow_compaction(%State{session: nil} = state, reason) do
    Logger.error("Context overflow but no session attached — cannot compact")
    broadcast(state, {:error, {:overflow_no_session, reason}})
    {:noreply, %{state | status: :idle}}
  end

  def handle_overflow_compaction(%State{session: session, model: model} = state, reason) do
    context_window = model_context_window(model)

    # Aggressive keep budget: retain only ~20% of the context window so
    # the retried turn has plenty of headroom.
    keep_tokens = div(context_window, 5)

    Logger.info("Context overflow detected — compacting to #{keep_tokens} tokens")
    broadcast(state, {:compaction_start, :overflow})

    case Opal.Session.Compaction.compact(session,
           provider: state.provider,
           model: state.model,
           keep_recent_tokens: keep_tokens,
           force: true
         ) do
      :ok ->
        new_path = Opal.Session.get_path(session)
        broadcast(state, {:compaction_end, length(state.messages), length(new_path)})

        state = %{
          state
          | messages: Enum.reverse(new_path),
            last_prompt_tokens: 0,
            overflow_detected: false,
            last_usage_msg_index: 0
        }

        # Auto-retry the turn immediately after compaction
        Opal.Agent.run_turn(state)

      {:error, compact_error} ->
        Logger.error("Overflow compaction failed: #{inspect(compact_error)}")
        broadcast(state, {:error, {:overflow_compact_failed, reason, compact_error}})
        {:noreply, %{state | status: :idle}}
    end
  end

  @doc """
  Updates token usage from a stream event and checks for overflow.

  Handles both Chat Completions keys (prompt_tokens) and Responses API keys (input_tokens).
  Flags usage-based overflow so finalize_response/1 can trigger compaction.
  """
  @spec update_usage(map(), State.t()) :: State.t()
  def update_usage(usage, state) do
    # Handle both Chat Completions keys (prompt_tokens) and Responses API keys (input_tokens)
    prompt =
      Map.get(
        usage,
        "prompt_tokens",
        Map.get(
          usage,
          :prompt_tokens,
          Map.get(usage, "input_tokens", Map.get(usage, :input_tokens, 0))
        )
      ) || 0

    completion =
      Map.get(
        usage,
        "completion_tokens",
        Map.get(
          usage,
          :completion_tokens,
          Map.get(usage, "output_tokens", Map.get(usage, :output_tokens, 0))
        )
      ) || 0

    total =
      Map.get(usage, "total_tokens", Map.get(usage, :total_tokens, prompt + completion)) || 0

    token_usage = %{
      state.token_usage
      | prompt_tokens: state.token_usage.prompt_tokens + prompt,
        completion_tokens: state.token_usage.completion_tokens + completion,
        total_tokens: state.token_usage.total_tokens + total,
        current_context_tokens: prompt
    }

    state = %{
      state
      | token_usage: token_usage,
        last_prompt_tokens: prompt,
        last_usage_msg_index: length(state.messages)
    }

    context_window = model_context_window(state.model)

    broadcast(state, {:usage_update, %{state.token_usage | context_window: context_window}})

    # Flag usage-based overflow so finalize_response/1 can trigger compaction
    # before the *next* turn pushes past the limit.
    if Opal.Agent.Overflow.usage_overflow?(prompt, context_window) do
      Logger.warning("Usage overflow: #{prompt} input tokens > #{context_window} context window")
      %{state | overflow_detected: true}
    else
      state
    end
  end

  # Private helper functions

  defp model_context_window(model), do: Opal.Models.context_window(model)

  defp broadcast(%State{} = state, event), do: Opal.Agent.EventLog.broadcast(state, event)
end
