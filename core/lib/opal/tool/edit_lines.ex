defmodule Opal.Tool.EditLines do
  @moduledoc """
  Edits a file by referencing lines via their hashline tags.

  Instead of reproducing the old content (as `edit_file` requires), the model
  references lines by their `N:hash` tags from `read_file` output. This
  eliminates recall failures — the model only needs to remember a short hash,
  not reproduce whitespace-perfect content.

  ## Operations

  - **replace** (default): Replace lines `start` through `end` with `new_string`.
  - **insert_after**: Insert `new_string` after the `start` line.
  - **insert_before**: Insert `new_string` before the `start` line.

  ## Hash Validation

  Before applying any edit, the tool verifies that the referenced line hashes
  match the current file content. If the file changed since the last `read_file`,
  the hashes won't match and the edit is rejected.
  """

  @behaviour Opal.Tool

  alias Opal.Tool.Encoding
  alias Opal.Tool.Hashline

  @impl true
  def name, do: "edit_file"

  @impl true
  def description,
    do:
      "Edit a file by referencing line:hash tags from read_file output. " <>
        "Supports replace (default), insert_after, and insert_before operations."

  @impl true
  def meta(%{"path" => path}), do: "Edit #{path}"
  def meta(_), do: "Edit file"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path to the file to edit"},
        "start" => %{
          "type" => "string",
          "description" => "Start line tag in 'N:hash' format (e.g. '5:a3') from read_file output"
        },
        "end" => %{
          "type" => "string",
          "description" =>
            "End line tag in 'N:hash' format for multi-line replacements. Defaults to start for single-line edits."
        },
        "new_string" => %{
          "type" => "string",
          "description" => "Content to insert or replace with. Omit to delete lines."
        },
        "operation" => %{
          "type" => "string",
          "description" => "Operation: 'replace' (default), 'insert_after', or 'insert_before'",
          "enum" => ["replace", "insert_after", "insert_before"]
        }
      },
      "required" => ["path", "start"]
    }
  end

  @impl true
  def execute(
        %{"path" => path, "start" => start_anchor} = args,
        %{working_dir: working_dir}
      ) do
    end_anchor = Map.get(args, "end", start_anchor)
    new_string = Map.get(args, "new_string", "")
    operation = Map.get(args, "operation", "replace")

    with {:ok, resolved} <- resolve_path(path, working_dir),
         {:ok, raw_content} <- read_file(resolved),
         {:ok, {start_line, start_hash}} <- Hashline.parse_anchor(start_anchor),
         {:ok, {end_line, end_hash}} <- Hashline.parse_anchor(end_anchor) do
      # Strip encoding artifacts before editing
      {had_bom, content} = Encoding.strip_bom(raw_content)
      {had_crlf, content} = Encoding.normalize_line_endings(content)
      new_string = String.replace(new_string, "\r\n", "\n")

      lines = String.split(content, "\n")

      with :ok <- validate_range(start_line, end_line, length(lines), operation),
           :ok <- Hashline.validate_hash(lines, start_line, start_hash),
           :ok <- validate_end_hash(lines, start_line, end_line, end_hash, operation) do
        new_content = apply_operation(lines, start_line, end_line, new_string, operation)

        restored =
          new_content
          |> Encoding.restore_line_endings(had_crlf)
          |> Encoding.restore_bom(had_bom)

        case File.write(resolved, restored) do
          :ok -> {:ok, "Edit applied to: #{resolved}"}
          {:error, reason} -> {:error, "Failed to write file: #{reason}"}
        end
      end
    end
  end

  def execute(%{"path" => _, "start" => _}, _context),
    do: {:error, "Missing working_dir in context"}

  def execute(_args, _context),
    do: {:error, "Missing required parameters: path and start"}

  # --- Private helpers ---

  defp resolve_path(path, working_dir) do
    case Opal.Path.safe_relative(path, working_dir) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, :outside_base_dir} -> {:error, "Path escapes working directory: #{path}"}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, "File not found: #{path}"}
      {:error, reason} -> {:error, "Failed to read file: #{reason}"}
    end
  end

  defp validate_range(start_line, end_line, total, operation) do
    cond do
      operation in ["insert_after", "insert_before"] and start_line > total ->
        {:error, "Line #{start_line} is out of range (file has #{total} lines)"}

      start_line > end_line ->
        {:error, "start line #{start_line} is after end line #{end_line}"}

      end_line > total ->
        {:error, "Line #{end_line} is out of range (file has #{total} lines)"}

      true ->
        :ok
    end
  end

  # For insert operations, only the start hash matters
  defp validate_end_hash(_lines, start_line, end_line, _end_hash, op)
       when op in ["insert_after", "insert_before"] and start_line == end_line,
       do: :ok

  defp validate_end_hash(lines, _start_line, end_line, end_hash, _op) do
    Hashline.validate_hash(lines, end_line, end_hash)
  end

  defp apply_operation(lines, start_line, end_line, new_string, "replace") do
    before = Enum.take(lines, start_line - 1)
    after_lines = Enum.drop(lines, end_line)

    replacement =
      if new_string == "" do
        []
      else
        String.split(new_string, "\n")
      end

    Enum.join(before ++ replacement ++ after_lines, "\n")
  end

  defp apply_operation(lines, start_line, _end_line, new_string, "insert_after") do
    {before, after_lines} = Enum.split(lines, start_line)
    insertion = String.split(new_string, "\n")
    Enum.join(before ++ insertion ++ after_lines, "\n")
  end

  defp apply_operation(lines, start_line, _end_line, new_string, "insert_before") do
    {before, after_lines} = Enum.split(lines, start_line - 1)
    insertion = String.split(new_string, "\n")
    Enum.join(before ++ insertion ++ after_lines, "\n")
  end
end
