import Config

config :opal,
  # data_dir: "~/.opal",          # nil = platform default (Unix: ~/.opal, Windows: %APPDATA%/opal)
  # shell: :sh,                   # nil = auto-detect per platform
  # default_model: {"copilot", "claude-sonnet-4-5"},
  # default_tools: [Opal.Tool.Read, Opal.Tool.Write, Opal.Tool.Edit, Opal.Tool.Shell],
  copilot: [
    client_id: "Iv1.b507a08c87ecfe98",
    domain: "github.com"
  ]

import_config "#{config_env()}.exs"
