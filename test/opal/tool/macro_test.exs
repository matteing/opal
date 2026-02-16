defmodule Opal.Tool.MacroTest do
  use ExUnit.Case, async: true

  describe "use Opal.Tool" do
    defmodule FullOptsTool do
      use Opal.Tool,
        name: "custom_name",
        description: "A custom tool",
        group: :testing

      @impl true
      def parameters do
        %{
          "type" => "object",
          "properties" => %{
            "input" => %{"type" => "string", "description" => "Input"}
          },
          "required" => ["input"]
        }
      end

      @impl true
      def execute(%{"input" => input}, _context) do
        {:ok, "Got: #{input}"}
      end
    end

    test "name/0 returns the explicit name" do
      assert FullOptsTool.name() == "custom_name"
    end

    test "description/0 returns the explicit description" do
      assert FullOptsTool.description() == "A custom tool"
    end

    test "parameters/0 returns the schema" do
      assert %{"type" => "object"} = FullOptsTool.parameters()
    end

    test "execute/2 works" do
      assert {:ok, "Got: hi"} = FullOptsTool.execute(%{"input" => "hi"}, %{})
    end

    test "implements Opal.Tool behaviour" do
      behaviours =
        FullOptsTool.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Opal.Tool in behaviours
    end
  end

  describe "auto-derived name" do
    defmodule AutoNameTool do
      use Opal.Tool,
        description: "Auto-named tool"

      @impl true
      def parameters, do: %{"type" => "object", "properties" => %{}}

      @impl true
      def execute(_args, _ctx), do: {:ok, "ok"}
    end

    test "derives name from module name" do
      assert AutoNameTool.name() == "auto_name_tool"
    end
  end

  describe "overridable callbacks" do
    defmodule OverriddenTool do
      use Opal.Tool,
        name: "base_name",
        description: "Base description"

      @impl true
      def name, do: "overridden_name"

      @impl true
      def parameters, do: %{"type" => "object", "properties" => %{}}

      @impl true
      def execute(_args, _ctx), do: {:ok, "ok"}
    end

    test "name/0 can be overridden" do
      assert OverriddenTool.name() == "overridden_name"
    end
  end

  describe "compile-time validation" do
    test "raises when parameters/0 is missing" do
      assert_raise CompileError, ~r/must implement parameters\/0/, fn ->
        Code.compile_string("""
        defmodule MissingParamsTool do
          use Opal.Tool, description: "bad"
          def execute(_args, _ctx), do: {:ok, "ok"}
        end
        """)
      end
    end

    test "raises when execute/2 is missing" do
      assert_raise CompileError, ~r/must implement execute\/2/, fn ->
        Code.compile_string("""
        defmodule MissingExecuteTool do
          use Opal.Tool, description: "bad"
          def parameters, do: %{"type" => "object", "properties" => %{}}
        end
        """)
      end
    end
  end
end
