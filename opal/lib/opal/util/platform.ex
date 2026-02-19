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

  Uses `GlobEx` to compile patterns with standard glob semantics.
  On case-insensitive filesystems, patterns are normalized to lowercase.

  Returns `nil` for `nil` input (matches everything).

  ## Examples

      iex> match = Opal.Platform.compile_glob("*.ex")
      iex> Opal.Platform.matches_glob?("file.ex", match)
      true

      iex> match = Opal.Platform.compile_glob("*.{ex,exs}")
      iex> Opal.Platform.matches_glob?("file.exs", match)
      true
  """
  @spec compile_glob(String.t() | nil) :: GlobEx.t() | nil
  def compile_glob(nil), do: nil

  def compile_glob(pattern) when is_binary(pattern) do
    pattern
    |> normalize_case()
    |> GlobEx.compile!(match_dot: true)
  end

  @doc """
  Tests whether a filename matches a compiled glob regex.

  Returns `true` for a `nil` glob (matches everything).
  """
  @spec matches_glob?(String.t(), GlobEx.t() | nil) :: boolean()
  def matches_glob?(_name, nil), do: true

  def matches_glob?(name, %GlobEx{} = glob) do
    name
    |> normalize_case()
    |> then(&GlobEx.match?(glob, &1))
  end

  defp normalize_case(str) when is_binary(str) do
    if case_insensitive_fs?(), do: String.downcase(str), else: str
  end
end
