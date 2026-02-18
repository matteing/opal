defmodule Opal.Id do
  @moduledoc "Generates cryptographically random hex identifiers."

  @doc "Generates a random hex string of `byte_count` bytes (2 hex chars per byte)."
  @spec hex(pos_integer()) :: String.t()
  def hex(byte_count), do: :crypto.strong_rand_bytes(byte_count) |> Base.encode16(case: :lower)

  @doc "Generates an 8-byte (16-char) hex ID for messages and internal objects."
  @spec generate() :: String.t()
  def generate, do: hex(8)

  @doc "Generates a 16-byte (32-char) hex ID for sessions."
  @spec session() :: String.t()
  def session, do: hex(16)
end
