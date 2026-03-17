defmodule Opal.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    setup_file_logger()

    children = [
      {Registry, keys: :unique, name: Opal.Registry},
      {Registry, keys: :duplicate, name: Opal.Events.Registry},
      Opal.Shell.Process,
      {DynamicSupervisor, name: Opal.SessionSupervisor, strategy: :one_for_one}
    ]

    # Only start stdio transport when enabled (default true; set
    # `config :opal, start_rpc: false` in test config for isolation).
    children =
      if Application.get_env(:opal, :start_rpc, true) do
        children ++ [Opal.RPC.Server]
      else
        children
      end

    opts = [strategy: :rest_for_one, name: Opal.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp setup_file_logger do
    data_dir =
      Application.get_env(:opal, :data_dir) ||
        Opal.Config.default_data_dir()

    logs_dir = Path.join(Path.expand(data_dir), "logs")
    log_file = Path.join(logs_dir, "server.log")

    with :ok <- File.mkdir_p(logs_dir),
         :ok <-
           :logger.add_handler(:file_log, :logger_std_h, %{
             config: %{
               file: String.to_charlist(log_file),
               max_no_bytes: 5_000_000,
               max_no_files: 3
             },
             formatter:
               {:logger_formatter,
                %{
                  single_line: true,
                  template: [:time, " [", :level, "] ", :msg, "\n"]
                }}
           }) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Could not set up file logging: #{inspect(reason)}")
    end
  end
end
