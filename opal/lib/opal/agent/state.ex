defmodule Opal.Agent.State do
  @moduledoc """
  Internal runtime state for `Opal.Agent`.

  ## Field groups

  Fields are organized into logical groups:

  - **Identity** — `session_id`, `model`, `working_dir`, `config`, `provider`
  - **Conversation** — `system_prompt`, `messages`, `session`
  - **Tool registry** — `tools`, `disabled_tools` (use `Opal.Agent.ToolRunner.active_tools/1`
    for the filtered set; never read `tools` directly)
  - **Tool execution** — `tool_supervisor`, `pending_tool_tasks`, `tool_results`, `tool_context`
  - **Streaming accumulator** — `current_text`, `current_tool_calls`, `current_thinking`,
    `tag_buffers` (ephemeral, reset every turn)
  - **Stream transport** — `streaming_resp` (SSE via `Req.Response`)
  - **Stream health** — `last_chunk_at`, `stream_watchdog`, `stream_errored`
  - **Token tracking** — `token_usage`, `last_prompt_tokens`, `last_usage_msg_index`
  - **Context** — `context_entries` (raw discovered file data), `context_files` (paths for UI)
  - **Skills** — `available_skills`, `active_skills`
  - **Sub-agents / MCP** — `sub_agent_supervisor`, `mcp_supervisor`, `mcp_servers`
  - **Resilience** — `retry_count`, `max_retries`, `retry_base_delay_ms`, `retry_max_delay_ms`,
    `overflow_detected`
  - **Interaction** — `pending_messages`
  """

  @type t :: %__MODULE__{
          # ── Identity ─────────────────────────────────────────────────
          # Unique identifier for the conversation session.
          session_id: String.t(),
          # LLM model to use for this session.
          model: Opal.Provider.Model.t(),
          # Root directory for file operations and context discovery.
          working_dir: String.t(),
          # Typed configuration (features, limits, etc.).
          config: Opal.Config.t(),
          # LLM provider module (e.g. Opal.Provider.Copilot).
          provider: module(),
          # Agent status machine: idle → streaming → executing_tools → streaming …
          status: :idle | :running | :streaming | :executing_tools,

          # ── Conversation ─────────────────────────────────────────────
          # Base system prompt (user-provided or default).
          system_prompt: String.t(),
          # Conversation history (stored in reverse — most recent first).
          messages: [Opal.Message.t()],
          # Session persistence GenServer pid (nil = no persistence).
          session: pid() | nil,

          # ── Tool registry ────────────────────────────────────────────
          # Full pool of registered tool modules (built-in + MCP + custom).
          # ⚠ Do NOT read directly for availability — use
          #   `Opal.Agent.ToolRunner.active_tools/1` which applies
          #   feature gates and the disabled list.
          tools: [module()],
          # Per-name disable list (from config or RPC). A tool whose name
          # appears here is excluded by active_tools/1. Stored as names
          # (not modules) so it can disable tools not yet loaded.
          disabled_tools: [String.t()],

          # ── Tool execution ───────────────────────────────────────────
          # Task.Supervisor for concurrent tool tasks.
          tool_supervisor: atom() | pid(),
          # In-flight tool tasks: ref → {Task.t(), tool_call_map}.
          pending_tool_tasks: %{reference() => {Task.t(), map()}},
          # Completed results in this batch (accumulated in reverse,
          # reversed in finalize_tool_batch/1).
          tool_results: [{map(), term()}],
          # Shared context map passed to every tool in the current batch.
          tool_context: map() | nil,

          # ── Streaming accumulator (ephemeral, reset each turn) ───────
          # Assistant text assembled from streaming deltas.
          current_text: String.t(),
          # Tool call fragments being assembled from start/delta/done events.
          current_tool_calls: [map()],
          # Chain-of-thought reasoning text (nil = model didn't emit thinking).
          current_thinking: String.t() | nil,
          # Partial XML tag buffers for cross-chunk extraction (e.g. status, title).
          # Keyed by tag name atom; each value is the buffered partial text.
          tag_buffers: %{atom() => String.t()},

          # ── Stream transport ─────────────────────────────────────
          # HTTP/SSE: Req.Response for async SSE streams (Provider.Copilot).
          streaming_resp: Req.Response.t() | nil,

          # ── Stream health ────────────────────────────────────────────
          # Monotonic timestamp of the last received chunk (for stall detection).
          last_chunk_at: integer() | nil,
          # Timer ref for the periodic stall-detection watchdog.
          stream_watchdog: reference() | nil,
          # Set to the error reason when a stream error event arrives;
          # signals the agent to discard partial output. If the reason
          # matches a context overflow pattern, the agent triggers
          # compaction instead of going idle. `false` when no error.
          stream_errored: false | term(),

          # ── Token tracking ───────────────────────────────────────────
          # Cumulative session-wide counters (prompt, completion, total,
          # context_window, current_context_tokens). Updated every turn.
          token_usage: map(),
          # Most recent turn's input token count from the provider.
          # Used as the calibrated base for hybrid estimation between
          # turns (see Opal.Token.hybrid_estimate/2).
          last_prompt_tokens: non_neg_integer(),
          # Length of messages at the time of the last usage report.
          # Lets the hybrid estimator know which messages are already
          # accounted for in last_prompt_tokens.
          last_usage_msg_index: non_neg_integer(),

          # ── Context ──────────────────────────────────────────────────
          # Raw discovered context files (AGENTS.md, etc.) as
          # `[%{path: String.t(), content: String.t()}]` maps.
          # Formatted into the system prompt by `Opal.Agent.SystemPrompt`.
          context_entries: [%{path: String.t(), content: String.t()}],
          # Paths of the discovered context files (for UI display / events).
          context_files: [String.t()],

          # ── Skills ───────────────────────────────────────────────────
          # All discovered skill definitions.
          available_skills: [Opal.Skill.t()],
          # Names of skills that have been loaded into the conversation.
          active_skills: [String.t()],

          # ── Sub-agents / MCP ─────────────────────────────────────────
          # Supervisor for child agent processes.
          sub_agent_supervisor: atom() | pid(),
          # Supervisor for MCP server connections.
          mcp_supervisor: atom() | pid() | nil,
          # MCP server configs (used for connection management).
          mcp_servers: [map()],

          # ── Resilience ───────────────────────────────────────────────
          # Consecutive retry count for the current turn.
          retry_count: non_neg_integer(),
          # Max retries before giving up on a turn.
          max_retries: pos_integer(),
          # Base delay for exponential backoff (ms).
          retry_base_delay_ms: pos_integer(),
          # Maximum backoff cap (ms).
          retry_max_delay_ms: pos_integer(),
          # Set when provider usage shows input tokens exceed the context
          # window. Triggers compaction before the next turn (not an
          # immediate abort — contrast with stream_errored).
          overflow_detected: boolean(),

          # ── Interaction ──────────────────────────────────────────────

          # Pending messages injected between turns (queued while agent is busy).
          pending_messages: [String.t()]
        }

  @enforce_keys [:session_id, :model, :working_dir, :config]
  defstruct [
    # Identity
    :session_id,
    :model,
    :working_dir,
    :config,
    provider: Opal.Provider.Copilot,
    status: :idle,

    # Conversation
    system_prompt: "",
    messages: [],
    session: nil,

    # Tool registry
    tools: [],
    disabled_tools: [],

    # Tool execution
    tool_supervisor: nil,
    pending_tool_tasks: %{},
    tool_results: [],
    tool_context: nil,

    # Streaming accumulator
    current_text: "",
    current_tool_calls: [],
    current_thinking: nil,
    tag_buffers: %{},

    # Stream transport
    streaming_resp: nil,

    # Stream health
    last_chunk_at: nil,
    stream_watchdog: nil,
    stream_errored: false,

    # Token tracking
    token_usage: %{
      prompt_tokens: 0,
      completion_tokens: 0,
      total_tokens: 0,
      context_window: 0,
      current_context_tokens: 0
    },
    last_prompt_tokens: 0,
    last_usage_msg_index: 0,

    # Context
    context_entries: [],
    context_files: [],

    # Skills
    available_skills: [],
    active_skills: [],

    # Sub-agents / MCP
    sub_agent_supervisor: nil,
    mcp_supervisor: nil,
    mcp_servers: [],

    # Resilience
    retry_count: 0,
    max_retries: 3,
    retry_base_delay_ms: 2_000,
    retry_max_delay_ms: 60_000,
    overflow_detected: false,

    # Interaction
    pending_messages: []
  ]

  @valid_states [:idle, :running, :streaming, :executing_tools]

  @doc "Maps the status field to a valid gen_statem state name."
  @spec state_name(t()) :: :idle | :running | :streaming | :executing_tools
  def state_name(%__MODULE__{status: status}) when status in @valid_states, do: status

  @doc "Appends a message to history, persisting to Session if attached."
  @spec append_message(t(), Opal.Message.t()) :: t()
  def append_message(%__MODULE__{session: nil} = state, msg) do
    %{state | messages: [msg | state.messages]}
  end

  def append_message(%__MODULE__{session: session} = state, msg) do
    Opal.Session.append(session, msg)
    %{state | messages: [msg | state.messages]}
  end

  @doc "Appends multiple messages to history, persisting to Session if attached."
  @spec append_messages(t(), [Opal.Message.t()]) :: t()
  def append_messages(%__MODULE__{session: nil} = state, msgs) do
    %{state | messages: Enum.reverse(msgs) ++ state.messages}
  end

  def append_messages(%__MODULE__{session: session} = state, msgs) do
    Opal.Session.append_many(session, msgs)
    %{state | messages: Enum.reverse(msgs) ++ state.messages}
  end

  @doc "Resets ephemeral streaming accumulator fields."
  @spec reset_stream_fields(t()) :: t()
  def reset_stream_fields(%__MODULE__{} = state) do
    %{
      state
      | current_text: "",
        current_tool_calls: [],
        current_thinking: nil,
        stream_watchdog: nil,
        last_chunk_at: nil
    }
  end
end
