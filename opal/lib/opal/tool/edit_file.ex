defmodule Opal.Tool.EditFile do
  @moduledoc """
  Edits a file by referencing lines via their hashline tags.

  The model references lines by `N:hash` tags from `read_file` output,
  eliminating recall failures — only a short hash, not whitespace-perfect
  content.

  Supports `replace` (default), `insert_after`, and `insert_before`.
  """

  @behaviour Opal.Tool

  alias Opal.{FileIO, Hashline}

  @impl true
  def name, do: "edit_file"

  @impl true
  def description,
    do:
      "Edit a file by referencing line:hash tags from read_file output. " <>
        "Both start and through lines are INCLUDED in the replacement. " <>
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
        "through" => %{
          "type" => "string",
          "description" =>
            "Last line tag (inclusive) in 'N:hash' format for multi-line replacements. " <>
              "This line IS replaced — if it contains a block closer like `end`, your new_string must account for it. " <>
              "Defaults to start for single-line edits."
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
    end_anchor = Map.get(args, "through", Map.get(args, "end", start_anchor))
    new_string = Map.get(args, "new_string", "")
    operation = Map.get(args, "operation", "replace")

    with {:ok, resolved} <- FileIO.resolve_path(path, working_dir),
         {:ok, raw_content} <- FileIO.read_file(resolved),
         {:ok, {start_line, start_hash}} <- Hashline.parse_anchor(start_anchor),
         {:ok, {end_line, end_hash}} <- Hashline.parse_anchor(end_anchor) do
      {enc, content} = FileIO.normalize_encoding(raw_content)
      new_string = String.replace(new_string, "\r\n", "\n")

      lines = String.split(content, "\n")

      with :ok <- validate_range(start_line, end_line, length(lines), operation),
           :ok <- Hashline.validate_hash(lines, start_line, start_hash),
           :ok <- validate_end_hash(lines, start_line, end_line, end_hash, operation) do
        replaced = replaced_content(lines, start_line, end_line, operation)
        new_content = apply_operation(lines, start_line, end_line, new_string, operation)

        restored = FileIO.restore_encoding(new_content, enc)

        case File.write(resolved, restored) do
          :ok -> {:ok, format_result(resolved, replaced)}
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

  # --- Result formatting ---

  # Extracts the lines that will be replaced/displaced by the edit, so the
  # model can see exactly what it removed. For insert operations, returns
  # the anchor line for context.
  @spec replaced_content([String.t()], pos_integer(), pos_integer(), String.t()) :: String.t()
  defp replaced_content(lines, start_line, end_line, "replace") do
    lines
    |> Enum.slice((start_line - 1)..(end_line - 1)//1)
    |> Enum.with_index(start_line)
    |> Enum.map_join("\n", fn {line, num} -> Hashline.tag_line(line, num) end)
  end

  defp replaced_content(lines, start_line, _end_line, _insert_op) do
    line = Enum.at(lines, start_line - 1)
    Hashline.tag_line(line, start_line)
  end

  # Formats the success message including the replaced/anchor content.
  @spec format_result(String.t(), String.t()) :: String.t()
  defp format_result(resolved, replaced) do
    "Edit applied to: #{resolved}\n\nReplaced content:\n#{replaced}"
  end
end
