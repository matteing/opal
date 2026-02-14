defmodule Opal.MixProject do
  use Mix.Project

  @version "0.1.10"
  @source_url "https://github.com/scohen/opal"

  def project do
    [
      app: :opal,
      version: @version,
      config_path: "config/config.exs",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
      name: "Opal",
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: @source_url,
      test_coverage: [
        ignore_modules: [
          # Application bootstrap — no unit-testable logic
          Opal.Application,
          # Mix task — tested via CLI integration, not unit tests
          Mix.Tasks.Opal.Gen.JsonSchema,
          # I/O-bound stdio transport — tested via RPC integration tests
          Opal.RPC.Stdio,
          # MCP runtime discovery — requires live MCP servers
          Opal.MCP.Resources,
          # MCP client/bridge — requires live MCP servers to test
          Opal.MCP.Client,
          Opal.MCP.Bridge,
          # ReqLLM provider — stream/4 and private helpers require ReqLLM
          # mocking; convert_messages tested in llm_test.exs
          Opal.Provider.LLM
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Opal.Application, []}
    ]
  end

  defp description do
    "An OTP-native coding agent SDK. Build, orchestrate, and observe AI coding agents with Elixir supervision trees, streaming events, and a JSON-RPC 2.0 interface."
  end

  defp package do
    [
      name: "opal",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Architecture" => "#{@source_url}/blob/main/ARCHITECTURE.md"
      },
      files: ~w(
        lib config mix.exs mix.lock
        README.md LICENSE
      )
    ]
  end

  defp docs do
    [
      main: "Opal",
      source_ref: "v#{@version}",
      extras: [
        "README.md": [title: "Overview"]
      ],
      groups_for_modules: [
        "Public API": [
          Opal,
          Opal.Agent,
          Opal.Config,
          Opal.Events,
          Opal.Model,
          Opal.Session
        ],
        "RPC Server": [
          Opal.RPC,
          Opal.RPC.Handler,
          Opal.RPC.Protocol,
          Opal.RPC.Stdio
        ],
        Providers: [
          Opal.Provider,
          Opal.Provider.Copilot,
          Opal.Provider.LLM,
          Opal.Auth.Copilot
        ],
        Tools: [
          Opal.Tool,
          Opal.Tool.Read,
          Opal.Tool.Write,
          Opal.Tool.Edit,
          Opal.Tool.Shell,
          Opal.Tool.SubAgent,
          Opal.Skill
        ],
        MCP: [
          Opal.MCP.Bridge,
          Opal.MCP.Client,
          Opal.MCP.Config,
          Opal.MCP.Resources,
          Opal.MCP.Supervisor
        ],
        Internals: [
          Opal.Application,
          Opal.Context,
          Opal.Message,
          Opal.Path,
          Opal.SessionServer,
          Opal.Session.Compaction,
          Opal.SubAgent
        ]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp releases do
    [
      opal_server: [
        applications: [opal: :permanent],
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            darwin_arm64: [os: :darwin, cpu: :aarch64],
            darwin_x64: [os: :darwin, cpu: :x86_64],
            linux_x64: [os: :linux, cpu: :x86_64],
            linux_arm64: [os: :linux, cpu: :aarch64],
            win32_x64: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:req_llm, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.11"},
      {:anubis_mcp, "~> 0.17"},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:burrito, "~> 1.5", only: :prod}
    ]
  end
end
