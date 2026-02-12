defmodule Opal.MCP.IntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :mcp

  # Minimal provider that does nothing (no streaming needed for these tests)
  defmodule NoopProvider do
    @behaviour Opal.Provider

    @impl true
    def stream(_model, _messages, _tools, _opts \\ []) do
      ref = make_ref()
      caller = self()

      resp = %Req.Response{
        status: 200,
        body: %Req.Response.Async{pid: caller, ref: ref}
      }

      {:ok, resp}
    end

    @impl true
    def parse_stream_event(_data), do: []

    @impl true
    def convert_messages(_model, messages), do: messages

    @impl true
    def convert_tools(tools), do: tools
  end

  describe "SessionServer with MCP config" do
    setup do
      dir = Path.join(System.tmp_dir!(), "opal_mcp_int_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "session starts without MCP servers when no config files exist", %{dir: dir} do
      {:ok, session_server} =
        Opal.SessionServer.start_link(
          session_id: "mcp_test_#{:rand.uniform(100_000)}",
          model: Opal.Model.new(:copilot, "test-model"),
          working_dir: dir,
          tools: [],
          provider: NoopProvider,
          config: Opal.Config.new(%{features: %{mcp: %{servers: [], config_files: []}}})
        )

      agent = Opal.SessionServer.agent(session_server)
      state = Opal.Agent.get_state(agent)

      assert state.mcp_servers == []
      assert state.mcp_supervisor == nil

      Supervisor.stop(session_server)
    end

    test "session discovers MCP config from .opal/mcp.json", %{dir: dir} do
      opal_dir = Path.join(dir, ".opal")
      File.mkdir_p!(opal_dir)

      content =
        Jason.encode!(%{
          "servers" => %{
            "test_server" => %{
              "command" => "cat",
              "args" => []
            }
          }
        })

      File.write!(Path.join(opal_dir, "mcp.json"), content)

      session_id = "mcp_discover_test_#{:rand.uniform(100_000)}"

      {:ok, session_server} =
        Opal.SessionServer.start_link(
          session_id: session_id,
          model: Opal.Model.new(:copilot, "test-model"),
          working_dir: dir,
          tools: [],
          provider: NoopProvider,
          config: Opal.Config.new(%{features: %{mcp: %{servers: [], config_files: []}}})
        )

      agent = Opal.SessionServer.agent(session_server)
      state = Opal.Agent.get_state(agent)

      # MCP servers should be discovered from config file
      assert length(state.mcp_servers) == 1
      assert hd(state.mcp_servers).name == "test_server"

      # MCP supervisor should have been started (registered via Registry)
      assert [{_pid, _}] = Registry.lookup(Opal.Registry, {:mcp_sup, session_id})

      Supervisor.stop(session_server)
    end

    test "explicit mcp servers in config are used", %{dir: dir} do
      session_id = "mcp_explicit_test_#{:rand.uniform(100_000)}"

      explicit_servers = [
        %{name: :explicit_server, transport: {:stdio, command: "cat", args: []}}
      ]

      {:ok, session_server} =
        Opal.SessionServer.start_link(
          session_id: session_id,
          model: Opal.Model.new(:copilot, "test-model"),
          working_dir: dir,
          tools: [],
          provider: NoopProvider,
          config: Opal.Config.new(%{features: %{mcp: %{servers: explicit_servers, config_files: []}}})
        )

      agent = Opal.SessionServer.agent(session_server)
      state = Opal.Agent.get_state(agent)

      assert length(state.mcp_servers) == 1
      assert hd(state.mcp_servers).name == :explicit_server

      Supervisor.stop(session_server)
    end

    test "explicit servers override discovered ones with same name", %{dir: dir} do
      # Create a config file with server named "myserver"
      opal_dir = Path.join(dir, ".opal")
      File.mkdir_p!(opal_dir)

      content =
        Jason.encode!(%{
          "servers" => %{
            "myserver" => %{
              "command" => "cat",
              "args" => ["/dev/null"]
            }
          }
        })

      File.write!(Path.join(opal_dir, "mcp.json"), content)

      # Also pass explicit server with same name but different args
      session_id = "mcp_override_test_#{:rand.uniform(100_000)}"

      explicit_servers = [
        %{name: :myserver, transport: {:stdio, command: "cat", args: []}}
      ]

      {:ok, session_server} =
        Opal.SessionServer.start_link(
          session_id: session_id,
          model: Opal.Model.new(:copilot, "test-model"),
          working_dir: dir,
          tools: [],
          provider: NoopProvider,
          config: Opal.Config.new(%{features: %{mcp: %{servers: explicit_servers, config_files: []}}})
        )

      agent = Opal.SessionServer.agent(session_server)
      state = Opal.Agent.get_state(agent)

      # Only one server — explicit takes priority
      assert length(state.mcp_servers) == 1
      assert hd(state.mcp_servers).name == :myserver

      {:stdio, opts} = hd(state.mcp_servers).transport
      # Explicit has empty args, discovered has ["/dev/null"]
      assert Keyword.get(opts, :args) == []

      Supervisor.stop(session_server)
    end
  end
end
