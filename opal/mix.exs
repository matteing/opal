defmodule Opal.MixProject do
  use Mix.Project

  @version "0.2.0"
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
      dialyzer: [plt_add_apps: [:mix]],
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
          # I/O-bound stdio transport — tested via RPC integration tests
          Opal.RPC.Stdio
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
    "A local coding agent that runs on your machine and communicates exclusively via JSON-RPC 2.0 over stdio."
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
          Opal.Provider.Model,
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
          Opal.Provider.Model,
          Opal.Provider.Registry,
          Opal.Auth,
          Opal.Auth.Copilot
        ],
        Tools: [
          Opal.Tool,
          Opal.Tool.ReadFile,
          Opal.Tool.WriteFile,
          Opal.Tool.EditFile,
          Opal.Tool.Shell,
          Opal.Skill
        ],
        Internals: [
          Opal.Application,
          Opal.Context,
          Opal.Message,
          Opal.Path,
          Opal.Session.Supervisor,
          Opal.Session.Compaction
        ]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp releases do
    [
      opal: [
        applications: [opal: :permanent],
        include_erts: true,
        strip_beams: true,
        # vm.args disables interactive shell; see rel/vm.args.eex
        rel_templates_path: "rel"
      ]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:req_sse, "~> 0.1"},
      {:llm_db, "~> 2026.1"},
      {:jason, "~> 1.4"},
      {:nimble_options, "~> 1.1"},
      {:glob_ex, "~> 0.1"},
      {:yaml_elixir, "~> 2.11"},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
