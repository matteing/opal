defmodule Opal.Tool.AskUser do
  @moduledoc """
  Asks the user a question and waits for their response.

  Sends a server→client RPC request (`client/ask_user`) that blocks the
  tool task until the user responds. Supports both freeform text input
  and optional multiple-choice questions.

  Not available to sub-agents — only top-level agents prompt the user.
  """

  @behaviour Opal.Tool

  alias Opal.Tool.Args, as: ToolArgs

  @args_schema [
    question: [type: :string, required: true],
    choices: [type: {:list, :string}, default: []]
  ]

  @impl true
  @spec name() :: String.t()
  def name, do: "ask_user"

  @impl true
  @spec description() :: String.t()
  def description do
    "Ask the user a question and wait for their response. " <>
      "Provide optional choices for a multiple-choice question."
  end

  @impl true
  def meta(%{"question" => q}), do: Opal.Util.Text.truncate_preview(q, 60)
  def meta(_), do: "ask_user"

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "question" => %{
          "type" => "string",
          "description" => "The question to ask."
        },
        "choices" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Optional list of choices for multiple-choice."
        }
      },
      "required" => ["question"]
    }
  end

  @impl true
  @spec execute(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(args, context) when is_map(args) do
    with {:ok, opts} <-
           ToolArgs.validate(args, @args_schema,
             required_message: "Missing required parameter: question"
           ) do
      params = %{
        session_id: context.session_id,
        question: opts[:question],
        choices: opts[:choices]
      }

      case Opal.RPC.Server.request_client("client/ask_user", params, :infinity) do
        {:ok, %{"answer" => answer}} -> {:ok, answer}
        {:ok, result} -> {:ok, inspect(result)}
        {:error, reason} -> {:error, "User input request failed: #{inspect(reason)}"}
      end
    end
  end

  def execute(_args, _context), do: {:error, "Missing required parameter: question"}
end
