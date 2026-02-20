defmodule Opal.Diff do
  @moduledoc """
  Pure utility for computing structured diffs between file contents using Myers algorithm.

  Returns a structured diff with hunks containing line-by-line operations (eq/del/ins)
  suitable for display or serialization over RPC.
  """

  @type line_op :: :eq | :del | :ins

  @typedoc "A single annotated diff line with op, text, and line numbers."
  @type diff_line :: %{
          op: line_op(),
          text: String.t(),
          old_no: pos_integer() | nil,
          new_no: pos_integer() | nil
        }

  @type hunk :: %{
          old_start: pos_integer(),
          new_start: pos_integer(),
          lines: [diff_line()]
        }

  @type t :: %{
          path: String.t(),
          lines_removed: non_neg_integer(),
          lines_added: non_neg_integer(),
          hunks: [hunk()]
        }

  @doc """
  Compute a structured diff between old and new file content.

  ## Parameters

  - `old_content` - Original file content (or `nil` for new files)
  - `new_content` - New file content
  - `path` - Relative file path
  - `context` - Number of surrounding equal lines to include in each hunk (default: 3)

  ## Returns

  A map containing the diff metadata and hunks with annotated lines.

  ## Examples

      iex> Opal.Diff.compute("line1\\nline2\\n", "line1\\nmodified\\n", "test.txt")
      %{
        path: "test.txt",
        lines_removed: 1,
        lines_added: 1,
        hunks: [
          %{
            old_start: 1,
            new_start: 1,
            lines: [
              %{op: :eq, old_no: 1, new_no: 1, text: "line1"},
              %{op: :del, old_no: 2, text: "line2"},
              %{op: :ins, new_no: 2, text: "modified"}
            ]
          }
        ]
      }
  """
  @spec compute(String.t() | nil, String.t(), String.t(), non_neg_integer()) :: t()
  def compute(old_content, new_content, path, context \\ 3) do
    old_lines = split_lines(old_content || "")
    new_lines = split_lines(new_content)

    diff = List.myers_difference(old_lines, new_lines)
    annotated = annotate_lines(diff)

    hunks = build_hunks(annotated, context)
    {lines_removed, lines_added} = count_changes(annotated)

    %{
      path: path,
      lines_removed: lines_removed,
      lines_added: lines_added,
      hunks: hunks
    }
  end

  @spec split_lines(String.t()) :: [String.t()]
  defp split_lines(content) do
    String.split(content, "\n")
  end

  @spec annotate_lines([{:eq | :del | :ins, [String.t()]}]) :: [diff_line()]
  defp annotate_lines(diff) do
    {annotated, _, _} =
      Enum.reduce(diff, {[], 1, 1}, fn
        {:eq, lines}, {acc, old_no, new_no} ->
          new_lines =
            Enum.with_index(lines, fn line, idx ->
              %{op: :eq, old_no: old_no + idx, new_no: new_no + idx, text: line}
            end)

          {acc ++ new_lines, old_no + length(lines), new_no + length(lines)}

        {:del, lines}, {acc, old_no, new_no} ->
          new_lines =
            Enum.with_index(lines, fn line, idx ->
              %{op: :del, old_no: old_no + idx, text: line}
            end)

          {acc ++ new_lines, old_no + length(lines), new_no}

        {:ins, lines}, {acc, old_no, new_no} ->
          new_lines =
            Enum.with_index(lines, fn line, idx ->
              %{op: :ins, new_no: new_no + idx, text: line}
            end)

          {acc ++ new_lines, old_no, new_no + length(lines)}
      end)

    annotated
  end

  @spec count_changes([diff_line()]) :: {non_neg_integer(), non_neg_integer()}
  defp count_changes(annotated) do
    Enum.reduce(annotated, {0, 0}, fn
      %{op: :del}, {removed, added} -> {removed + 1, added}
      %{op: :ins}, {removed, added} -> {removed, added + 1}
      _, acc -> acc
    end)
  end

  @spec build_hunks([diff_line()], non_neg_integer()) :: [hunk()]
  defp build_hunks([], _context), do: []

  defp build_hunks(annotated, context) do
    # Find all changed line indices
    changed_indices =
      annotated
      |> Enum.with_index()
      |> Enum.filter(fn {line, _idx} -> line.op != :eq end)
      |> Enum.map(fn {_line, idx} -> idx end)

    if Enum.empty?(changed_indices) do
      []
    else
      # Build ranges for each change with context
      ranges =
        changed_indices
        |> Enum.map(fn idx ->
          {max(0, idx - context), min(length(annotated) - 1, idx + context)}
        end)
        |> merge_overlapping_ranges()

      # Convert ranges to hunks
      Enum.map(ranges, fn {start_idx, end_idx} ->
        lines = Enum.slice(annotated, start_idx..end_idx)

        old_start =
          Enum.find_value(lines, fn
            %{old_no: no} -> no
            _ -> nil
          end) || 1

        new_start =
          Enum.find_value(lines, fn
            %{new_no: no} -> no
            _ -> nil
          end) || 1

        %{
          old_start: old_start,
          new_start: new_start,
          lines: lines
        }
      end)
    end
  end

  @spec merge_overlapping_ranges([{non_neg_integer(), non_neg_integer()}]) :: [
          {non_neg_integer(), non_neg_integer()}
        ]
  defp merge_overlapping_ranges([]), do: []

  defp merge_overlapping_ranges(ranges) do
    sorted = Enum.sort(ranges)

    [first | rest] =
      Enum.reduce(sorted, [], fn {s, e}, acc ->
        case acc do
          [] ->
            [{s, e}]

          [{last_s, last_e} | tail] ->
            if s <= last_e + 1 do
              # Overlapping or adjacent, merge
              [{last_s, max(e, last_e)} | tail]
            else
              # Non-overlapping, add new range
              [{s, e} | acc]
            end
        end
      end)

    Enum.reverse([first | rest])
  end
end
