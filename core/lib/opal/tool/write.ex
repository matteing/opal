defmodule Opal.Tool.Write do
  @moduledoc """
  Writes content to a file, creating parent directories as needed.

  Implements the `Opal.Tool` behaviour. Resolves paths relative to the
  session's working directory using `Opal.Path.safe_relative/2`.

  ## Encoding Preservation

  When overwriting an existing file, detects its BOM and line-ending style
  and applies them to the new content. This prevents silent encoding
  corruption when the LLM writes content without `\\r` or BOM bytes.
  New files use platform defaults (LF, no BOM).
  """

  @behaviour Opal.Tool

  alias Opal.Tool.Encoding
  alias Opal.Tool.FileHelper

  @impl true
  @spec name() :: String.t()
  def name, do: "write_file"

  @impl true
  @spec description() :: String.t()
  def description,
    do: "Write content to a file at the given path. Creates parent directories if needed."

  @impl true
  def meta(%{"path" => path}), do: "Write #{path}"
  def meta(_), do: "Write file"

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path to the file to write"},
        "content" => %{"type" => "string", "description" => "Content to write to the file"}
      },
      "required" => ["path", "content"]
    }
  end

  @impl true
  @spec execute(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"path" => path, "content" => content}, %{working_dir: working_dir}) do
    with {:ok, resolved} <- FileHelper.resolve_path(path, working_dir) do
      write_file(resolved, content)
    end
  end

  def execute(%{"path" => _, "content" => _}, _context),
    do: {:error, "Missing working_dir in context"}

  def execute(_args, _context),
    do: {:error, "Missing required parameters: path and content"}

  defp write_file(path, content) do
    path |> Path.dirname() |> File.mkdir_p!()

    # If the file already exists, detect its encoding and apply it to the
    # new content so we don't silently strip BOM or change line endings.
    content = match_existing_encoding(path, content)

    case File.write(path, content) do
      :ok -> {:ok, "File written: #{path}"}
      {:error, reason} -> {:error, "Failed to write file: #{reason}"}
    end
  end

  # Detects the BOM and line-ending style of an existing file and applies
  # them to the new content. For new files, returns content unchanged.
  defp match_existing_encoding(path, content) do
    case File.read(path) do
      {:ok, existing} ->
        {had_bom, _} = Encoding.strip_bom(existing)
        {had_crlf, _} = Encoding.normalize_line_endings(existing)

        content
        |> Encoding.restore_line_endings(had_crlf)
        |> Encoding.restore_bom(had_bom)

      # New file — use platform defaults (LF, no BOM)
      {:error, _} ->
        content
    end
  end
end
