defmodule Opal.MCP.ConfigTest do
  use ExUnit.Case, async: true

  alias Opal.MCP.Config

  @moduletag :mcp

  describe "parse_server/2" do
    test "parses stdio server with command and args" do
      config = %{
        "command" => "npx",
        "args" => ["-y", "@modelcontextprotocol/server-memory"]
      }

      result = Config.parse_server("memory", config)

      assert %{name: "memory", transport: {:stdio, opts}} = result
      assert Keyword.get(opts, :command) == "npx"
      assert Keyword.get(opts, :args) == ["-y", "@modelcontextprotocol/server-memory"]
    end

    test "parses stdio server with explicit type" do
      config = %{
        "type" => "stdio",
        "command" => "python",
        "args" => ["server.py"]
      }

      result = Config.parse_server("db", config)

      assert %{name: "db", transport: {:stdio, opts}} = result
      assert Keyword.get(opts, :command) == "python"
      assert Keyword.get(opts, :args) == ["server.py"]
    end

    test "parses stdio server with env" do
      config = %{
        "command" => "npx",
        "args" => ["server"],
        "env" => %{"API_KEY" => "secret123"}
      }

      result = Config.parse_server("api", config)

      assert %{name: "api", transport: {:stdio, opts}} = result
      assert Keyword.get(opts, :env) == %{"API_KEY" => "secret123"}
    end

    test "parses http server" do
      config = %{
        "type" => "http",
        "url" => "https://api.example.com/mcp"
      }

      result = Config.parse_server("example", config)

      assert %{name: "example", transport: {:streamable_http, opts}} = result
      assert Keyword.get(opts, :url) == "https://api.example.com/mcp"
    end

    test "parses sse server" do
      config = %{
        "type" => "sse",
        "url" => "http://localhost:3000/sse"
      }

      result = Config.parse_server("local", config)

      assert %{name: "local", transport: {:sse, opts}} = result
      assert Keyword.get(opts, :url) == "http://localhost:3000/sse"
    end

    test "parses http server with headers" do
      config = %{
        "type" => "http",
        "url" => "https://api.example.com/mcp",
        "headers" => %{"Authorization" => "Bearer token123"}
      }

      result = Config.parse_server("auth", config)

      assert %{name: "auth", transport: {:streamable_http, opts}} = result
      assert Keyword.get(opts, :headers) == [{"Authorization", "Bearer token123"}]
    end

    test "returns nil for invalid config" do
      assert Config.parse_server("bad", %{}) == nil
      assert Config.parse_server("bad", %{"invalid" => true}) == nil
    end

    test "returns nil for non-string name" do
      assert Config.parse_server(123, %{"command" => "npx"}) == nil
    end
  end

  describe "parse_file/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "opal_mcp_config_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "parses valid mcp.json with multiple servers", %{dir: dir} do
      path = Path.join(dir, "mcp.json")

      content =
        Jason.encode!(%{
          "servers" => %{
            "memory" => %{
              "command" => "npx",
              "args" => ["-y", "@modelcontextprotocol/server-memory"]
            },
            "github" => %{
              "type" => "http",
              "url" => "https://api.githubcopilot.com/mcp"
            }
          }
        })

      File.write!(path, content)

      result = Config.parse_file(path)

      assert length(result) == 2
      names = Enum.map(result, & &1.name) |> Enum.sort()
      assert names == ["github", "memory"]
    end

    test "returns empty list for non-existent file" do
      assert Config.parse_file("/nonexistent/mcp.json") == []
    end

    test "returns empty list for invalid JSON", %{dir: dir} do
      path = Path.join(dir, "mcp.json")
      File.write!(path, "not json")
      assert Config.parse_file(path) == []
    end

    test "returns empty list for JSON without servers key", %{dir: dir} do
      path = Path.join(dir, "mcp.json")
      File.write!(path, Jason.encode!(%{"other" => "data"}))
      assert Config.parse_file(path) == []
    end

    test "skips invalid server entries", %{dir: dir} do
      path = Path.join(dir, "mcp.json")

      content =
        Jason.encode!(%{
          "servers" => %{
            "good" => %{"command" => "npx", "args" => ["server"]},
            "bad" => %{"invalid" => true}
          }
        })

      File.write!(path, content)

      result = Config.parse_file(path)
      assert length(result) == 1
      assert hd(result).name == "good"
    end
  end

  describe "discover/2" do
    setup do
      dir = Path.join(System.tmp_dir!(), "opal_mcp_discover_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "discovers servers from .vscode/mcp.json", %{dir: dir} do
      vscode_dir = Path.join(dir, ".vscode")
      File.mkdir_p!(vscode_dir)

      content =
        Jason.encode!(%{
          "servers" => %{
            "memory" => %{"command" => "npx", "args" => ["server-memory"]}
          }
        })

      File.write!(Path.join(vscode_dir, "mcp.json"), content)

      result = Config.discover(dir)
      assert length(result) == 1
      assert hd(result).name == "memory"
    end

    test "discovers servers from .opal/mcp.json", %{dir: dir} do
      opal_dir = Path.join(dir, ".opal")
      File.mkdir_p!(opal_dir)

      content =
        Jason.encode!(%{
          "servers" => %{
            "db" => %{"command" => "python", "args" => ["db_server.py"]}
          }
        })

      File.write!(Path.join(opal_dir, "mcp.json"), content)

      result = Config.discover(dir)
      assert length(result) == 1
      assert hd(result).name == "db"
    end

    test "discovers servers from .github/mcp.json", %{dir: dir} do
      github_dir = Path.join(dir, ".github")
      File.mkdir_p!(github_dir)

      content =
        Jason.encode!(%{
          "servers" => %{
            "gh" => %{"type" => "http", "url" => "https://api.github.com/mcp"}
          }
        })

      File.write!(Path.join(github_dir, "mcp.json"), content)

      result = Config.discover(dir)
      assert length(result) == 1
      assert hd(result).name == "gh"
    end

    test "discovers servers from .mcp.json", %{dir: dir} do
      content =
        Jason.encode!(%{
          "servers" => %{
            "root" => %{"command" => "node", "args" => ["server.js"]}
          }
        })

      File.write!(Path.join(dir, ".mcp.json"), content)

      result = Config.discover(dir)
      assert length(result) == 1
      assert hd(result).name == "root"
    end

    test "deduplicates by name (first wins)", %{dir: dir} do
      # .vscode has higher priority than .opal
      vscode_dir = Path.join(dir, ".vscode")
      opal_dir = Path.join(dir, ".opal")
      File.mkdir_p!(vscode_dir)
      File.mkdir_p!(opal_dir)

      vscode_content =
        Jason.encode!(%{
          "servers" => %{
            "myserver" => %{"command" => "npx", "args" => ["v1"]}
          }
        })

      opal_content =
        Jason.encode!(%{
          "servers" => %{
            "myserver" => %{"command" => "npx", "args" => ["v2"]}
          }
        })

      File.write!(Path.join(vscode_dir, "mcp.json"), vscode_content)
      File.write!(Path.join(opal_dir, "mcp.json"), opal_content)

      result = Config.discover(dir)
      assert length(result) == 1
      assert hd(result).name == "myserver"

      {:stdio, opts} = hd(result).transport
      assert Keyword.get(opts, :args) == ["v1"]
    end

    test "merges servers from multiple files", %{dir: dir} do
      vscode_dir = Path.join(dir, ".vscode")
      File.mkdir_p!(vscode_dir)

      vscode_content =
        Jason.encode!(%{
          "servers" => %{"server_a" => %{"command" => "npx", "args" => ["a"]}}
        })

      root_content =
        Jason.encode!(%{
          "servers" => %{"server_b" => %{"command" => "npx", "args" => ["b"]}}
        })

      File.write!(Path.join(vscode_dir, "mcp.json"), vscode_content)
      File.write!(Path.join(dir, ".mcp.json"), root_content)

      result = Config.discover(dir)
      names = Enum.map(result, & &1.name) |> Enum.sort()
      assert names == ["server_a", "server_b"]
    end

    test "handles extra_files option", %{dir: dir} do
      custom_path = Path.join(dir, "custom/mcp.json")
      File.mkdir_p!(Path.dirname(custom_path))

      content =
        Jason.encode!(%{
          "servers" => %{
            "custom" => %{"command" => "custom-server"}
          }
        })

      File.write!(custom_path, content)

      result = Config.discover(dir, extra_files: ["custom/mcp.json"])
      assert length(result) == 1
      assert hd(result).name == "custom"
    end

    test "returns empty list when no config files exist", %{dir: dir} do
      assert Config.discover(dir) == []
    end
  end

  describe "env variable resolution" do
    test "resolves ${input:...} from environment" do
      System.put_env("API_KEY", "resolved_value")

      config = %{
        "command" => "npx",
        "args" => ["server"],
        "env" => %{"KEY" => "${input:api_key}"}
      }

      result = Config.parse_server("test", config)
      {:stdio, opts} = result.transport
      assert Keyword.get(opts, :env) == %{"KEY" => "resolved_value"}
    after
      System.delete_env("API_KEY")
    end

    test "keeps placeholder when env var not set" do
      System.delete_env("MISSING_KEY")

      config = %{
        "command" => "npx",
        "args" => ["server"],
        "env" => %{"KEY" => "${input:missing_key}"}
      }

      result = Config.parse_server("test", config)
      {:stdio, opts} = result.transport
      assert Keyword.get(opts, :env) == %{"KEY" => "${input:missing_key}"}
    end
  end
end
