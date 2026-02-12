import Config

if data_dir = System.get_env("OPAL_DATA_DIR") do
  config :opal, data_dir: data_dir
end

if shell = System.get_env("OPAL_SHELL") do
  config :opal, shell: String.to_existing_atom(shell)
end

if copilot_domain = System.get_env("OPAL_COPILOT_DOMAIN") do
  config :opal, copilot: [domain: copilot_domain]
end
