defmodule Opal.Tool.SubAgent do
  @moduledoc """
  Tool that allows an agent to spawn a sub-agent for delegated tasks.

  The sub-agent runs with its own conversation loop, executes tools, and
  returns a structured result containing the final response and a log of
  all tool calls made. Sub-agent events are forwarded to the parent session
  for real-time observability.

  ## Depth Enforcement

  Sub-agents are limited to one level — this tool is never included in the
  sub-agent's tool list, preventing recursive spawning.

  ## Tool Selection

  The parent agent can specify a subset of its own tools by name. If omitted,
  the sub-agent inherits all of the parent's tools (minus this one).
  """

  @behaviour Opal.Tool

  @impl true
  def name, do: "sub_agent"

  @impl true
  def description do
    "Spawn a sub-agent to work on a delegated task. The sub-agent runs independently " <>
      "with its own conversation and tools, then returns a structured result with its " <>
      "response and a log of tool calls it made. Use this for parallel or specialized work."
  end

  @impl true
  def meta(%{"prompt" => prompt}) do
    truncated =
      if String.length(prompt) > 60, do: String.slice(prompt, 0, 57) <> "...", else: prompt

    "Sub-agent: #{truncated}"
  end

  def meta(_), do: "Sub-agent"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "prompt" => %{
          "type" => "string",
          "description" => "The task prompt to send to the sub-agent"
        },
        "tools" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" =>
            "Optional list of tool names (subset of your tools) the sub-agent can use. " <>
              "If omitted, the sub-agent gets all your tools."
        },
        "model" => %{
          "type" => "string",
          "description" =>
            "Optional model ID override for the sub-agent (e.g. \"claude-haiku-3-5\"). " <>
              "Uses the same provider as the parent."
        },
        "system_prompt" => %{
          "type" => "string",
          "description" => "Optional system prompt override for the sub-agent"
        }
      },
      "required" => ["prompt"]
    }
  end

  @impl true
  def execute(args, context) do
    agent_state = Map.get(context, :agent_state)
    config = Map.get(context, :config)

    cond do
      agent_state == nil ->
        {:error, "sub_agent tool requires agent_state in context"}

      config != nil and not config.features.sub_agents.enabled ->
        {:error, "Sub-agents are disabled in configuration"}

      true ->
        run_sub_agent(args, context)
    end
  end

  defp run_sub_agent(args, context) do
    parent_state = context.agent_state
    parent_call_id = Map.get(context, :call_id, "")

    # Build a question_handler that the sub-agent's AskParent tool can call.
    # It sends a message to *this* process (the parent's tool task running
    # collect_and_forward) and blocks until we reply with the answer.
    # Classic Erlang request/reply with a make_ref for correlation.
    parent_task = self()

    question_handler = fn %{question: question, choices: choices} ->
      ref = make_ref()

      send(
        parent_task,
        {:sub_agent_question, self(), ref, %{question: question, choices: choices}}
      )

      receive do
        {:sub_agent_answer, ^ref, answer} -> {:ok, answer}
      end
    end

    overrides =
      build_overrides(args, parent_state) |> Map.put(:question_handler, question_handler)

    case Opal.SubAgent.spawn_from_state(parent_state, overrides) do
      {:ok, sub_pid} ->
        sub_state = Opal.Agent.get_state(sub_pid)
        sub_session_id = sub_state.session_id
        parent_session_id = parent_state.session_id

        # Subscribe to sub-agent events for forwarding
        Opal.Events.subscribe(sub_session_id)

        # Emit sub_agent_start with metadata for the CLI tab UI
        tool_names = Enum.map(sub_state.tools, & &1.name())
        label = truncate(args["prompt"] || "", 80)

        forward_event(
          parent_session_id,
          sub_session_id,
          parent_call_id,
          {:sub_agent_start, %{model: sub_state.model.id, label: label, tools: tool_names}}
        )

        # Send the prompt
        Opal.Agent.prompt(sub_pid, args["prompt"])

        # Collect response while forwarding events
        result =
          collect_and_forward(sub_session_id, parent_session_id, parent_call_id, "", [], 120_000)

        # Clean up
        Opal.Events.unsubscribe(sub_session_id)
        Opal.SubAgent.stop(sub_pid)

        case result do
          {:ok, response, tool_log} ->
            {:ok, format_result(response, tool_log)}

          {:error, reason} ->
            {:error, "Sub-agent failed: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Failed to spawn sub-agent: #{inspect(reason)}"}
    end
  end

  # Builds the overrides map for SubAgent.spawn from tool arguments.
  defp build_overrides(args, parent_state) do
    overrides = %{}

    overrides =
      case args["system_prompt"] do
        nil -> overrides
        prompt -> Map.put(overrides, :system_prompt, prompt)
      end

    overrides =
      case args["model"] do
        nil -> overrides
        model_id -> Map.put(overrides, :model, {parent_state.model.provider, model_id})
      end

    # Filter tools: exclude this tool (depth enforcement), then apply user selection
    parent_tools = parent_state.tools -- [__MODULE__]

    tools =
      case args["tools"] do
        nil ->
          parent_tools

        tool_names when is_list(tool_names) ->
          Enum.filter(parent_tools, fn mod -> mod.name() in tool_names end)
      end

    Map.put(overrides, :tools, tools)
  end

  # Collects sub-agent response while forwarding events to the parent session.
  # Also handles :sub_agent_question messages from the sub-agent's AskParent
  # tool — escalates the question to the user via RPC and replies with the
  # answer, all within the same receive loop (no extra process needed).
  defp collect_and_forward(
         sub_session_id,
         parent_session_id,
         parent_call_id,
         text,
         tool_log,
         timeout
       ) do
    receive do
      # --- Sub-agent question escalation ---
      # The sub-agent's AskParent tool sends this when the LLM needs user input.
      # We handle it here so the parent's collect loop acts as a message relay:
      # sub-agent task → parent task → RPC → CLI → user → back the same way.
      {:sub_agent_question, from, ref, %{question: question, choices: choices}} ->
        args = %{"question" => question, "choices" => choices}

        answer =
          case Opal.Tool.Ask.ask_via_rpc(args, %{session_id: parent_session_id}) do
            {:ok, a} -> a
            {:error, _} -> "(question could not be answered)"
          end

        send(from, {:sub_agent_answer, ref, answer})

        collect_and_forward(
          sub_session_id,
          parent_session_id,
          parent_call_id,
          text,
          tool_log,
          timeout
        )

      # --- Event forwarding ---
      {:opal_event, ^sub_session_id, {:message_delta, %{delta: delta}} = event} ->
        forward_event(parent_session_id, sub_session_id, parent_call_id, event)

        collect_and_forward(
          sub_session_id,
          parent_session_id,
          parent_call_id,
          text <> delta,
          tool_log,
          timeout
        )

      {:opal_event, ^sub_session_id, {:tool_execution_start, name, args, _meta} = event} ->
        forward_event(parent_session_id, sub_session_id, parent_call_id, event)
        entry = %{tool: name, arguments: args, result: nil}

        collect_and_forward(
          sub_session_id,
          parent_session_id,
          parent_call_id,
          text,
          tool_log ++ [entry],
          timeout
        )

      {:opal_event, ^sub_session_id, {:tool_execution_end, name, result} = event} ->
        forward_event(parent_session_id, sub_session_id, parent_call_id, event)
        tool_log = update_last_tool_result(tool_log, name, result)

        collect_and_forward(
          sub_session_id,
          parent_session_id,
          parent_call_id,
          text,
          tool_log,
          timeout
        )

      {:opal_event, ^sub_session_id, {:agent_end, _messages} = event} ->
        forward_event(parent_session_id, sub_session_id, parent_call_id, event)
        {:ok, text, tool_log}

      {:opal_event, ^sub_session_id, {:agent_end, _messages, _usage} = event} ->
        forward_event(parent_session_id, sub_session_id, parent_call_id, event)
        {:ok, text, tool_log}

      {:opal_event, ^sub_session_id, {:error, reason}} ->
        {:error, reason}

      {:opal_event, ^sub_session_id, event} ->
        forward_event(parent_session_id, sub_session_id, parent_call_id, event)

        collect_and_forward(
          sub_session_id,
          parent_session_id,
          parent_call_id,
          text,
          tool_log,
          timeout
        )
    after
      timeout ->
        {:error, :timeout}
    end
  end

  # Forwards a sub-agent event to the parent session, tagged with parent call_id and sub-agent ID.
  defp forward_event(parent_session_id, sub_session_id, parent_call_id, event) do
    Opal.Events.broadcast(
      parent_session_id,
      {:sub_agent_event, parent_call_id, sub_session_id, event}
    )
  end

  # Updates the result field of the last tool log entry matching the given name.
  defp update_last_tool_result(tool_log, name, result) do
    idx =
      tool_log
      |> Enum.reverse()
      |> Enum.find_index(fn entry -> entry.tool == name and entry.result == nil end)

    if idx do
      real_idx = length(tool_log) - 1 - idx
      List.update_at(tool_log, real_idx, &%{&1 | result: result})
    else
      tool_log
    end
  end

  # Formats the sub-agent's response and tool log into a readable string.
  defp format_result(response, []) do
    response
  end

  defp format_result(response, tool_log) do
    tool_section =
      tool_log
      |> Enum.map_join("\n", fn entry ->
        result_str = format_tool_result(entry.result)
        "- #{entry.tool}(#{Jason.encode!(entry.arguments)}): #{result_str}"
      end)

    """
    ## Sub-agent tool log
    #{tool_section}

    ## Sub-agent response
    #{response}\
    """
  end

  defp format_tool_result({:ok, output}) do
    truncate(output, 500)
  end

  defp format_tool_result({:error, reason}) do
    "ERROR: #{truncate(to_string(reason), 200)}"
  end

  defp format_tool_result(nil), do: "(no result)"

  defp truncate(str, max) when byte_size(str) <= max, do: str

  defp truncate(str, max) do
    String.slice(str, 0, max) <> "… (truncated)"
  end
end
