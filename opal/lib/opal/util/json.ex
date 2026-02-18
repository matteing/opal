defmodule Opal.Util.Json do
  @moduledoc "Shared JSON encoding and decoding helpers with safe error handling."

  @doc """
  Decodes a JSON string, returning `default` on failure.

      iex> Opal.Util.Json.safe_decode("{\"a\":1}")
      %{"a" => 1}

      iex> Opal.Util.Json.safe_decode("bad")
      %{}

      iex> Opal.Util.Json.safe_decode(nil)
      %{}
  """
  @spec safe_decode(term(), term()) :: term()
  def safe_decode(json, default \\ %{})

  def safe_decode(json, default) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, parsed} -> parsed
      {:error, _} -> default
    end
  end

  def safe_decode(_, default), do: default

  @doc """
  Encodes a term to JSON, falling back to `inspect/1` on failure.

      iex> Opal.Util.Json.encode_or_inspect(%{a: 1})
      "{\"a\":1}"
  """
  @spec encode_or_inspect(term()) :: String.t()
  def encode_or_inspect(term) do
    case Jason.encode(term) do
      {:ok, json} -> json
      {:error, _} -> inspect(term)
    end
  end
end
