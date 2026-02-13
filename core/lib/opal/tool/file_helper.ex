defmodule Opal.Tool.FileHelper do
  @moduledoc "Shared path resolution and file I/O helpers for file-based tools."

  @doc "Resolves a relative path against the working directory safely."
  @spec resolve_path(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve_path(path, working_dir) do
    case Opal.Path.safe_relative(path, working_dir) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, :outside_base_dir} -> {:error, "Path escapes working directory: #{path}"}
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
