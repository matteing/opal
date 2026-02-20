import Config

# Logger must use stderr — stdout is reserved for JSON-RPC over stdio.
config :logger, :default_handler, config: %{type: :standard_error}

config :opal,
  # data_dir: "~/.opal",          # nil = platform default (Unix: ~/.opal, Windows: %APPDATA%/opal)
  # shell: :sh,                   # nil = auto-detect per platform
  # default_model: {"copilot", "claude-sonnet-4-5"},
  # default_tools: [Opal.Tool.ReadFile, Opal.Tool.WriteFile, Opal.Tool.EditFile, Opal.Tool.Shell],
  copilot_domain: "github.com"

import_config "#{config_env()}.exs"
