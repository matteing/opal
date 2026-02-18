defmodule Opal.Util.Error do
  @moduledoc "Helpers for converting and matching error reasons."

  @doc """
  Converts an arbitrary error term to a string for pattern matching.

  Maps are `inspect/1`-ed (they don't implement `String.Chars`).
  Atoms and binaries are converted directly.
  """
  @spec stringify_reason(term()) :: String.t()
  def stringify_reason(reason) when is_binary(reason), do: reason
  def stringify_reason(reason) when is_map(reason), do: inspect(reason)
  def stringify_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  def stringify_reason(reason) do
    String.Chars.to_string(reason)
  rescue
    Protocol.UndefinedError -> inspect(reason)
  end

  @doc """
  Returns `true` if `text` contains any of the given `patterns`.

      iex> Opal.Util.Error.matches_any?("connection timeout", ["timeout", "refused"])
      true
  """
  @spec matches_any?(String.t(), [String.t()]) :: boolean()
  def matches_any?(text, patterns) do
    Enum.any?(patterns, &String.contains?(text, &1))
  end
end
