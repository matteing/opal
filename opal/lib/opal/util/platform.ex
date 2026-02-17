defmodule Opal.Platform do
  @moduledoc """
  Cross-platform helpers.

  Provides a single, cached platform detection used throughout the codebase
  instead of scattering `:os.type()` calls.
  """

  @type os :: :linux | :macos | :windows

  @doc """
  Returns the current platform as `:linux`, `:macos`, or `:windows`.
  """
  @spec os() :: os()
  def os do
    case :os.type() do
      {:unix, :darwin} -> :macos
      {:unix, _} -> :linux
      {:win32, _} -> :windows
    end
  end

  @doc "Returns `true` on Windows."
  @spec windows?() :: boolean()
  def windows?, do: os() == :windows

  @doc "Returns `true` on macOS."
  @spec macos?() :: boolean()
  def macos?, do: os() == :macos

  @doc "Returns `true` on Linux (any non-macOS Unix)."
  @spec linux?() :: boolean()
  def linux?, do: os() == :linux

  @doc "Returns `true` on any Unix variant (macOS or Linux)."
  @spec unix?() :: boolean()
  def unix?, do: os() in [:linux, :macos]

  @doc """
  Returns `true` if the filesystem is case-insensitive on the current platform.

  Windows filesystems (NTFS, FAT) are case-insensitive by default.
  macOS HFS+/APFS is case-insensitive by default but can be configured
  otherwise — we treat it as case-sensitive since developer machines
  commonly use the default case-sensitive APFS variant.
  """
  @spec case_insensitive_fs?() :: boolean()
  def case_insensitive_fs?, do: windows?()

  @doc """
  Detects binary (non-text) content by checking for null bytes.

  Samples the first 8 KB of the content — sufficient for detecting binary
  headers without scanning the entire file. Returns `true` if any null
  byte is found.

  Useful for skipping binary files in search, diff, and read tools.
  """
  @spec binary_content?(binary()) :: boolean()
  def binary_content?(content) when is_binary(content) do
    sample = binary_part(content, 0, min(byte_size(content), 8192))
    :binary.match(sample, <<0>>) != :nomatch
  end

  @doc """
  Compiles a filename glob pattern into a `Regex`.

  Handles `*` wildcards and `{a,b}` brace expansion. On platforms with
  case-insensitive filesystems, the regex is compiled with `:caseless`.

  Returns `nil` for `nil` input (matches everything).

  ## Examples

      iex> Opal.Platform.compile_glob("*.ex")
      ~r/^.*\\.ex$/

      iex> Opal.Platform.compile_glob("*.{ex,exs}")
      ~r/^.*\\.(ex|exs)$/
  """
  @spec compile_glob(String.t() | nil) :: Regex.t() | nil
  def compile_glob(nil), do: nil

  def compile_glob(pattern) when is_binary(pattern) do
    regex_str =
      pattern
      |> String.replace(".", "\\.")
      |> String.replace("*", ".*")
      |> String.replace("{", "(")
      |> String.replace("}", ")")
      |> String.replace(",", "|")
      |> then(&("^" <> &1 <> "$"))

    opts = if case_insensitive_fs?(), do: [:caseless], else: []
    Regex.compile!(regex_str, opts)
  end

  @doc """
  Tests whether a filename matches a compiled glob regex.

  Returns `true` for a `nil` glob (matches everything).
  """
  @spec matches_glob?(String.t(), Regex.t() | nil) :: boolean()
  def matches_glob?(_name, nil), do: true
  def matches_glob?(name, regex), do: Regex.match?(regex, name)
end
