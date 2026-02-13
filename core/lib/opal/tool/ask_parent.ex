defmodule Opal.Tool.AskParent do
  @moduledoc """
  Asks a question to the parent agent (or escalates to the user).

  This tool is available to sub-agents instead of `AskUser`. When called,
  it sends the question to the parent agent's tool task process via a
  `question_handler` callback in the tool context. If no handler is set
  (standalone sub-agent), it falls back to the same direct RPC path that
  `AskUser` uses.

  See `Opal.Tool.Ask` for the shared spec and RPC logic.
  """

  @behaviour Opal.Tool

  @impl true
  defdelegate name, to: Opal.Tool.Ask

  @impl true
  defdelegate description, to: Opal.Tool.Ask

  @impl true
  defdelegate parameters, to: Opal.Tool.Ask

  @impl true
  defdelegate meta(args), to: Opal.Tool.Ask

  @impl true
  def execute(%{"question" => question} = args, context) do
    case Map.get(context, :question_handler) do
      handler when is_function(handler, 1) ->
        request = %{
          question: question,
          choices: Map.get(args, "choices", [])
        }

        case handler.(request) do
          {:ok, answer} -> {:ok, answer}
          {:error, reason} -> {:error, "Question failed: #{inspect(reason)}"}
        end

      nil ->
        # Fallback: direct escalation via RPC (standalone sub-agent)
        Opal.Tool.Ask.ask_via_rpc(args, context)
    end
  end

  def execute(_args, _context) do
    {:error, "Missing required parameter: question"}
  end
end
