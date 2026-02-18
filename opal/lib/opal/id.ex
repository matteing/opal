defmodule Opal.Id do
  @moduledoc "Generates cryptographically random hex identifiers."

  @doc "Generates an 8-byte (16-char) hex ID for messages and internal objects."
  @spec generate() :: String.t()
  def generate, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  @doc "Generates a 16-byte (32-char) hex ID for sessions."
  @spec session() :: String.t()
  def session, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end
