use Mix.Config

# In prod, only show warnings and errors on console
config :logger,
  level: :warn

config :logger, :console,
  level: :warn
