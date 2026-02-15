defmodule Opal.Config.CopilotTest do
  use ExUnit.Case, async: true

  alias Opal.Config.Copilot

  describe "new/1" do
    test "builds from keyword list" do
      c = Copilot.new(client_id: "custom", domain: "ghe.example.com")
      assert c.client_id == "custom"
      assert c.domain == "ghe.example.com"
    end

    test "builds from map" do
      c = Copilot.new(%{domain: "enterprise.github.com"})
      assert c.domain == "enterprise.github.com"
      # Default client_id preserved
      assert c.client_id == "Iv1.b507a08c87ecfe98"
    end

    test "defaults" do
      c = %Copilot{}
      assert c.client_id == "Iv1.b507a08c87ecfe98"
      assert c.domain == "github.com"
    end
  end
end

defmodule Opal.Config.FeaturesTest do
  use ExUnit.Case, async: true

  alias Opal.Config.Features

  describe "new/1" do
    test "enables all subsystems by default" do
      f = Features.new(%{})
      assert f.sub_agents.enabled == true
      assert f.context.enabled == true
      assert f.skills.enabled == true
      assert f.mcp.enabled == true
      assert f.debug.enabled == false
    end

    test "disables subsystems via override" do
      f = Features.new(%{sub_agents: %{enabled: false}})
      assert f.sub_agents.enabled == false
      # Others unchanged
      assert f.skills.enabled == true
    end

    test "merges subsystem options" do
      f = Features.new(%{context: %{enabled: true, filenames: ["CUSTOM.md"]}})
      assert f.context.enabled == true
      assert f.context.filenames == ["CUSTOM.md"]
    end

    test "enables debug feature" do
      f = Features.new(%{debug: %{enabled: true}})
      assert f.debug.enabled == true
    end

    test "handles MCP config with servers" do
      servers = [%{name: "test", command: "node"}]
      f = Features.new(%{mcp: %{enabled: true, servers: servers}})
      assert f.mcp.enabled == true
      assert f.mcp.servers == servers
    end
  end
end

defmodule Opal.ConfigTest2 do
  use ExUnit.Case, async: true

  alias Opal.Config

  describe "new/1" do
    test "builds with default values" do
      c = Config.new()
      assert c.auto_save == true
      assert c.auto_title == true
      assert is_binary(c.data_dir)
      assert c.shell in [:sh, :bash, :zsh, :cmd, :powershell]
    end

    test "accepts overrides" do
      c = Config.new(%{shell: :zsh, auto_save: false})
      assert c.shell == :zsh
      assert c.auto_save == false
    end

    test "accepts keyword list overrides" do
      c = Config.new(shell: :bash)
      assert c.shell == :bash
    end

    test "ignores nil override values" do
      c = Config.new(%{shell: nil})
      # Should still resolve to platform default, not nil
      assert c.shell != nil
    end

    test "copilot override with keyword list" do
      c = Config.new(%{copilot: [domain: "ghe.example.com"]})
      assert c.copilot.domain == "ghe.example.com"
    end

    test "features override with map" do
      c = Config.new(%{features: %{debug: %{enabled: true}}})
      assert c.features.debug.enabled == true
    end
  end

  describe "derived paths" do
    test "data_dir returns expanded path" do
      c = Config.new(%{data_dir: "/tmp/opal-test"})
      assert Config.data_dir(c) == "/tmp/opal-test"
    end

    test "sessions_dir is under data_dir" do
      c = Config.new(%{data_dir: "/tmp/opal-test"})
      assert Config.sessions_dir(c) == "/tmp/opal-test/sessions"
    end

    test "auth_file is under data_dir" do
      c = Config.new(%{data_dir: "/tmp/opal-test"})
      assert Config.auth_file(c) == "/tmp/opal-test/auth.json"
    end

    test "logs_dir is under data_dir" do
      c = Config.new(%{data_dir: "/tmp/opal-test"})
      assert Config.logs_dir(c) == "/tmp/opal-test/logs"
    end
  end

  describe "default_data_dir/0" do
    test "returns a non-empty string" do
      dir = Config.default_data_dir()
      assert is_binary(dir)
      assert String.length(dir) > 0
    end
  end
end
