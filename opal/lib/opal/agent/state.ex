defmodule Opal.Agent.State do
  @moduledoc """
  Internal runtime state for `Opal.Agent`.
  """

  @type t :: %__MODULE__{
          session_id: String.t(),
          system_prompt: String.t(),
          messages: [Opal.Message.t()],
          model: Opal.Provider.Model.t(),
          tools: [module()],
          disabled_tools: [String.t()],
          working_dir: String.t(),
          config: Opal.Config.t(),
          status: :idle | :running | :streaming | :executing_tools,
          streaming_resp: Req.Response.t() | nil,
          streaming_ref: reference() | nil,
          streaming_cancel: (-> :ok) | nil,
          current_text: String.t(),
          current_tool_calls: [map()],
          current_thinking: String.t() | nil,
          pending_steers: [String.t()],
          status_tag_buffer: String.t(),
          provider: module(),
          session: pid() | nil,
          tool_supervisor: atom() | pid(),
          sub_agent_supervisor: atom() | pid(),
          mcp_supervisor: atom() | pid() | nil,
          mcp_servers: [map()],
          context: String.t(),
          context_files: [String.t()],
          available_skills: [Opal.Skill.t()],
          active_skills: [String.t()],
          token_usage: map(),
          retry_count: non_neg_integer(),
          max_retries: pos_integer(),
          retry_base_delay_ms: pos_integer(),
          retry_max_delay_ms: pos_integer(),
          overflow_detected: boolean(),
          stream_errored: boolean(),
          question_handler: (map() -> {:ok, String.t()} | {:error, term()}) | nil,
          pending_tool_tasks: %{reference() => {Task.t(), map()}},
          tool_results: [{map(), term()}],
          tool_context: map() | nil,
          last_prompt_tokens: non_neg_integer(),
          last_chunk_at: integer() | nil,
          stream_watchdog: reference() | nil,
          last_usage_msg_index: non_neg_integer()
        }

  @enforce_keys [:session_id, :model, :working_dir, :config]
  defstruct [
    :session_id,
    :model,
    :working_dir,
    :config,
    :streaming_resp,
    streaming_ref: nil,
    streaming_cancel: nil,
    system_prompt: "",
    messages: [],
    tools: [],
    disabled_tools: [],
    status: :idle,
    current_text: "",
    current_tool_calls: [],
    current_thinking: nil,
    pending_steers: [],
    status_tag_buffer: "",
    provider: Opal.Provider.Copilot,
    session: nil,
    tool_supervisor: nil,
    sub_agent_supervisor: nil,
    mcp_supervisor: nil,
    mcp_servers: [],
    context: "",
    context_files: [],
    available_skills: [],
    active_skills: [],
    token_usage: %{
      prompt_tokens: 0,
      completion_tokens: 0,
      total_tokens: 0,
      context_window: 0,
      current_context_tokens: 0
    },
    last_prompt_tokens: 0,
    last_chunk_at: nil,
    stream_watchdog: nil,
    retry_count: 0,
    max_retries: 3,
    retry_base_delay_ms: 2_000,
    retry_max_delay_ms: 60_000,
    overflow_detected: false,
    stream_errored: false,
    last_usage_msg_index: 0,
    question_handler: nil,
    pending_tool_tasks: %{},
    tool_results: [],
    tool_context: nil
  ]

  @valid_states [:idle, :running, :streaming, :executing_tools]

  @doc "Maps the status field to a valid gen_statem state name."
  @spec state_name(t()) :: :idle | :running | :streaming | :executing_tools
  def state_name(%__MODULE__{status: status}) when status in @valid_states, do: status
end
