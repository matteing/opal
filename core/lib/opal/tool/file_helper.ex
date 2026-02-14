defmodule Opal.Tool.FileHelper do
  @moduledoc "Shared path resolution and file I/O helpers for file-based tools."

  @doc "Resolves a relative path against the working directory safely."
  @spec resolve_path(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def resolve_path(path, working_dir, opts \\ []) do
    allow_bases = Keyword.get(opts, :allow_bases, [])

    with {:error, :outside_base_dir} <- Opal.Path.safe_relative(path, working_dir),
         {:error, :outside_base_dir} <- resolve_in_allowed_bases(path, allow_bases) do
      {:error, "Path escapes working directory: #{path}"}
    else
      {:ok, resolved} -> {:ok, resolved}
    end
  end

  @doc "Returns additional trusted base directories from tool context."
  @spec allowed_bases(map()) :: [String.t()]
  def allowed_bases(%{config: %Opal.Config{} = config}), do: [Opal.Config.data_dir(config)]
  def allowed_bases(_), do: []

  defp resolve_in_allowed_bases(_path, []), do: {:error, :outside_base_dir}

  defp resolve_in_allowed_bases(path, [base | rest]) do
    case Opal.Path.safe_relative(path, base) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, :outside_base_dir} -> resolve_in_allowed_bases(path, rest)
    end
  end

  @doc "Reads a file with friendly error messages."
  @spec read_file(String.t()) :: {:ok, binary()} | {:error, String.t()}
  def read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, "File not found: #{path}"}
      {:error, :eisdir} -> {:error, "Path is a directory: #{path}"}
      {:error, reason} -> {:error, "Failed to read file: #{reason}"}
    end
  end
end
