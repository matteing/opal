defmodule Opal.SubAgentTest do
  use ExUnit.Case, async: false

  alias Opal.Agent
  alias Opal.Provider.Model
  alias Opal.SubAgent

  # Reuse the TestProvider from AgentTest
  defmodule TestProvider do
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
        send_text(caller, ref, "Sub-agent response!")
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

    defp send_text(caller, ref, text) do
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
      system_prompt: Keyword.get(opts, :system_prompt, "You are a parent agent."),
      tools: Keyword.get(opts, :tools, []),
      provider: TestProvider,
      config: config,
      tool_supervisor: tool_sup,
      sub_agent_supervisor: sub_agent_sup
    ]

    {:ok, pid} = Agent.start_link(agent_opts)
    %{pid: pid, session_id: session_id}
  end

  # ============================================================
  # Spawn
  # ============================================================

  describe "spawn/2" do
    test "spawns a sub-agent from a parent agent" do
      %{pid: parent} = start_parent()

      {:ok, sub} = SubAgent.spawn(parent)
      assert Process.alive?(sub)
    end

    test "sub-agent inherits parent's config by default" do
      %{pid: parent} = start_parent(system_prompt: "Inherited prompt")

      {:ok, sub} = SubAgent.spawn(parent)
      sub_state = Agent.get_state(sub)

      assert sub_state.system_prompt == "Inherited prompt"
      assert sub_state.model.provider == :test
      assert sub_state.model.id == "test-model"
      assert sub_state.working_dir == System.tmp_dir!()
    end

    test "sub-agent overrides system_prompt" do
      %{pid: parent} = start_parent()

      {:ok, sub} = SubAgent.spawn(parent, %{system_prompt: "Custom sub prompt"})
      sub_state = Agent.get_state(sub)

      assert sub_state.system_prompt == "Custom sub prompt"
    end

    test "sub-agent overrides model" do
      %{pid: parent} = start_parent()

      {:ok, sub} = SubAgent.spawn(parent, %{model: {:test, "different-model"}})
      sub_state = Agent.get_state(sub)

      assert sub_state.model.id == "different-model"
    end

    test "model override auto-selects matching provider module" do
      %{pid: parent} = start_parent()

      {:ok, sub} = SubAgent.spawn(parent, %{model: {:copilot, "gpt-5"}})
      sub_state = Agent.get_state(sub)

      assert sub_state.provider == Opal.Provider.Copilot
    end

    test "explicit provider override wins over model-derived provider" do
      %{pid: parent} = start_parent()

      {:ok, sub} =
        SubAgent.spawn(parent, %{model: {:copilot, "gpt-5"}, provider: TestProvider})

      sub_state = Agent.get_state(sub)
      assert sub_state.provider == TestProvider
    end

    test "sub-agent overrides working_dir" do
      %{pid: parent} = start_parent()

      {:ok, sub} = SubAgent.spawn(parent, %{working_dir: "/tmp/sub"})
      sub_state = Agent.get_state(sub)

      assert sub_state.working_dir == "/tmp/sub"
    end

    test "sub-agent has unique session_id starting with sub-" do
      %{pid: parent} = start_parent()

      {:ok, sub} = SubAgent.spawn(parent)
      sub_state = Agent.get_state(sub)

      assert String.starts_with?(sub_state.session_id, "sub-")
    end

    test "multiple sub-agents can be spawned from same parent" do
      %{pid: parent} = start_parent()

      {:ok, sub1} = SubAgent.spawn(parent)
      {:ok, sub2} = SubAgent.spawn(parent)
      {:ok, sub3} = SubAgent.spawn(parent)

      assert Process.alive?(sub1)
      assert Process.alive?(sub2)
      assert Process.alive?(sub3)

      # Each has its own session_id
      s1 = Agent.get_state(sub1).session_id
      s2 = Agent.get_state(sub2).session_id
      s3 = Agent.get_state(sub3).session_id
      assert s1 != s2
      assert s2 != s3
    end

    test "returns error when sub-agents are disabled in config" do
      config = Opal.Config.new(%{features: %{sub_agents: false}})
      %{pid: parent} = start_parent(config: config)

      assert {:error, :sub_agents_disabled} = SubAgent.spawn(parent)
    end
  end

  # ============================================================
  # Run
  # ============================================================

  describe "run/2" do
    test "sends prompt and collects response synchronously" do
      %{pid: parent} = start_parent()

      {:ok, sub} = SubAgent.spawn(parent)
      {:ok, response} = SubAgent.run(sub, "Do something")

      assert response == "Sub-agent response!"
    end

    test "sub-agent is idle after run completes" do
      %{pid: parent} = start_parent()

      {:ok, sub} = SubAgent.spawn(parent)
      {:ok, _response} = SubAgent.run(sub, "Do something")

      state = Agent.get_state(sub)
      assert state.status == :idle
    end

    test "multiple sub-agents can run in parallel" do
      %{pid: parent} = start_parent()

      {:ok, sub1} = SubAgent.spawn(parent)
      {:ok, sub2} = SubAgent.spawn(parent)
      {:ok, sub3} = SubAgent.spawn(parent)

      # Run all three in parallel using Task
      tasks = [
        Task.async(fn -> SubAgent.run(sub1, "Task 1") end),
        Task.async(fn -> SubAgent.run(sub2, "Task 2") end),
        Task.async(fn -> SubAgent.run(sub3, "Task 3") end)
      ]

      results = Task.await_many(tasks, 5000)

      assert [
               {:ok, "Sub-agent response!"},
               {:ok, "Sub-agent response!"},
               {:ok, "Sub-agent response!"}
             ] =
               results
    end
  end

  # ============================================================
  # Stop
  # ============================================================

  describe "stop/1" do
    test "stops a sub-agent" do
      %{pid: parent} = start_parent()

      {:ok, sub} = SubAgent.spawn(parent)
      assert Process.alive?(sub)

      :ok = SubAgent.stop(sub)
      refute Process.alive?(sub)
    end

    test "stopping a sub-agent does not affect parent" do
      %{pid: parent} = start_parent()

      {:ok, sub} = SubAgent.spawn(parent)
      :ok = SubAgent.stop(sub)

      assert Process.alive?(parent)
    end

    test "stopping a sub-agent does not affect siblings" do
      %{pid: parent} = start_parent()

      {:ok, sub1} = SubAgent.spawn(parent)
      {:ok, sub2} = SubAgent.spawn(parent)

      :ok = SubAgent.stop(sub1)

      refute Process.alive?(sub1)
      assert Process.alive?(sub2)
    end
  end
end
