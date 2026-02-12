defmodule Opal.Settings do
  @moduledoc """
  Persistent user preferences stored in `~/.opal/settings.json`.

  Provides a thin JSON-backed key-value store for user preferences that
  persist across sessions. Settings are separate from `Opal.Config` which
  handles compile-time and application-level configuration.

  ## Supported Keys

    * `"default_model"` — `"provider:model_id"` string (e.g. `"anthropic:claude-sonnet-4-5"`)

  ## File Location

  Settings live at `<data_dir>/settings.json`, typically `~/.opal/settings.json`.
  """

  @doc """
  Returns all settings as a map.

  Reads from disk on every call (no caching). Returns an empty map if
  the file doesn't exist or is invalid.
  """
  @spec get_all() :: map()
  def get_all do
    case File.read(settings_path()) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, settings} when is_map(settings) -> settings
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  @doc """
  Returns a single setting value, or `default` if not set.
  """
  @spec get(String.t(), term()) :: term()
  def get(key, default \\ nil) when is_binary(key) do
    Map.get(get_all(), key, default)
  end

  @doc """
  Saves settings to disk, merging with existing settings.

  Accepts a map of key-value pairs. Existing keys not present in
  the input are preserved.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec save(map()) :: :ok | {:error, term()}
  def save(settings) when is_map(settings) do
    current = get_all()
    merged = Map.merge(current, settings)
    path = settings_path()

    File.mkdir_p!(Path.dirname(path))

    case Jason.encode(merged, pretty: true) do
      {:ok, json} -> File.write(path, json)
      {:error, reason} -> {:error, reason}
    end
  end

  defp settings_path do
    cfg = Opal.Config.new()
    Path.join(Opal.Config.data_dir(cfg), "settings.json")
  end
end
