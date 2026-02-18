defmodule Opal.Path do
  @moduledoc "Cross-platform path security and normalization."

  @type safe_error :: :outside_base_dir

  @doc """
  Ensures `path` resolves safely within `base_dir`.

  Expands both paths and verifies the target is the base itself or a
  descendant — preventing traversal attacks like `../../etc/passwd`.

  ## Examples

      iex> Opal.Path.safe_relative("src/main.ex", "/project")
      {:ok, "/project/src/main.ex"}

      iex> Opal.Path.safe_relative("../../etc/passwd", "/project")
      {:error, :outside_base_dir}
  """
  @spec safe_relative(String.t(), String.t()) :: {:ok, String.t()} | {:error, safe_error()}
  def safe_relative(path, base_dir) when is_binary(path) and is_binary(base_dir) do
    base = Path.expand(base_dir)
    full = Path.expand(path, base)

    if full == base or String.starts_with?(full, base <> "/") do
      {:ok, full}
    else
      {:error, :outside_base_dir}
    end
  end

  @doc """
  Returns `path` relative to `base`, always using POSIX `/` separators.

  Normalizes `Path.relative_to/2` output so tool results are consistent
  across platforms and the LLM always sees `/`-separated paths.

  ## Examples

      iex> Opal.Path.posix_relative("/project/src/main.ex", "/project")
      "src/main.ex"
  """
  @spec posix_relative(String.t(), String.t()) :: String.t()
  def posix_relative(path, base) when is_binary(path) and is_binary(base) do
    path |> Path.relative_to(base) |> String.replace("\\", "/")
  end

  @doc """
  Returns every directory from the filesystem root down to `path`.

  Walks up from the given path, collecting each ancestor, and returns
  them ordered root-first (deepest directory last). Handles both Unix
  `/` and Windows `C:/` roots.

  ## Examples

      iex> Opal.Path.ancestors("/a/b/c")
      ["/", "/a", "/a/b", "/a/b/c"]
  """
  @spec ancestors(String.t()) :: [String.t()]
  def ancestors(path) when is_binary(path) do
    path |> Path.expand() |> do_ancestors([])
  end

  defp do_ancestors(path, acc) do
    parent = Path.dirname(path)

    if parent == path,
      do: [path | acc],
      else: do_ancestors(parent, [path | acc])
  end
end
