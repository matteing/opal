defmodule Opal.Tool.Hashline do
  @moduledoc """
  Hashline utilities for content-addressed line references.

  Every line is tagged with a short content hash so the LLM can reference
  specific lines without reproducing their full content. The format is:

      N:hash|content

  Where `N` is the 1-indexed line number and `hash` is a 2-character hex
  digest of the trimmed line content. The hash acts as a checksum — if the
  file changes, stale hashes won't match and the edit is rejected.

  ## Hash computation

  Uses `:erlang.phash2/2` of the trimmed line content, modulo 256, formatted
  as zero-padded lowercase hex. Empty lines always hash to the same value
  but are distinguished by line number.
  """

  @doc """
  Computes a 2-character hex hash for a single line's content.

      iex> Opal.Tool.Hashline.line_hash("  return 42;")
      "8a"  # example — actual value depends on phash2
  """
  @spec line_hash(String.t()) :: String.t()
  def line_hash(line) do
    line
    |> String.trim()
    |> :erlang.phash2(256)
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(2, "0")
  end

  @doc """
  Tags lines with `N:hash|` prefixes.

  Accepts raw file content and an optional starting line number (default 1).
  Returns the tagged string.
  """
  @spec tag_lines(String.t(), pos_integer()) :: String.t()
  def tag_lines(content, start_line \\ 1) do
    content
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> Enum.with_index(start_line)
    |> Enum.map_join("\n", fn {line, num} ->
      hash = line_hash(line)
      "#{num}:#{hash}|#{line}"
    end)
  end

  @doc """
  Parses a `"N:hash"` anchor string into `{line_number, hash}`.

  Returns `{:ok, {line, hash}}` or `{:error, reason}`.
  """
  @spec parse_anchor(String.t()) :: {:ok, {pos_integer(), String.t()}} | {:error, String.t()}
  def parse_anchor(anchor) when is_binary(anchor) do
    case String.split(anchor, ":", parts: 2) do
      [line_str, hash] when byte_size(hash) > 0 ->
        case Integer.parse(line_str) do
          {line, ""} when line > 0 -> {:ok, {line, String.downcase(hash)}}
          _ -> {:error, "Invalid line number in anchor: #{anchor}"}
        end

      _ ->
        {:error, "Invalid anchor format '#{anchor}' — expected 'N:hash' (e.g. '5:a3')"}
    end
  end

  @doc """
  Validates that line `line_num` in `lines` (0-indexed list) has the expected hash.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_hash([String.t()], pos_integer(), String.t()) :: :ok | {:error, String.t()}
  def validate_hash(lines, line_num, expected_hash) do
    idx = line_num - 1

    cond do
      idx < 0 or idx >= length(lines) ->
        {:error, "Line #{line_num} is out of range (file has #{length(lines)} lines)"}

      true ->
        actual = line_hash(Enum.at(lines, idx))

        if actual == expected_hash do
          :ok
        else
          {:error,
           "Hash mismatch on line #{line_num}: expected #{expected_hash}, got #{actual}. File may have changed since last read."}
        end
    end
  end
end
