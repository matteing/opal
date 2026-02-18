defmodule Opal.RPC do
  @moduledoc """
  JSON-RPC 2.0 encoding/decoding. Transport-agnostic.

  Used by `Opal.RPC.Server` today; could be used by a WebSocket or HTTP
  transport later. All functions are stateless — pure encode/decode.

  ## Wire Format

  Messages are JSON objects conforming to the
  [JSON-RPC 2.0 spec](https://www.jsonrpc.org/specification).

  ### Message Types

    * **Request** — `{jsonrpc, id, method, params}` — expects a response
    * **Response** — `{jsonrpc, id, result}` — success reply
    * **Error Response** — `{jsonrpc, id, error}` — failure reply
    * **Notification** — `{jsonrpc, method, params}` — fire-and-forget (no `id`)

  ## Error Codes

  Standard JSON-RPC 2.0 error codes:

    | Code    | Constant           | Meaning                |
    | ------- | ------------------ | ---------------------- |
    | -32700  | `parse_error`      | Invalid JSON           |
    | -32600  | `invalid_request`  | Not a valid request    |
    | -32601  | `method_not_found` | Method does not exist  |
    | -32602  | `invalid_params`   | Invalid method params  |
    | -32603  | `internal_error`   | Internal server error  |
  """

  # -- Types --

  @type id :: integer() | String.t()
  @type params :: map()

  @type request :: %{
          jsonrpc: String.t(),
          id: id(),
          method: String.t(),
          params: params()
        }

  @type response :: %{
          jsonrpc: String.t(),
          id: id(),
          result: term()
        }

  @type error :: %{
          code: integer(),
          message: String.t(),
          data: term() | nil
        }

  @type error_response :: %{
          jsonrpc: String.t(),
          id: id() | nil,
          error: error()
        }

  @type notification :: %{
          jsonrpc: String.t(),
          method: String.t(),
          params: params()
        }

  @type message :: request() | response() | error_response() | notification()

  @type decoded ::
          {:request, id(), String.t(), params()}
          | {:response, id(), term()}
          | {:error_response, id() | nil, map()}
          | {:notification, String.t(), params()}
          | {:error, :parse_error | :invalid_request}

  # -- Standard Error Codes --

  @parse_error -32700
  @invalid_request -32600
  @method_not_found -32601
  @invalid_params -32602
  @internal_error -32603

  @doc "Parse error code (-32700)."
  @spec parse_error() :: integer()
  def parse_error, do: @parse_error

  @doc "Invalid request code (-32600)."
  @spec invalid_request() :: integer()
  def invalid_request, do: @invalid_request

  @doc "Method not found code (-32601)."
  @spec method_not_found() :: integer()
  def method_not_found, do: @method_not_found

  @doc "Invalid params code (-32602)."
  @spec invalid_params() :: integer()
  def invalid_params, do: @invalid_params

  @doc "Internal error code (-32603)."
  @spec internal_error() :: integer()
  def internal_error, do: @internal_error

  # -- Encoding --

  @doc """
  Encodes a JSON-RPC 2.0 request.

  ## Examples

      iex> Opal.RPC.encode_request(1, "agent/prompt", %{text: "hello"})
      ~s({"id":1,"jsonrpc":"2.0","method":"agent/prompt","params":{"text":"hello"}})
  """
  @spec encode_request(id(), String.t(), params()) :: String.t()
  def encode_request(id, method, params) do
    Jason.encode!(%{jsonrpc: "2.0", id: id, method: method, params: params})
  end

  @doc """
  Encodes a JSON-RPC 2.0 success response.

  ## Examples

      iex> Opal.RPC.encode_response(1, %{ok: true})
      ~s({"id":1,"jsonrpc":"2.0","result":{"ok":true}})
  """
  @spec encode_response(id(), term()) :: String.t()
  def encode_response(id, result) do
    Jason.encode!(%{jsonrpc: "2.0", id: id, result: result})
  end

  @doc """
  Encodes a JSON-RPC 2.0 error response.

  ## Examples

      iex> Opal.RPC.encode_error(1, -32601, "Method not found")
      ~s({"error":{"code":-32601,"message":"Method not found"},"id":1,"jsonrpc":"2.0"})
  """
  @spec encode_error(id() | nil, integer(), String.t(), term()) :: String.t()
  def encode_error(id, code, message, data \\ nil) do
    error = %{code: code, message: message}
    error = if data != nil, do: Map.put(error, :data, data), else: error
    Jason.encode!(%{jsonrpc: "2.0", id: id, error: error})
  end

  @doc """
  Encodes a JSON-RPC 2.0 notification (no `id`).

  ## Examples

      iex> Opal.RPC.encode_notification("agent/event", %{type: "token"})
      ~s({"jsonrpc":"2.0","method":"agent/event","params":{"type":"token"}})
  """
  @spec encode_notification(String.t(), params()) :: String.t()
  def encode_notification(method, params) do
    Jason.encode!(%{jsonrpc: "2.0", method: method, params: params})
  end

  # -- Decoding --

  @doc """
  Decodes a JSON string into a tagged message tuple.

  Returns one of:

    * `{:request, id, method, params}` — client or server request
    * `{:response, id, result}` — success response
    * `{:error_response, id, error_map}` — error response
    * `{:notification, method, params}` — fire-and-forget
    * `{:error, :parse_error}` — invalid JSON
    * `{:error, :invalid_request}` — valid JSON but not JSON-RPC 2.0

  ## Examples

      iex> Opal.RPC.decode(~s({"jsonrpc":"2.0","id":1,"method":"ping","params":{}}))
      {:request, 1, "ping", %{}}

      iex> Opal.RPC.decode(~s({"jsonrpc":"2.0","method":"notify","params":{}}))
      {:notification, "notify", %{}}

      iex> Opal.RPC.decode("not json")
      {:error, :parse_error}
  """
  @spec decode(String.t()) :: decoded()
  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"jsonrpc" => "2.0", "id" => id, "method" => method} = msg} ->
        {:request, id, method, Map.get(msg, "params", %{})}

      {:ok, %{"jsonrpc" => "2.0", "id" => id, "result" => result}} ->
        {:response, id, result}

      {:ok, %{"jsonrpc" => "2.0", "id" => id, "error" => error}} ->
        {:error_response, id, error}

      {:ok, %{"jsonrpc" => "2.0", "method" => method} = msg} ->
        {:notification, method, Map.get(msg, "params", %{})}

      {:ok, _} ->
        {:error, :invalid_request}

      {:error, _} ->
        {:error, :parse_error}
    end
  end
end
