defmodule Opal.CliState do
  @moduledoc """
  Persistent CLI state.

  Stores user preferences in `<data_dir>/cli_state.json`.
  Separate from `Opal.Settings` which handles server-side configuration.

  ## Stored Data

    * `last_model` — last used model configuration (id, provider, thinking_level)
    * `preferences` — user preferences (auto_confirm, verbose)

  Command history is derived from saved sessions (see `Opal.Session.recent_prompts/2`).
  """

  @version 1

  @default_preferences %{"auto_confirm" => false, "verbose" => false}

  # ── Public API ────────────────────────────────────────────────────

  @doc "Returns the current CLI state."
  @spec get_state() :: map()
  def get_state do
    data = read()

    %{
      "lastModel" => data["last_model"],
      "preferences" => Map.merge(@default_preferences, data["preferences"] || %{}),
      "version" => @version
    }
  end

  @doc "Updates CLI state fields. Merges with existing state."
  @spec set_state(map()) :: map()
  def set_state(updates) when is_map(updates) do
    data = read()

    data =
      data
      |> maybe_put("last_model", updates["lastModel"])
      |> maybe_merge("preferences", updates["preferences"])

    write(data)
    get_state()
  end

  # ── Internals ─────────────────────────────────────────────────────

  defp read do
    case File.read(state_path()) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp write(data) do
    path = state_path()
    File.mkdir_p!(Path.dirname(path))

    case Jason.encode(data, pretty: true) do
      {:ok, json} -> File.write!(path, json)
      {:error, _} -> :ok
    end
  end

  defp state_path do
    cfg = Opal.Config.new()
    Path.join(Opal.Config.data_dir(cfg), "cli_state.json")
  end

  defp maybe_put(data, _key, nil), do: data
  defp maybe_put(data, key, value), do: Map.put(data, key, value)

  defp maybe_merge(data, _key, nil), do: data

  defp maybe_merge(data, key, updates) when is_map(updates) do
    current = data[key] || %{}
    Map.put(data, key, Map.merge(current, updates))
  end
end
