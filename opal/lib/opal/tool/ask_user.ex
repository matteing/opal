defmodule Opal.Tool.AskUser do
  @moduledoc """
  Asks the user a question and waits for their response.

  This tool sends a server→client RPC request (`client/ask_user`) that
  blocks the tool task until the user responds. Supports both freeform
  text input and optional multiple-choice questions.

  Not available to sub-agents — only the top-level interactive agent
  should prompt the user. See `Opal.Tool.Ask` for the shared spec/RPC
  logic.
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
  def execute(%{"question" => _} = args, context) do
    Opal.Tool.Ask.ask_via_rpc(args, context)
  end

  def execute(_args, _context) do
    {:error, "Missing required parameter: question"}
  end
end
