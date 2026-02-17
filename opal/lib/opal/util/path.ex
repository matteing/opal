defmodule Opal.Path do
  @moduledoc """
  Cross-platform path normalization and security utilities.

  Provides functions for normalizing file paths across operating systems
  and ensuring paths stay within allowed base directories to prevent
  path traversal attacks.
  """

  @doc """
  Normalizes a path by replacing backslashes with forward slashes and expanding it.

  This ensures consistent path representation regardless of the source OS.

  ## Examples

      iex> Opal.Path.normalize("foo\\\\bar/baz")
      Path.expand("foo/bar/baz")
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(path) when is_binary(path) do
    path
    |> String.replace("\\", "/")
    |> Path.expand()
  end

  @doc """
  Converts a path to use native OS separators.

  Uses backslashes on Windows and forward slashes elsewhere.

  ## Examples

      iex> Opal.Path.to_native("foo/bar/baz")
      "foo/bar/baz"
  """
  @spec to_native(String.t()) :: String.t()
  def to_native(path) when is_binary(path) do
    if Opal.Platform.windows?(), do: String.replace(path, "/", "\\"), else: path
  end

  @doc """
  Ensures a path is safely contained within a base directory.

  Expands both paths and verifies the target is a child of the base directory.
  This prevents path traversal attacks (e.g. `../../etc/passwd`).

  Returns `{:ok, expanded_path}` if the path is within the base directory,
  or `{:error, :outside_base_dir}` if it escapes.

  ## Examples

      iex> Opal.Path.safe_relative("src/main.ex", "/project")
      {:ok, "/project/src/main.ex"}

      iex> Opal.Path.safe_relative("../../etc/passwd", "/project")
      {:error, :outside_base_dir}
  """
  @spec safe_relative(String.t(), String.t()) :: {:ok, String.t()} | {:error, :outside_base_dir}
  def safe_relative(path, base_dir)
      when is_binary(path) and is_binary(base_dir) do
    expanded_base = Path.expand(base_dir)
    expanded_path = Path.expand(path, expanded_base)

    # Ensure the expanded path is within the base directory.
    # Path.relative_to/2 returns the input unchanged when it's not a child.
    if expanded_path == expanded_base or
         Path.relative_to(expanded_path, expanded_base) != expanded_path do
      {:ok, expanded_path}
    else
      {:error, :outside_base_dir}
    end
  end
end
