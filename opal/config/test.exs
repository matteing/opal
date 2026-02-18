import Config

config :logger, level: :warning

config :llm_db,
  compile_embed: false,
  integrity_policy: :warn
