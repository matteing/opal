defmodule Opal.Auth.Copilot do
  @moduledoc """
  Manages GitHub Copilot OAuth credentials.

  Implements the device-code OAuth flow for GitHub Copilot:

  1. Start device flow → get `device_code`, `user_code`, `verification_uri`
  2. User visits URL and enters code
  3. Poll until token is granted
  4. Exchange GitHub access token for Copilot API token
  5. Persist tokens to disk for reuse across sessions

  Configuration (client ID, domain) comes from `Opal.Config`.
  Tokens are stored at `Opal.Config.auth_file/1` (default: `~/.opal/auth.json`).
  """

  @copilot_headers %{
    "user-agent" => "GitHubCopilotChat/0.35.0",
    "editor-version" => "vscode/1.107.0",
    "editor-plugin-version" => "copilot-chat/0.35.0",
    "copilot-integration-id" => "vscode-chat"
  }

  defp client_id, do: default_config().copilot.client_id
  defp domain, do: default_config().copilot.domain

  defp default_config, do: Opal.Config.new()

  @doc """
  Starts the GitHub device-code OAuth flow.

  POSTs to `https://{domain}/login/device/code` and returns the response body
  containing `device_code`, `user_code`, and `verification_uri`.

  ## Parameters

    * `domain` — GitHub domain (default: `"github.com"`)
  """
  @spec start_device_flow(String.t()) :: {:ok, map()} | {:error, term()}
  def start_device_flow(dom \\ domain()) do
    case Req.post("https://#{dom}/login/device/code",
           json: %{client_id: client_id(), scope: "read:user"},
           headers: %{"accept" => "application/json"},
           pool_timeout: 5_000,
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Polls GitHub for an access token after the user authorizes the device.

  Handles `"authorization_pending"` by retrying after `interval_ms` and
  `"slow_down"` by increasing the interval by 5 seconds.

  ## Parameters

    * `domain` — GitHub domain
    * `device_code` — the device code from `start_device_flow/1`
    * `interval_ms` — polling interval in milliseconds
  """
  @spec poll_for_token(String.t(), String.t(), pos_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def poll_for_token(domain, device_code, interval_ms) do
    body = %{
      client_id: client_id(),
      device_code: device_code,
      grant_type: "urn:ietf:params:oauth:grant-type:device_code"
    }

    case Req.post("https://#{domain}/login/oauth/access_token",
           json: body,
           headers: %{"accept" => "application/json"},
           pool_timeout: 5_000,
           receive_timeout: 10_000
         ) do
      {:ok, %{body: %{"access_token" => token}}} ->
        {:ok, token}

      {:ok, %{body: %{"error" => "authorization_pending"}}} ->
        Process.sleep(interval_ms)
        poll_for_token(domain, device_code, interval_ms)

      {:ok, %{body: %{"error" => "slow_down"}}} ->
        # Back off by adding 5 seconds as per OAuth spec
        Process.sleep(interval_ms + 5_000)
        poll_for_token(domain, device_code, interval_ms + 5_000)

      {:ok, %{body: %{"error" => error} = body}} ->
        {:error, {error, Map.get(body, "error_description", "")}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Exchanges a GitHub access token for a Copilot API token.

  Calls `https://api.{domain}/copilot_internal/v2/token` and returns
  the Copilot token response containing `token`, `expires_at`, and
  endpoint information.
  """
  @spec exchange_copilot_token(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def exchange_copilot_token(github_token, domain \\ "github.com") do
    case Req.get("https://api.#{domain}/copilot_internal/v2/token",
           auth: {:bearer, github_token},
           headers: @copilot_headers,
           pool_timeout: 5_000,
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets a valid Copilot token, refreshing if expired.

  Loads the token from disk, checks expiry, and re-exchanges the GitHub
  token for a fresh Copilot token if needed. Returns `{:error, :not_authenticated}`
  if no token is stored on disk.
  """
  @spec get_token() :: {:ok, map()} | {:error, term()}
  def get_token do
    case load_token() do
      {:ok, token_data} ->
        if token_expired?(token_data) do
          refresh_token(token_data)
        else
          {:ok, token_data}
        end

      {:error, _reason} ->
        {:error, :not_authenticated}
    end
  end

  @doc """
  Extracts the API base URL from a Copilot token response.

  Parses the `endpoints.api` field or falls back to constructing
  the URL from the token's `proxy-ep` annotation.
  """
  @spec base_url(map()) :: String.t()
  def base_url(%{"endpoints" => %{"api" => url}}) when is_binary(url), do: url

  def base_url(%{"token" => token}) when is_binary(token) do
    # The Copilot token is a semicolon-delimited key=value string
    # containing a `proxy-ep` field with the proxy hostname.
    # We convert proxy.* → api.* to get the API base URL.
    case Regex.run(~r/(?:^|;)\s*proxy-ep=([^;\s]+)/i, token) do
      [_, proxy_ep] ->
        host =
          proxy_ep
          |> String.replace(~r/^https?:\/\//, "")
          |> String.replace(~r/^proxy\./i, "api.")

        "https://#{host}"

      _ ->
        "https://api.individual.githubcopilot.com"
    end
  end

  def base_url(_), do: "https://api.individual.githubcopilot.com"

  @doc """
  Persists token data to disk as JSON.

  Stores in the OS user-data directory under `opal/token.json`.
  """
  @spec save_token(map()) :: :ok | {:error, term()}
  def save_token(token_data) when is_map(token_data) do
    path = token_path()

    with :ok <- path |> Path.dirname() |> File.mkdir_p(),
         json <- Jason.encode!(token_data),
         :ok <- File.write(path, json) do
      :ok
    end
  end

  @doc """
  Loads token data from disk.

  Returns `{:ok, token_data}` or `{:error, reason}` if the file
  doesn't exist or can't be parsed.
  """
  @spec load_token() :: {:ok, map()} | {:error, term()}
  def load_token do
    path = token_path()

    with {:ok, contents} <- File.read(path),
         {:ok, data} <- Jason.decode(contents) do
      {:ok, data}
    end
  end

  @doc """
  Checks whether a token has expired based on its `expires_at` field.

  Returns `true` if the token is expired or will expire within 5 minutes.
  """
  @spec token_expired?(map()) :: boolean()
  def token_expired?(%{"expires_at" => expires_at}) when is_integer(expires_at) do
    # Refresh 5 minutes before actual expiry
    now = System.system_time(:second)
    now >= expires_at - 300
  end

  def token_expired?(_), do: true

  # --- Private helpers ---

  defp refresh_token(%{"github_token" => github_token} = token_data) do
    case exchange_copilot_token(github_token, domain()) do
      {:ok, copilot_response} ->
        updated =
          Map.merge(token_data, %{
            "copilot_token" => copilot_response["token"],
            "expires_at" => copilot_response["expires_at"],
            "base_url" => base_url(copilot_response)
          })

        save_token(updated)
        {:ok, updated}

      {:error, reason} ->
        {:error, {:refresh_failed, reason}}
    end
  end

  defp refresh_token(_), do: {:error, :missing_github_token}

  @doc """
  Returns the list of models available via GitHub Copilot.

  Auto-discovered from LLMDB's `github_copilot` provider. See `Opal.Models`
  for details on model discovery and Copilot naming quirks.
  """
  @spec list_models() :: [map()]
  def list_models do
    Opal.Models.list_copilot()
  end

  defp token_path do
    Opal.Config.auth_file(Opal.Config.new())
  end
end
