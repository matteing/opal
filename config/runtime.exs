import Config

if data_dir = System.get_env("OPAL_DATA_DIR") do
  config :opal, data_dir: data_dir
end

if shell = System.get_env("OPAL_SHELL") do
  # to_atom is safe here — called once per boot with a user-controlled env var.
  # to_existing_atom would crash if the shell atom hasn't been loaded yet.
  config :opal, shell: String.to_atom(shell)
end

if copilot_domain = System.get_env("OPAL_COPILOT_DOMAIN") do
  config :opal, copilot: [domain: copilot_domain]
end
