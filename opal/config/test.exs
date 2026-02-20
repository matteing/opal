import Config

config :opal, start_rpc: false

config :logger, level: :warning

config :logger, level: :warning

config :llm_db,
  compile_embed: false,
  integrity_policy: :warn
