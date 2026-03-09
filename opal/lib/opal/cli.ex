defmodule Opal.CLI do
  @moduledoc """
  Interactive terminal client for Opal on Snow Leopard.

  A lightweight REPL that talks to the Opal agent via Elixir function
  calls — no Node.js, no JSON-RPC, no external processes.

  ## Usage

      Opal.CLI.main()
      Opal.CLI.main(["--dir", "/project", "--model", "gpt-4o"])
  """

  alias Opal.CLI.Renderer

  @default_model "claude-sonnet-4.5"

  def main(argv \\ []) do
    opts = parse_args(argv)

    # Ensure crypto NIF can find the bundled OpenSSL dylibs.
    # When running as an escript, the code path may not include the OTP
    # lib directory. We add it explicitly and pre-start crypto before
    # the full app tree boots.
    ensure_crypto_loaded()

    # Ensure the OTP app is started (handles both escript and mix run)
    Application.put_env(:opal, :start_rpc, false)
    {:ok, _} = Application.ensure_all_started(:opal)

    # Auth check — run device code flow if no valid token
    ensure_authenticated()

    working_dir = Map.get(opts, :dir, File.cwd!())
    model = Map.get(opts, :model, @default_model)

    case Opal.start_session(%{working_dir: working_dir, model: model}) do
      {:ok, agent} ->
        Renderer.banner(working_dir, model)
        loop(agent)

      {:error, reason} ->
        IO.puts("Failed to start session: #{inspect(reason)}")
        System.halt(1)
    end
  end

  # ── Crypto Bootstrap ───────────────────────────────────────────

  defp ensure_crypto_loaded do
    # The escript bundles app beams but relies on ERL_LIBS for OTP apps
    # like crypto. When escript strips or reorders the code path, the
    # crypto NIF can't find its priv/lib directory. Fix: ensure the OTP
    # lib path is on the code path before anything tries to load crypto.
    case System.get_env("ERL_LIBS") do
      nil -> :ok
      libs ->
        libs
        |> String.split(":")
        |> Enum.each(fn lib_dir ->
          Path.wildcard(Path.join(lib_dir, "*/ebin"))
          |> Enum.each(&:code.add_pathz(String.to_charlist(&1)))
        end)
    end

    case :application.start(:crypto) do
      :ok -> :ok
      {:error, {:already_started, :crypto}} -> :ok
      {:error, reason} ->
        IO.puts("\e[31mFailed to load crypto: #{inspect(reason)}\e[0m")
        IO.puts("Check that OpenSSL dylibs are in the crypto priv/lib directory.")
        System.halt(1)
    end
  end

  # ── Authentication ────────────────────────────────────────────

  defp ensure_authenticated do
    case Opal.Auth.Copilot.get_token() do
      {:ok, _token} ->
        :ok

      {:error, _} ->
        run_device_auth()
    end
  end

  defp run_device_auth do
    IO.puts("")
    IO.puts("  \e[1m✦ GitHub Copilot — Device Authentication\e[0m")
    IO.puts("")

    case Opal.Auth.Copilot.start_device_flow() do
      {:ok, %{body: body}} ->
        user_code = body["user_code"]
        verify_uri = body["verification_uri"]
        device_code = body["device_code"]
        interval = (body["interval"] || 5) * 1000

        IO.puts("  Open: \e[4m#{verify_uri}\e[0m")
        IO.puts("  Code: \e[1;33m#{user_code}\e[0m")
        IO.puts("")
        IO.puts("  Waiting for authorization...")

        case Opal.Auth.Copilot.poll_for_token(
               Opal.Config.new().copilot_domain,
               device_code,
               interval
             ) do
          {:ok, github_token} ->
            IO.puts("  \e[32m✓\e[0m GitHub token received")
            IO.puts("  Exchanging for Copilot token...")

            case Opal.Auth.Copilot.exchange_copilot_token(github_token) do
              {:ok, %{body: copilot_response}} ->
                token_data = %{
                  "github_token" => github_token,
                  "copilot_token" => copilot_response["token"],
                  "expires_at" => copilot_response["expires_at"],
                  "base_url" => Opal.Auth.Copilot.base_url(copilot_response)
                }

                case Opal.Auth.Copilot.save_token(token_data) do
                  :ok ->
                    IO.puts("  \e[32m✓\e[0m Authenticated! Token saved.")
                    IO.puts("")

                  {:error, reason} ->
                    IO.puts("  \e[33m!\e[0m Token works but couldn't save: #{inspect(reason)}")
                    IO.puts("")
                end

              {:error, reason} ->
                IO.puts("  \e[31m✗\e[0m Copilot token exchange failed: #{inspect(reason)}")
                System.halt(1)
            end

          {:error, reason} ->
            IO.puts("  \e[31m✗\e[0m Authorization failed: #{inspect(reason)}")
            System.halt(1)
        end

      {:error, reason} ->
        IO.puts("  \e[31m✗\e[0m Could not start device flow: #{inspect(reason)}")
        System.halt(1)
    end
  end

  # ── REPL Loop ──────────────────────────────────────────────────

  defp loop(agent) do
    case IO.gets(Renderer.prompt_marker()) do
      :eof ->
        goodbye()

      {:error, _} ->
        goodbye()

      input when is_binary(input) ->
        text = String.trim(input)

        cond do
          text == "" ->
            loop(agent)

          String.starts_with?(text, "/") ->
            handle_command(text, agent)

          true ->
            handle_prompt(text, agent)
            loop(agent)
        end
    end
  end

  # ── Prompt Handling ────────────────────────────────────────────

  defp handle_prompt(text, agent) do
    Opal.stream(agent, text)
    |> Enum.each(&Renderer.render_event/1)
  end

  # ── Commands ───────────────────────────────────────────────────

  defp handle_command("/help", agent),
    do:
      (
        Renderer.help()
        loop(agent)
      )

  defp handle_command("/quit", _agent), do: goodbye()
  defp handle_command("/exit", _agent), do: goodbye()

  defp handle_command("/model " <> model_str, agent) do
    model = String.trim(model_str)

    if model == "" do
      current = Opal.Agent.get_state(agent).model
      IO.puts("Current model: #{current.id}")
    else
      Opal.set_model(agent, model)
      IO.puts("Model set to #{model}")
    end

    loop(agent)
  end

  defp handle_command("/models", agent) do
    models = Opal.Provider.Registry.list_copilot()
    current = Opal.Agent.get_state(agent).model.id

    IO.puts("")

    Enum.each(models, fn m ->
      marker = if m.id == current, do: " \e[32m● current\e[0m", else: ""
      thinking = if m.supports_thinking, do: " \e[2m(thinking)\e[0m", else: ""
      IO.puts("  #{m.id}#{thinking}#{marker}")
    end)

    IO.puts("")
    loop(agent)
  end

  defp handle_command("/thinking " <> level_str, agent) do
    level =
      case String.trim(level_str) do
        "off" -> :off
        "low" -> :low
        "medium" -> :medium
        "high" -> :high
        "max" -> :max
        other -> other
      end

    if is_atom(level) do
      Opal.set_thinking_level(agent, level)
      IO.puts("Thinking level set to #{level}")
    else
      IO.puts("Unknown level: #{level}. Use: off, low, medium, high, max")
    end

    loop(agent)
  end

  defp handle_command("/info", agent) do
    info = Opal.get_info(agent)

    IO.puts("""

      \e[1mSession:\e[0m  #{info.session_id}
      \e[1mModel:\e[0m    #{info.model.id}
      \e[1mProvider:\e[0m  #{inspect(info.provider)}
      \e[1mStatus:\e[0m   #{info.status}
      \e[1mMessages:\e[0m #{info.message_count}
      \e[1mTokens:\e[0m   #{inspect(info.token_usage)}
      \e[1mDir:\e[0m      #{info.working_dir}
      \e[1mTools:\e[0m    #{length(info.tools)}
    """)

    loop(agent)
  end

  defp handle_command("/abort", agent) do
    Opal.abort(agent)
    IO.puts("Aborted.")
    loop(agent)
  end

  defp handle_command(cmd, agent) do
    IO.puts("Unknown command: #{cmd}. Type /help for available commands.")
    loop(agent)
  end

  # ── Argument Parsing ───────────────────────────────────────────

  defp parse_args(argv) do
    parse_args(argv, %{})
  end

  defp parse_args([], acc), do: acc
  defp parse_args(["--dir", dir | rest], acc), do: parse_args(rest, Map.put(acc, :dir, dir))
  defp parse_args(["--model", m | rest], acc), do: parse_args(rest, Map.put(acc, :model, m))

  defp parse_args(["--help" | _], _acc) do
    IO.puts("Usage: opal [--dir /path] [--model name]")
    System.halt(0)
  end

  defp parse_args([_ | rest], acc), do: parse_args(rest, acc)

  # ── Goodbye ────────────────────────────────────────────────────

  defp goodbye do
    IO.puts("\n\e[2mGoodbye! (◕‿◕)\e[0m")
    :ok
  end
end
