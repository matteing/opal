defmodule Opal.Tool.Encoding do
  @moduledoc """
  Shared encoding utilities for tool modules.

  Handles two invisible encoding artifacts that cause tool failures:

  1. **UTF-8 BOM** (Byte Order Mark) — a 3-byte prefix (`EF BB BF`) that some
     editors add. The LLM never sees or reproduces it, causing edit mismatches.

  2. **CRLF line endings** — Windows-style `\\r\\n` that the LLM always omits
     from its `old_string`, breaking exact-match edits.

  Both are stripped before matching and restored after editing to preserve
  the file's original encoding.
  """

  # The UTF-8 BOM: 3 bytes that precede file content in some editors.
  @bom <<0xEF, 0xBB, 0xBF>>

  # -- BOM handling -----------------------------------------------------------

  @doc """
  Strips a UTF-8 BOM if present at the start of content.

  Returns `{had_bom?, content_without_bom}` so callers can restore it later.
  """
  @spec strip_bom(binary()) :: {boolean(), binary()}
  def strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: {true, rest}
  def strip_bom(content), do: {false, content}

  @doc """
  Restores the UTF-8 BOM prefix if the original file had one.
  """
  @spec restore_bom(binary(), boolean()) :: binary()
  def restore_bom(content, true), do: @bom <> content
  def restore_bom(content, false), do: content

  # -- Line-ending handling ---------------------------------------------------

  @doc """
  Normalizes CRLF (`\\r\\n`) to LF (`\\n`) for consistent matching.

  Returns `{had_crlf?, normalized_content}` so callers can restore later.
  Only flags `had_crlf?` if the content actually contains `\\r\\n`.
  """
  @spec normalize_line_endings(binary()) :: {boolean(), binary()}
  def normalize_line_endings(content) do
    if String.contains?(content, "\r\n") do
      {true, String.replace(content, "\r\n", "\n")}
    else
      {false, content}
    end
  end

  @doc """
  Restores CRLF line endings if the original file used them.
  """
  @spec restore_line_endings(binary(), boolean()) :: binary()
  def restore_line_endings(content, true), do: String.replace(content, "\n", "\r\n")
  def restore_line_endings(content, false), do: content
end
