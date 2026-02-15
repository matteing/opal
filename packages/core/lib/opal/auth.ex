defmodule Opal.Auth do
  @moduledoc """
  Provider-agnostic credential detection.

  Probes all available authentication sources — Copilot token file,
  environment-variable API keys (via ReqLLM), and saved settings —
  and returns a summary the client can use to decide whether a setup
  wizard is needed.

  ## Provider selection (first ready wins)

  Providers are checked in the order defined by `@known_providers`
  (`copilot`, `anthropic`, `openai`, `google`). The first provider
  whose credentials are ready is selected.

  If nothing is found, `probe/0` returns `status: "setup_required"` with
  a list of provider options the client can present to the user.
  """

  @known_providers [
    %{
      id: "copilot",
      name: "GitHub Copilot",
      method: "device_code"
    },
    %{
      id: "anthropic",
      name: "Anthropic",
      method: "api_key",
      env_var: "ANTHROPIC_API_KEY"
    },
    %{
      id: "openai",
      name: "OpenAI",
      method: "api_key",
      env_var: "OPENAI_API_KEY"
    },
    %{
      id: "google",
      name: "Google Gemini",
      method: "api_key",
      env_var: "GOOGLE_API_KEY"
    }
  ]

  @type probe_result :: %{
          status: String.t(),
          provider: String.t() | nil,
          providers: [map()]
        }

  @doc """
  Probes all credential sources and returns auth readiness.

  Returns a map with:

    * `status` — `"ready"` if at least one provider has valid credentials,
      `"setup_required"` if none do.
    * `provider` — the ID of the auto-selected provider (or `nil`).
    * `providers` — list of all known providers with their readiness state.
  """
  @spec probe() :: probe_result()
  def probe do
    providers = Enum.map(@known_providers, &check_provider/1)

    case Enum.find(providers, & &1.ready) do
      %{id: id} ->
        %{status: "ready", provider: id, providers: providers}

      nil ->
        %{status: "setup_required", provider: nil, providers: providers}
    end
  end

  @doc """
  Checks whether a specific provider has valid credentials.
  """
  @spec ready?(String.t()) :: boolean()
  def ready?(provider_id) do
    probe()
    |> Map.get(:providers, [])
    |> Enum.find(&(&1.id == provider_id))
    |> case do
      %{ready: true} -> true
      _ -> false
    end
  end

  # -- Private --

  defp check_provider(%{id: "copilot"} = p) do
    ready =
      case Opal.Auth.Copilot.get_token() do
        {:ok, _} -> true
        _ -> false
      end

    Map.put(p, :ready, ready)
  end

  defp check_provider(%{id: id, env_var: env_var} = p) do
    ready =
      has_saved_key?(id) ||
        has_env_key?(env_var)

    Map.put(p, :ready, ready)
  end

  defp has_saved_key?(provider_id) do
    key = Opal.Settings.get("#{provider_id}_api_key")
    is_binary(key) and key != ""
  end

  defp has_env_key?(env_var) do
    case System.get_env(env_var) do
      val when is_binary(val) and val != "" -> true
      _ -> false
    end
  end
end
