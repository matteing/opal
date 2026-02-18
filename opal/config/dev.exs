import Config

config :logger, :default_handler, level: :debug

config :logger,
  level: :debug

config :llm_db,
  compile_embed: false,
  integrity_policy: :warn
