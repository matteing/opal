defmodule OpalTest do
  use ExUnit.Case, async: false

  # --- Test Provider ---
  # Reuses the same mock provider pattern from AgentTest

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

        events = [
          sse_line("response.output_item.added", %{
            "item" => %{"type" => "message", "id" => "item_1"}
          }),
          sse_line("response.output_text.delta", %{"delta" => "Test"}),
          sse_line("response.output_text.delta", %{"delta" => " response"}),
          sse_line("response.output_text.done", %{"text" => "Test response"}),
          sse_line("response.completed", %{
            "response" => %{"id" => "resp_1", "status" => "completed", "usage" => %{}}
          })
        ]

        for event <- events do
          send(caller, {ref, {:data, event}})
          Process.sleep(1)
        end

        send(caller, {ref, :done})
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

    defp sse_line(type, fields) do
      data = Map.merge(%{"type" => type}, fields) |> Jason.encode!()
      "data: #{data}\n"
    end
  end

  defp start_test_session(opts \\ %{}) do
    config =
      Map.merge(
        %{
          model: {:test, "test-model"},
          working_dir: System.tmp_dir!(),
          system_prompt: "Test prompt",
          provider: TestProvider
        },
        opts
      )

    Opal.start_session(config)
  end

  # ============================================================
  # Public API Tests
  # ============================================================

  describe "start_session/1" do
    test "starts an agent and returns {:ok, pid}" do
      assert {:ok, pid} = start_test_session()
      assert Process.alive?(pid)
      Opal.stop_session(pid)
    end

    test "started agent has correct configuration" do
      {:ok, pid} = start_test_session()
      state = Opal.Agent.get_state(pid)

      assert state.model.provider == :test
      assert state.model.id == "test-model"
      assert state.system_prompt == "Test prompt"
      Opal.stop_session(pid)
    end
  end

  describe "prompt/2" do
    test "delegates to Agent.prompt and returns :ok" do
      {:ok, pid} = start_test_session()
      assert :ok = Opal.prompt(pid, "Hello")
      Opal.stop_session(pid)
    end
  end

  describe "stop_session/1" do
    test "terminates the agent" do
      {:ok, pid} = start_test_session()
      assert Process.alive?(pid)

      assert :ok = Opal.stop_session(pid)

      # Give it a moment to terminate
      Process.sleep(50)
      refute Process.alive?(pid)
    end
  end

  describe "prompt_sync/2" do
    test "sends a prompt and waits for the response text" do
      {:ok, pid} = start_test_session()

      assert {:ok, response} = Opal.prompt_sync(pid, "Hello", 5000)
      assert response == "Test response"

      Opal.stop_session(pid)
    end

    test "returns accumulated text from deltas" do
      {:ok, pid} = start_test_session()

      {:ok, response} = Opal.prompt_sync(pid, "Hi", 5000)
      # The TestProvider sends "Test" and " response" as deltas
      assert response == "Test response"

      Opal.stop_session(pid)
    end
  end

  describe "steer/2" do
    test "delegates to Agent.steer" do
      {:ok, pid} = start_test_session()
      assert :ok = Opal.steer(pid, "Steer this")
      Opal.stop_session(pid)
    end
  end

  describe "follow_up/2" do
    test "delegates to Agent.follow_up" do
      {:ok, pid} = start_test_session()
      assert :ok = Opal.follow_up(pid, "Follow up")
      Opal.stop_session(pid)
    end
  end

  describe "abort/1" do
    test "delegates to Agent.abort" do
      {:ok, pid} = start_test_session()
      assert :ok = Opal.abort(pid)
      Opal.stop_session(pid)
    end
  end
end
