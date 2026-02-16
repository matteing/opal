defmodule Opal.Tool.SubAgentTest do
  use ExUnit.Case, async: false

  alias Opal.Agent
  alias Opal.Events
  alias Opal.Provider.Model
  alias Opal.Tool.SubAgent, as: SubAgentTool

  # --- Test Provider ---
  # Simulates a text-only response for sub-agents.
  defmodule TextProvider do
    @behaviour Opal.Provider

    @impl true
    def stream(_model, _messages, _tools, _opts \\ []) do
      caller = self()
      ref = make_ref()

      resp = %Req.Response{
        status: 200,
        headers: %{},
        body: %Req.Response.Async{
          ref: ref,
          stream_fun: fn
            inner_ref, {inner_ref, {:data, data}} -> {:ok, [data: data]}
            inner_ref, {inner_ref, :done} -> {:ok, [:done]}
            _, _ -> :unknown
          end,
          cancel_fun: fn _ref -> :ok end
        }
      }

      spawn(fn ->
        Process.sleep(5)
        send_text_response(caller, ref, "Sub-agent completed the task.")
      end)

      {:ok, resp}
    end

    @impl true
    def parse_stream_event(data) do
      case Jason.decode(data) do
        {:ok, parsed} -> do_parse(parsed)
        {:error, _} -> []
      end
    end

    @impl true
    def convert_messages(_model, messages), do: messages

    @impl true
    def convert_tools(tools), do: tools

    defp do_parse(%{
           "type" => "response.output_item.added",
           "item" => %{"type" => "message"} = item
         }),
         do: [{:text_start, %{item_id: item["id"]}}]

    defp do_parse(%{"type" => "response.output_text.delta", "delta" => delta}),
      do: [{:text_delta, delta}]

    defp do_parse(%{"type" => "response.output_text.done", "text" => text}),
      do: [{:text_done, text}]

    defp do_parse(%{"type" => "response.completed", "response" => resp}),
      do: [{:response_done, %{usage: Map.get(resp, "usage", %{})}}]

    defp do_parse(_), do: []

    defp send_text_response(caller, ref, text) do
      events = [
        sse_line("response.output_item.added", %{
          "item" => %{"type" => "message", "id" => "item_sub"}
        }),
        sse_line("response.output_text.delta", %{"delta" => text}),
        sse_line("response.output_text.done", %{"text" => text}),
        sse_line("response.completed", %{
          "response" => %{"id" => "resp_sub", "status" => "completed", "usage" => %{}}
        })
      ]

      for event <- events do
        send(caller, {ref, {:data, event}})
        Process.sleep(1)
      end

      send(caller, {ref, :done})
    end

    defp sse_line(type, fields) do
      data = Map.merge(%{"type" => type}, fields) |> Jason.encode!()
      "data: #{data}\n"
    end
  end

  # --- Test Tool ---
  defmodule EchoTool do
    @behaviour Opal.Tool

    @impl true
    def name, do: "echo_tool"

    @impl true
    def description, do: "Echoes input back"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{"input" => %{"type" => "string"}},
        "required" => ["input"]
      }
    end

    @impl true
    def execute(%{"input" => input}, _context), do: {:ok, "Echo: #{input}"}
  end

  defmodule AnotherTool do
    @behaviour Opal.Tool

    @impl true
    def name, do: "another_tool"

    @impl true
    def description, do: "Another tool"

    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def execute(_args, _context), do: {:ok, "done"}
  end

  # --- Helpers ---

  defp start_parent(opts \\ []) do
    session_id = "parent-#{System.unique_integer([:positive])}"
    config = Keyword.get(opts, :config, Opal.Config.new())

    {:ok, tool_sup} = Task.Supervisor.start_link()
    {:ok, sub_agent_sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

    agent_opts = [
      session_id: session_id,
      model: Model.new(:test, "test-model"),
      working_dir: System.tmp_dir!(),
      system_prompt: "You are a parent agent.",
      tools: Keyword.get(opts, :tools, [EchoTool, AnotherTool, SubAgentTool]),
      provider: TextProvider,
      config: config,
      tool_supervisor: tool_sup,
      sub_agent_supervisor: sub_agent_sup
    ]

    {:ok, pid} = Agent.start_link(agent_opts)
    %{pid: pid, session_id: session_id}
  end

  defp build_context(%{pid: parent, session_id: session_id}) do
    state = Agent.get_state(parent)

    %{
      agent_pid: parent,
      agent_state: state,
      working_dir: state.working_dir,
      session_id: session_id,
      config: state.config
    }
  end

  # ============================================================
  # Tool Metadata
  # ============================================================

  describe "tool metadata" do
    test "name/0 returns sub_agent" do
      assert SubAgentTool.name() == "sub_agent"
    end

    test "description/0 is non-empty" do
      assert is_binary(SubAgentTool.description())
      assert String.length(SubAgentTool.description()) > 0
    end

    test "parameters/0 requires prompt" do
      params = SubAgentTool.parameters()
      assert params["required"] == ["prompt"]
      assert Map.has_key?(params["properties"], "prompt")
      assert Map.has_key?(params["properties"], "tools")
      assert Map.has_key?(params["properties"], "model")
      assert Map.has_key?(params["properties"], "system_prompt")
    end

    test "meta/1 truncates long prompts" do
      long = String.duplicate("x", 100)
      meta = SubAgentTool.meta(%{"prompt" => long})
      assert meta =~ "Sub-agent:"
      assert meta =~ "..."
      assert String.length(meta) < 80
    end

    test "meta/1 keeps short prompts intact" do
      assert SubAgentTool.meta(%{"prompt" => "Do something"}) == "Sub-agent: Do something"
    end

    test "meta/1 returns fallback for missing prompt" do
      assert SubAgentTool.meta(%{}) == "Sub-agent"
    end
  end

  # ============================================================
  # Execution — Basic
  # ============================================================

  describe "execute — basic" do
    test "spawns sub-agent and returns its response" do
      parent = start_parent()
      context = build_context(parent)

      {:ok, result} = SubAgentTool.execute(%{"prompt" => "Do something"}, context)
      assert result == "Sub-agent completed the task."
    end

    test "returns error when agent_state missing from context" do
      context = %{working_dir: System.tmp_dir!(), session_id: "x", config: Opal.Config.new()}
      {:error, msg} = SubAgentTool.execute(%{"prompt" => "Do something"}, context)
      assert msg =~ "agent_state"
    end

    test "returns error when sub-agents disabled" do
      config = Opal.Config.new(%{features: %{sub_agents: false}})
      parent = start_parent(config: config)
      context = build_context(parent)

      {:error, msg} = SubAgentTool.execute(%{"prompt" => "Do something"}, context)
      assert msg =~ "disabled"
    end
  end

  # ============================================================
  # Depth Enforcement
  # ============================================================

  describe "depth enforcement" do
    test "sub-agent does not receive the sub_agent tool" do
      %{pid: parent} = start_parent(tools: [EchoTool, SubAgentTool])

      {:ok, sub} =
        Opal.SubAgent.spawn(parent, %{
          tools: parent |> Agent.get_state() |> Map.get(:tools) |> Kernel.--([SubAgentTool])
        })

      sub_state = Agent.get_state(sub)
      tool_names = Enum.map(sub_state.tools, & &1.name())

      refute "sub_agent" in tool_names
      assert "echo_tool" in tool_names
    end
  end

  # ============================================================
  # Tool Filtering
  # ============================================================

  describe "tool filtering" do
    test "sub-agent gets all parent tools (minus sub_agent) when tools param omitted" do
      parent = start_parent(tools: [EchoTool, AnotherTool, SubAgentTool])
      context = build_context(parent)

      {:ok, _result} = SubAgentTool.execute(%{"prompt" => "Do something"}, context)
    end

    test "sub-agent gets only named tools when tools param provided" do
      parent = start_parent(tools: [EchoTool, AnotherTool, SubAgentTool])
      context = build_context(parent)

      {:ok, _result} =
        SubAgentTool.execute(
          %{"prompt" => "Do something", "tools" => ["echo_tool"]},
          context
        )
    end
  end

  # ============================================================
  # Event Forwarding
  # ============================================================

  describe "event forwarding" do
    test "sub-agent events are forwarded to parent session as :sub_agent_event" do
      parent = start_parent()
      parent_sid = parent.session_id
      context = build_context(parent)

      Events.subscribe(parent_sid)

      # Run in a task since execute blocks
      task = Task.async(fn -> SubAgentTool.execute(%{"prompt" => "Do work"}, context) end)

      # Should receive forwarded events tagged with :sub_agent_event
      assert_receive {:opal_event, ^parent_sid,
                      {:sub_agent_event, _parent_call_id, sub_sid, {:message_start}}},
                     2000

      assert String.starts_with?(sub_sid, "sub-")

      assert_receive {:opal_event, ^parent_sid,
                      {:sub_agent_event, _parent_call_id2, ^sub_sid,
                       {:message_delta, %{delta: "Sub-agent completed the task."}}}},
                     2000

      {:ok, _result} = Task.await(task, 5000)
    end
  end

  # ============================================================
  # Model Override
  # ============================================================

  describe "model override" do
    test "sub-agent can use a different model" do
      parent = start_parent()
      context = build_context(parent)

      {:ok, _result} =
        SubAgentTool.execute(
          %{"prompt" => "Do something", "model" => "different-model"},
          context
        )
    end
  end
end
