defmodule Opal.Tool.Read do
  @moduledoc """
  Reads file contents, optionally returning a slice of lines.

  Implements the `Opal.Tool` behaviour. Resolves paths relative to the
  session's working directory using `Opal.Path.safe_relative/2`.

  ## Encoding

  Strips UTF-8 BOM before returning content so the LLM sees clean text.
  The BOM is invisible and would confuse pattern matching in edits.

  ## Truncation

  Large outputs are truncated to avoid consuming excessive context tokens.
  Files are truncated from the head (structure/imports are at the top)
  with actionable hints telling the LLM how to request more.
  """

  @behaviour Opal.Tool

  alias Opal.Tool.Encoding
  alias Opal.Tool.FileHelper
  alias Opal.Tool.Hashline

  # -- Truncation limits ------------------------------------------------------
  # Files beyond these thresholds get head-truncated with continuation hints.
  @max_lines 2_000
  @max_bytes 50 * 1024

  @impl true
  @spec name() :: String.t()
  def name, do: "read_file"

  @impl true
  @spec description() :: String.t()
  def description, do: "Read the contents of a file at the given path."

  @impl true
  def meta(%{"path" => path}), do: "Read #{path}"
  def meta(_), do: "Read file"

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path to the file to read"},
        "offset" => %{
          "type" => "integer",
          "description" => "Line number to start reading from (1-indexed)"
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Maximum number of lines to read"
        }
      },
      "required" => ["path"]
    }
  end

  @impl true
  @spec execute(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"path" => path} = args, %{working_dir: working_dir} = context) do
    allow_bases = FileHelper.allowed_bases(context)

    with {:ok, resolved} <- FileHelper.resolve_path(path, working_dir, allow_bases: allow_bases),
         {:ok, raw_content} <- FileHelper.read_file(resolved) do
      # Strip BOM so the LLM sees clean text (BOM is invisible and would
      # cause mismatches if the LLM later tries to edit the file).
      {_had_bom, content} = Encoding.strip_bom(raw_content)
      # Normalize CRLF → LF for consistent line splitting
      {_had_crlf, content} = Encoding.normalize_line_endings(content)

      offset = Map.get(args, "offset")
      limit = Map.get(args, "limit")
      sliced = maybe_slice(content, offset, limit)

      # Truncate oversized output with actionable continuation hints
      truncate_output(sliced, offset, path)
    end
  end

  def execute(%{"path" => _}, _context), do: {:error, "Missing working_dir in context"}
  def execute(_args, _context), do: {:error, "Missing required parameter: path"}

  defp maybe_slice(content, nil, nil), do: Hashline.tag_lines(content)

  defp maybe_slice(content, offset, limit) do
    lines = String.split(content, "\n")
    # Default offset to 1, default limit to all remaining lines
    start = max((offset || 1) - 1, 0)
    selected = if limit, do: Enum.slice(lines, start, limit), else: Enum.drop(lines, start)

    selected
    |> Enum.with_index(start + 1)
    |> Enum.map_join("\n", fn {line, num} ->
      hash = Hashline.line_hash(line)
      "#{num}:#{hash}|#{line}"
    end)
  end

  # -- Output truncation ------------------------------------------------------
  #
  # Head-truncation: keeps the beginning of the file (where structure,
  # imports, and module definitions live). Each truncation message tells the
  # LLM exactly how to request the next chunk.

  defp truncate_output(content, offset, path) do
    lines = String.split(content, "\n")
    total_lines = length(lines)
    start = offset || 1

    cond do
      # Giant single-line file (e.g. minified JS) — suggest shell extraction
      byte_size(content) > @max_bytes and total_lines <= 1 ->
        kb = Float.round(byte_size(content) / 1024, 1)
        max_kb = div(@max_bytes, 1024)

        {:ok,
         "[Line 1 is #{kb}KB, exceeds #{max_kb}KB limit. " <>
           "Use shell: head -c #{@max_bytes} #{path}]"}

      # Too many lines — keep the first @max_lines
      total_lines > @max_lines ->
        shown = Enum.take(lines, @max_lines)
        text = Enum.join(shown, "\n")
        end_line = start + @max_lines - 1

        {:ok,
         text <>
           "\n\n[Showing lines #{start}-#{end_line} of #{total_lines}. " <>
           "Use offset=#{end_line + 1} to continue.]"}

      # Under line limit but over byte limit — truncate at line boundary
      byte_size(content) > @max_bytes ->
        truncated = truncate_at_line_boundary(content, @max_bytes)
        shown_count = length(String.split(truncated, "\n"))
        end_line = start + shown_count - 1

        {:ok,
         truncated <>
           "\n\n[Output truncated at #{div(@max_bytes, 1024)}KB. " <>
           "Showing lines #{start}-#{end_line} of #{total_lines}. " <>
           "Use offset=#{end_line + 1} to continue.]"}

      # Within limits — pass through unchanged
      true ->
        {:ok, content}
    end
  end

  # Truncates binary content at the last newline boundary before `max_bytes`.
  # This avoids splitting a line in the middle, which would confuse the LLM.
  defp truncate_at_line_boundary(content, max_bytes) do
    truncated = binary_part(content, 0, min(max_bytes, byte_size(content)))

    case :binary.matches(truncated, "\n") do
      [] ->
        truncated

      matches ->
        {last_pos, _} = List.last(matches)
        binary_part(truncated, 0, last_pos)
    end
  end
end
