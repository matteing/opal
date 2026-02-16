defmodule Opal.Provider.MacroTest do
  use ExUnit.Case, async: true

  describe "use Opal.Provider" do
    defmodule TestProvider do
      use Opal.Provider,
        name: :test_provider,
        models: ["model-a", "model-b"]

      @impl true
      def stream(_model, _messages, _tools, _opts) do
        {:ok, %{}}
      end

      @impl true
      def parse_stream_event(_data), do: []

      @impl true
      def convert_messages(_model, messages), do: messages
    end

    test "exposes provider name" do
      assert TestProvider.__opal_provider_name__() == :test_provider
    end

    test "exposes model list" do
      assert TestProvider.__opal_provider_models__() == ["model-a", "model-b"]
    end

    test "provides default convert_tools/1" do
      defmodule FakeTool do
        @behaviour Opal.Tool
        def name, do: "fake"
        def description, do: "A fake tool"
        def parameters, do: %{"type" => "object", "properties" => %{}}
        def execute(_args, _ctx), do: {:ok, "ok"}
      end

      [tool_def] = TestProvider.convert_tools([FakeTool])
      assert tool_def.type == "function"
      assert tool_def.function.name == "fake"
    end

    test "implements Opal.Provider behaviour" do
      behaviours =
        TestProvider.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Opal.Provider in behaviours
    end
  end

  describe "convert_tools/1 is overridable" do
    defmodule CustomFormatProvider do
      use Opal.Provider,
        name: :custom,
        models: []

      @impl true
      def stream(_model, _messages, _tools, _opts), do: {:ok, %{}}

      @impl true
      def parse_stream_event(_data), do: []

      @impl true
      def convert_messages(_model, messages), do: messages

      @impl true
      def convert_tools(tools) do
        Enum.map(tools, fn tool -> %{custom: tool.name()} end)
      end
    end

    test "custom convert_tools/1 is used" do
      defmodule AnotherFakeTool do
        @behaviour Opal.Tool
        def name, do: "another"
        def description, do: "Another"
        def parameters, do: %{}
        def execute(_args, _ctx), do: {:ok, "ok"}
      end

      assert [%{custom: "another"}] = CustomFormatProvider.convert_tools([AnotherFakeTool])
    end
  end

  describe "default models list" do
    defmodule MinimalProvider do
      use Opal.Provider, name: :minimal

      @impl true
      def stream(_model, _messages, _tools, _opts), do: {:ok, %{}}

      @impl true
      def parse_stream_event(_data), do: []

      @impl true
      def convert_messages(_model, messages), do: messages
    end

    test "models defaults to empty list" do
      assert MinimalProvider.__opal_provider_models__() == []
    end
  end
end
