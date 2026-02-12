# `Opal.Auth`
[🔗](https://github.com/scohen/opal/blob/v0.1.0/lib/opal/auth.ex#L1)

Manages GitHub Copilot OAuth credentials.

Implements the device-code OAuth flow for GitHub Copilot:

1. Start device flow → get `device_code`, `user_code`, `verification_uri`
2. User visits URL and enters code
3. Poll until token is granted
4. Exchange GitHub access token for Copilot API token
5. Persist tokens to disk for reuse across sessions

Configuration (client ID, domain) comes from `Opal.Config`.
Tokens are stored at `Opal.Config.auth_file/0` (default: `~/.opal/auth.json`).

# `base_url`

```elixir
@spec base_url(map()) :: String.t()
```

Extracts the API base URL from a Copilot token response.

Parses the `endpoints.api` field or falls back to constructing
the URL from the token's `proxy-ep` annotation.

# `exchange_copilot_token`

```elixir
@spec exchange_copilot_token(String.t(), String.t()) ::
  {:ok, map()} | {:error, term()}
```

Exchanges a GitHub access token for a Copilot API token.

Calls `https://api.{domain}/copilot_internal/v2/token` and returns
the Copilot token response containing `token`, `expires_at`, and
endpoint information.

# `get_token`

```elixir
@spec get_token() :: {:ok, map()} | {:error, term()}
```

Gets a valid Copilot token, refreshing if expired.

Loads the token from disk, checks expiry, and re-exchanges the GitHub
token for a fresh Copilot token if needed. Returns `{:error, :not_authenticated}`
if no token is stored on disk.

# `list_models`

```elixir
@spec list_models() :: [map()]
```

Returns the list of known models available via GitHub Copilot.

This is a curated list since the Copilot API does not expose
a model listing endpoint.

# `load_token`

```elixir
@spec load_token() :: {:ok, map()} | {:error, term()}
```

Loads token data from disk.

Returns `{:ok, token_data}` or `{:error, reason}` if the file
doesn't exist or can't be parsed.

# `poll_for_token`

```elixir
@spec poll_for_token(String.t(), String.t(), pos_integer()) ::
  {:ok, String.t()} | {:error, term()}
```

Polls GitHub for an access token after the user authorizes the device.

Handles `"authorization_pending"` by retrying after `interval_ms` and
`"slow_down"` by increasing the interval by 5 seconds.

## Parameters

  * `domain` — GitHub domain
  * `device_code` — the device code from `start_device_flow/1`
  * `interval_ms` — polling interval in milliseconds

# `save_token`

```elixir
@spec save_token(map()) :: :ok | {:error, term()}
```

Persists token data to disk as JSON.

Stores in the OS user-data directory under `opal/token.json`.

# `start_device_flow`

```elixir
@spec start_device_flow(String.t()) :: {:ok, map()} | {:error, term()}
```

Starts the GitHub device-code OAuth flow.

POSTs to `https://{domain}/login/device/code` and returns the response body
containing `device_code`, `user_code`, and `verification_uri`.

## Parameters

  * `domain` — GitHub domain (default: `"github.com"`)

# `token_expired?`

```elixir
@spec token_expired?(map()) :: boolean()
```

Checks whether a token has expired based on its `expires_at` field.

Returns `true` if the token is expired or will expire within 5 minutes.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
