defmodule Opal.Agent.UsageTracker do
  @moduledoc """
  Token usage tracking and context-aware compaction for the agent loop.

  Combines actual provider usage reports with heuristic estimates for
  messages added between turns, letting the agent predict overflow
  *before* it happens.
  """

  require Logger

  alias Opal.Agent.{Emitter, Overflow, State}
  alias Opal.Provider.Registry, as: Models
  alias Opal.Session.Compaction
  alias Opal.Token

  @type build_messages :: (State.t() -> [Opal.Message.t()])

  @auto_compact_ratio 0.80

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Compacts the conversation when estimated usage crosses `#{@auto_compact_ratio * 100}%`
  of the context window. No-ops without a live session.
  """
  @spec maybe_auto_compact(State.t(), build_messages()) :: State.t()
  def maybe_auto_compact(%State{session: session} = state, build_messages_fn)
      when is_pid(session) do
    window = context_window(state)
    estimated = estimate_tokens(state, build_messages_fn)

    if estimated / window >= @auto_compact_ratio do
      Logger.info("Auto-compacting: ~#{estimated}/#{window} tokens (#{pct(estimated, window)}%)")
      compact(state, keep: div(window, 4))
    else
      state
    end
  end

  def maybe_auto_compact(state, _build_messages_fn), do: state

  @doc """
  Estimates the current context size in tokens.

  When a recent provider usage report exists, uses it as a calibrated base
  and adds heuristic estimates only for messages appended since. Otherwise
  falls back to a full heuristic pass.
  """
  @spec estimate_tokens(State.t(), build_messages()) :: non_neg_integer()
  def estimate_tokens(%State{last_prompt_tokens: base} = state, _build_messages_fn)
      when base > 0 do
    trailing = Enum.take(state.messages, length(state.messages) - state.last_usage_msg_index)
    Token.hybrid_estimate(base, trailing)
  end

  def estimate_tokens(state, build_messages_fn) do
    Token.estimate_context(build_messages_fn.(state))
  end

  @doc """
  Reacts to a context overflow error by aggressively compacting
  and signalling `{:next_turn, state}` to retry.
  """
  @spec handle_overflow(State.t(), term()) :: {:next_turn, State.t()} | State.t()
  def handle_overflow(%State{session: nil} = state, reason) do
    Logger.error("Context overflow with no session — cannot compact")
    Emitter.broadcast(state, {:error, {:overflow_no_session, reason}})
    %{state | status: :idle}
  end

  def handle_overflow(%State{} = state, reason) do
    keep = div(context_window(state), 5)
    Logger.info("Context overflow — compacting to #{keep} tokens")

    case do_compact(state, keep: keep, force: true) do
      {:ok, state} ->
        {:next_turn, %{state | overflow_detected: false}}

      {:error, err} ->
        Logger.error("Overflow compaction failed: #{inspect(err)}")
        Emitter.broadcast(state, {:error, {:overflow_compact_failed, reason, err}})
        %{state | status: :idle}
    end
  end

  @doc """
  Records a provider usage report and flags overflow when input tokens
  exceed the context window.

  Normalizes across both Chat Completions (`prompt_tokens`) and
  Responses API (`input_tokens`) key conventions.
  """
  @spec update_usage(map(), State.t()) :: State.t()
  def update_usage(usage, %State{} = state) when is_map(usage) do
    prompt = extract(usage, ~w(prompt_tokens input_tokens))
    completion = extract(usage, ~w(completion_tokens output_tokens))

    total =
      extract(usage, ~w(total_tokens)) |> then(&if(&1 > 0, do: &1, else: prompt + completion))

    token_usage = %{
      state.token_usage
      | prompt_tokens: state.token_usage.prompt_tokens + prompt,
        completion_tokens: state.token_usage.completion_tokens + completion,
        total_tokens: state.token_usage.total_tokens + total,
        current_context_tokens: prompt
    }

    window = context_window(state)

    state = %{
      state
      | token_usage: token_usage,
        last_prompt_tokens: prompt,
        last_usage_msg_index: length(state.messages)
    }

    Emitter.broadcast(state, {:usage_update, %{token_usage | context_window: window}})

    if Overflow.usage_overflow?(prompt, window) do
      Logger.warning("Usage overflow: #{prompt} input tokens / #{window} context window")
      %{state | overflow_detected: true}
    else
      state
    end
  end

  # ── Internals ───────────────────────────────────────────────────────

  @spec compact(State.t(), keyword()) :: State.t()
  defp compact(state, opts) do
    Emitter.broadcast(state, {:compaction_start, length(state.messages)})

    case do_compact(state, opts) do
      {:ok, state} ->
        state

      {:error, reason} ->
        Logger.warning("Auto-compaction failed: #{inspect(reason)}")
        state
    end
  end

  @spec do_compact(State.t(), keyword()) :: {:ok, State.t()} | {:error, term()}
  defp do_compact(%State{session: session} = state, opts) do
    compact_opts =
      [provider: state.provider, model: state.model] ++
        Keyword.take(opts, [:keep_recent_tokens, :force]) ++
        if(tokens = opts[:keep], do: [keep_recent_tokens: tokens], else: [])

    case Compaction.compact(session, compact_opts) do
      :ok ->
        new_path = Opal.Session.get_path(session)
        Emitter.broadcast(state, {:compaction_end, length(state.messages), length(new_path)})

        {:ok,
         %{
           state
           | messages: Enum.reverse(new_path),
             last_prompt_tokens: 0,
             last_usage_msg_index: 0
         }}

      {:error, _} = err ->
        err
    end
  end

  # Extracts a numeric value by trying string keys then atom keys in order.
  @spec extract(map(), [String.t()]) :: non_neg_integer()
  defp extract(usage, candidates) do
    Enum.find_value(candidates, 0, fn key ->
      Map.get(usage, key) || Map.get(usage, String.to_existing_atom(key))
    end) || 0
  end

  defp context_window(%State{model: model}), do: Models.context_window(model)

  defp pct(n, total), do: Float.round(n / total * 100, 1)
end
