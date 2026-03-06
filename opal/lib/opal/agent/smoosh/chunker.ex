defmodule Opal.Agent.Smoosh.Chunker do
  @moduledoc """
  Splits content into searchable chunks for FTS5 indexing.

  Three strategies based on detected content type:
  - **Markdown** — split by headings, keep code blocks intact
  - **JSON** — walk object tree, use key paths as titles
  - **Plain text** — blank-line splitting or fixed line groups

  All chunks are capped at `@max_chunk_bytes` (4 KB).
  """

  @max_chunk_bytes 4_096
  @overlap_lines 2

  @type chunk :: %{title: String.t(), content: String.t(), content_type: :code | :prose}

  @doc """
  Split `content` into chunks. Returns a list of `%{title, content, content_type}` maps.

  Options:
  - `:label` — source label used as fallback title prefix (default: `"content"`)
  - `:max_bytes` — override max chunk size (default: #{@max_chunk_bytes})
  """
  @spec chunk(String.t(), keyword()) :: [chunk()]
  def chunk(content, opts \\ []) do
    label = Keyword.get(opts, :label, "content")
    max = Keyword.get(opts, :max_bytes, @max_chunk_bytes)

    case detect_type(content) do
      :markdown -> chunk_markdown(content, label, max)
      :json -> chunk_json(content, label, max)
      :plaintext -> chunk_plaintext(content, label, max)
    end
  end

  @doc "Detect content type from content."
  @spec detect_type(String.t()) :: :markdown | :json | :plaintext
  def detect_type(content) do
    trimmed = String.trim_leading(content)

    cond do
      json_content?(trimmed) -> :json
      markdown_content?(trimmed) -> :markdown
      true -> :plaintext
    end
  end

  # ── Markdown Chunking ──

  defp chunk_markdown(content, label, max) do
    content
    |> split_markdown_sections()
    |> Enum.flat_map(fn {title, body, content_type} ->
      title = if title == "", do: label, else: title

      if byte_size(body) <= max do
        [%{title: title, content: body, content_type: content_type}]
      else
        split_oversized(body, title, max)
        |> Enum.map(&%{title: &1.title, content: &1.content, content_type: content_type})
      end
    end)
    |> reject_empty()
  end

  defp split_markdown_sections(content) do
    lines = String.split(content, "\n")
    {sections, current_title, current_lines, current_type} = split_md_sections_acc(lines)

    sections
    |> List.insert_at(
      -1,
      {current_title, Enum.join(Enum.reverse(current_lines), "\n"), current_type}
    )
  end

  defp split_md_sections_acc(lines) do
    Enum.reduce(lines, {[], "", [], :prose}, fn line, {sections, title, acc, content_type} ->
      cond do
        heading?(line) ->
          section = {title, Enum.join(Enum.reverse(acc), "\n"), content_type}
          new_type = if in_code_block?(acc), do: :code, else: :prose
          {[section | sections], extract_heading(line), [], new_type}

        true ->
          new_type = update_content_type(line, acc, content_type)
          {sections, title, [line | acc], new_type}
      end
    end)
  end

  defp heading?(line), do: Regex.match?(~r/^\#{1,4}\s+\S/, line)

  defp extract_heading(line) do
    line |> String.replace(~r/^#+\s+/, "") |> String.trim()
  end

  defp in_code_block?(lines) do
    lines
    |> Enum.reverse()
    |> Enum.count(&String.starts_with?(&1, "```"))
    |> rem(2) == 1
  end

  defp update_content_type(line, acc, current) do
    cond do
      String.starts_with?(line, "```") and not in_code_block?(acc) -> :code
      String.starts_with?(line, "```") and in_code_block?(acc) -> :prose
      true -> current
    end
  end

  # ── JSON Chunking ──

  defp chunk_json(content, label, max) do
    case Jason.decode(content) do
      {:ok, decoded} ->
        walk_json(decoded, label, max)

      {:error, _} ->
        # Malformed JSON — fall back to plaintext
        chunk_plaintext(content, label, max)
    end
  end

  defp walk_json(value, path, max) when is_map(value) do
    entries = Map.to_list(value)

    if json_size(value) <= max do
      [%{title: path, content: Jason.encode!(value, pretty: true), content_type: :prose}]
    else
      Enum.flat_map(entries, fn {key, val} ->
        walk_json(val, "#{path}.#{key}", max)
      end)
    end
  end

  defp walk_json(value, path, max) when is_list(value) do
    encoded = Jason.encode!(value, pretty: true)

    if byte_size(encoded) <= max do
      [%{title: path, content: encoded, content_type: :prose}]
    else
      value
      |> Enum.with_index()
      |> batch_json_array(path, max)
    end
  end

  defp walk_json(value, path, _max) do
    [%{title: path, content: to_string(value), content_type: :prose}]
  end

  defp batch_json_array(indexed_items, path, max) do
    {batches, current_batch, current_size} =
      Enum.reduce(indexed_items, {[], [], 0}, fn {item, idx}, {batches, batch, size} ->
        item_json = Jason.encode!(item, pretty: true)
        item_size = byte_size(item_json)

        if size + item_size > max and batch != [] do
          {[Enum.reverse(batch) | batches], [{item, idx}], item_size}
        else
          {batches, [{item, idx} | batch], size + item_size}
        end
      end)

    all_batches =
      if current_batch == [] do
        Enum.reverse(batches)
      else
        Enum.reverse([Enum.reverse(current_batch) | batches])
      end

    _ = current_size

    Enum.map(all_batches, fn items ->
      {_item, start_idx} = hd(items)
      end_idx = start_idx + length(items) - 1
      content = items |> Enum.map(fn {item, _} -> item end) |> Jason.encode!(pretty: true)
      title = "#{path}[#{start_idx}..#{end_idx}]"
      %{title: title, content: content, content_type: :prose}
    end)
  end

  defp json_size(value), do: value |> Jason.encode!() |> byte_size()

  # ── Plain Text Chunking ──

  defp chunk_plaintext(content, label, max) do
    paragraphs = String.split(content, ~r/\n\s*\n/, trim: true)

    if length(paragraphs) > 1 do
      chunk_paragraphs(paragraphs, label, max)
    else
      chunk_fixed_lines(content, label, max)
    end
  end

  defp chunk_paragraphs(paragraphs, label, max) do
    paragraphs
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {para, idx} ->
      title = "#{label} §#{idx}"

      if byte_size(para) <= max do
        [%{title: title, content: para, content_type: :prose}]
      else
        split_oversized(para, title, max)
      end
    end)
    |> reject_empty()
  end

  defp chunk_fixed_lines(content, label, max) do
    lines = String.split(content, "\n")
    lines_per_chunk = max(1, div(max, avg_line_bytes(lines)))

    lines
    |> Enum.chunk_every(lines_per_chunk, max(1, lines_per_chunk - @overlap_lines))
    |> Enum.with_index(1)
    |> Enum.map(fn {chunk_lines, idx} ->
      %{
        title:
          "#{label} lines #{(idx - 1) * (lines_per_chunk - @overlap_lines) + 1}–#{(idx - 1) * (lines_per_chunk - @overlap_lines) + length(chunk_lines)}",
        content: Enum.join(chunk_lines, "\n"),
        content_type: :prose
      }
    end)
    |> reject_empty()
  end

  defp avg_line_bytes(lines) do
    total = lines |> Enum.map(&byte_size/1) |> Enum.sum()
    # +1 for newline per line, min 10 to avoid degenerate cases
    max(10, div(total + length(lines), max(1, length(lines))))
  end

  # ── Shared Helpers ──

  defp split_oversized(text, title, max) do
    lines = String.split(text, "\n")

    # If any single line exceeds max, split at byte boundaries
    lines =
      Enum.flat_map(lines, fn line ->
        if byte_size(line) > max do
          split_long_line(line, max)
        else
          [line]
        end
      end)

    lines
    |> Enum.chunk_while(
      {"", 0, 1},
      fn line, {buf, size, part} ->
        line_size = byte_size(line) + 1

        if size + line_size > max and buf != "" do
          chunk = %{title: "#{title} (part #{part})", content: buf, content_type: :prose}
          {:cont, chunk, {line, line_size, part + 1}}
        else
          sep = if buf == "", do: "", else: "\n"
          {:cont, {buf <> sep <> line, size + line_size, part}}
        end
      end,
      fn {buf, _, part} ->
        if buf == "" do
          {:cont, []}
        else
          {:cont, %{title: "#{title} (part #{part})", content: buf, content_type: :prose},
           {"", 0, part + 1}}
        end
      end
    )
  end

  defp reject_empty(chunks) do
    Enum.reject(chunks, fn %{content: c} -> String.trim(c) == "" end)
  end

  defp split_long_line(line, max) do
    line
    |> :binary.bin_to_list()
    |> Enum.chunk_every(max)
    |> Enum.map(&:binary.list_to_bin/1)
  end

  defp json_content?(trimmed) do
    (String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[")) and
      match?({:ok, _}, Jason.decode(trimmed))
  end

  defp markdown_content?(trimmed) do
    String.starts_with?(trimmed, "#") or
      Regex.match?(~r/^```/m, trimmed) or
      Regex.match?(~r/^\*\*[^*]+\*\*/m, trimmed) or
      Regex.match?(~r/^\[.+\]\(.+\)/m, trimmed)
  end
end
