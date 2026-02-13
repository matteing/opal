defmodule Opal.Message do
  @moduledoc """
  A struct representing messages in an agent conversation.

  Messages flow through the agent loop and carry content between the user,
  assistant, and tool executions. Each message has a role that determines
  its semantics:

    * `:user` — a user-originated message with text content
    * `:assistant` — an assistant response with text and optional tool calls
    * `:tool_call` — a tool invocation specifying name, call ID, and arguments
    * `:tool_result` — the result of a tool execution, keyed by call ID

  Every message is assigned a unique ID at construction time.
  """

  @type role :: :user | :assistant | :tool_call | :tool_result

  @type tool_call :: %{
          call_id: String.t(),
          name: String.t(),
          arguments: map()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          parent_id: String.t() | nil,
          role: role(),
          content: String.t() | nil,
          tool_calls: [tool_call()] | nil,
          call_id: String.t() | nil,
          name: String.t() | nil,
          is_error: boolean(),
          # Optional structured data attached by compaction or other subsystems.
          # For compaction summaries this holds :type, :read_files, :modified_files.
          metadata: map() | nil
        }

  @enforce_keys [:id, :role]
  defstruct [
    :id,
    :parent_id,
    :role,
    :content,
    :tool_calls,
    :call_id,
    :name,
    :metadata,
    is_error: false
  ]

  @doc """
  Creates a user message with the given text content.

  ## Examples

      iex> msg = Opal.Message.user("Hello")
      iex> msg.role
      :user
  """
  @spec user(String.t()) :: t()
  def user(content) when is_binary(content) do
    %__MODULE__{id: generate_id(), role: :user, content: content}
  end

  @doc """
  Creates an assistant message with text content and optional tool calls.

  ## Examples

      iex> msg = Opal.Message.assistant("Sure, let me check.", [])
      iex> msg.role
      :assistant
  """
  @spec assistant(String.t() | nil, [tool_call()]) :: t()
  def assistant(content, tool_calls \\ []) do
    %__MODULE__{
      id: generate_id(),
      role: :assistant,
      content: content,
      tool_calls: tool_calls
    }
  end

  @doc """
  Creates a tool call message representing a tool invocation.

  ## Parameters

    * `call_id` — unique identifier linking this call to its result
    * `name` — the tool name to invoke
    * `arguments` — a map of arguments to pass to the tool
  """
  @spec tool_call(String.t(), String.t(), map()) :: t()
  def tool_call(call_id, name, arguments)
      when is_binary(call_id) and is_binary(name) and is_map(arguments) do
    %__MODULE__{
      id: generate_id(),
      role: :tool_call,
      call_id: call_id,
      name: name,
      content: Jason.encode!(arguments)
    }
  end

  @doc """
  Creates a tool result message with the output of a tool execution.

  ## Parameters

    * `call_id` — the call ID this result corresponds to
    * `output` — the string output produced by the tool
    * `is_error` — whether the tool execution resulted in an error (default: `false`)
  """
  @spec tool_result(String.t(), String.t(), boolean()) :: t()
  def tool_result(call_id, output, is_error \\ false)
      when is_binary(call_id) and is_binary(output) and is_boolean(is_error) do
    %__MODULE__{
      id: generate_id(),
      role: :tool_result,
      call_id: call_id,
      content: output,
      is_error: is_error
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
