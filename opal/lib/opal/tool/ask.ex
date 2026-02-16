defmodule Opal.Tool.Ask do
  @moduledoc """
  Shared spec and RPC helper for the ask-user family of tools.

  Both `Opal.Tool.AskUser` (top-level agent) and `Opal.Tool.AskParent`
  (sub-agent) present an identical `ask_user` interface to the LLM.
  This module holds the common schema, meta, and the RPC call so the
  two tools stay DRY — the only thing that differs is the delivery
  path in `execute/2`.
  """

  @doc "Shared tool name — both tools expose `ask_user` to the LLM."
  def name, do: "ask_user"

  @doc "Shared description shown in the tool list."
  def description do
    "Ask the user a question and wait for their response. " <>
      "Provide optional choices for a multiple-choice question."
  end

  @doc "Shared JSON-Schema parameters."
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

  @doc "Shared meta — truncated question for display."
  def meta(%{"question" => q}), do: String.slice(q, 0, 60)
  def meta(_), do: "ask_user"

  @doc """
  Sends a `client/ask_user` RPC request and returns the answer.

  Builds the params map from the raw tool args + context, then calls
  `Opal.RPC.Stdio.request_client/3` with an infinite timeout (user
  input has no upper bound).
  """
  def ask_via_rpc(args, context) do
    params = %{
      session_id: context.session_id,
      question: args["question"],
      choices: Map.get(args, "choices", [])
    }

    case Opal.RPC.Stdio.request_client("client/ask_user", params, :infinity) do
      {:ok, %{"answer" => answer}} -> {:ok, answer}
      {:ok, result} -> {:ok, inspect(result)}
      {:error, reason} -> {:error, "User input request failed: #{inspect(reason)}"}
    end
  end
end
