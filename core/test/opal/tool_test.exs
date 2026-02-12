defmodule Opal.ToolTest do
  use ExUnit.Case, async: true

  # A test module implementing the Opal.Tool behaviour
  defmodule EchoTool do
    @behaviour Opal.Tool

    @impl true
    def name, do: "echo"

    @impl true
    def description, do: "Echoes the input back"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "input" => %{"type" => "string", "description" => "The input to echo"}
        },
        "required" => ["input"]
      }
    end

    @impl true
    def execute(%{"input" => input}, _context) do
      {:ok, "Echo: #{input}"}
    end
  end

  # Validates that a module implementing Opal.Tool compiles and works
  describe "Opal.Tool behaviour" do
    test "implementing module compiles successfully" do
      assert Code.ensure_loaded?(EchoTool)
    end

    test "name/0 returns the tool name" do
      assert EchoTool.name() == "echo"
    end

    test "description/0 returns the description" do
      assert EchoTool.description() == "Echoes the input back"
    end

    test "parameters/0 returns a JSON Schema map" do
      params = EchoTool.parameters()
      assert is_map(params)
      assert params["type"] == "object"
      assert Map.has_key?(params, "properties")
    end

    test "execute/2 returns {:ok, result} on success" do
      assert {:ok, "Echo: hello"} = EchoTool.execute(%{"input" => "hello"}, %{})
    end
  end

  # Validates that the behaviour defines the expected callbacks
  describe "callback definitions" do
    test "Opal.Tool exports behaviour_info" do
      callbacks = Opal.Tool.behaviour_info(:callbacks)
      assert {:name, 0} in callbacks
      assert {:description, 0} in callbacks
      assert {:parameters, 0} in callbacks
      assert {:execute, 2} in callbacks
    end
  end
end
