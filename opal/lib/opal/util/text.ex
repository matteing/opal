defmodule Opal.Util.Text do
  @moduledoc "Shared text truncation and formatting helpers."

  @doc """
  Truncates a string to `max` characters, appending `suffix` when truncated.

  Default suffix is `"… (truncated)"`. Pass `"..."` or `""` for other styles.

      iex> Opal.Util.Text.truncate("hello", 100)
      "hello"

      iex> Opal.Util.Text.truncate("hello world", 5, "...")
      "hello..."
  """
  @spec truncate(String.t(), pos_integer(), String.t()) :: String.t()
  def truncate(str, max, suffix \\ "… (truncated)")
  def truncate(str, max, _suffix) when byte_size(str) <= max, do: str
  def truncate(str, max, suffix), do: String.slice(str, 0, max) <> suffix

  @doc """
  Truncates a string to `max` characters with no suffix.

  Useful for display previews, debug output, and meta labels.

      iex> Opal.Util.Text.truncate_preview("hello world", 5)
      "hello"
  """
  @spec truncate_preview(String.t(), pos_integer()) :: String.t()
  def truncate_preview(str, max) when byte_size(str) <= max, do: str
  def truncate_preview(str, max), do: String.slice(str, 0, max)
end
