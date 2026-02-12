defmodule Opal.Tool.Edit.Fuzzy do
  @moduledoc """
  Fuzzy text normalization for edit matching.

  When the LLM reproduces text for an edit, it often "corrects" invisible
  characters: smart quotes become straight quotes, em-dashes become hyphens,
  non-breaking spaces become regular spaces, and trailing whitespace is
  stripped. These transformations cause exact-match failures.

  This module applies progressive normalization to both the file content
  and the search string, then attempts matching in the normalized space.
  If a unique match is found, the edit targets the original (un-normalized)
  substring — so the file's encoding is respected.

  ## Normalization Pipeline

  1. Strip trailing whitespace from each line
  2. Curly/smart quotes → straight quotes
  3. En-dash, em-dash, math minus → ASCII hyphen
  4. Non-breaking/Unicode whitespace → regular space
  """

  # -- Public API -------------------------------------------------------------

  @doc """
  Normalizes text through the full pipeline.

  Useful for comparing two strings where invisible formatting differences
  might cause false mismatches.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(text) do
    text
    |> strip_trailing_whitespace()
    |> normalize_quotes()
    |> normalize_dashes()
    |> normalize_spaces()
  end

  @doc """
  Attempts a fuzzy match of `pattern` within `content`.

  Returns `{:ok, original_text}` where `original_text` is the actual
  substring from the un-normalized content that corresponds to the match.
  Returns `:no_match` if no match or multiple matches (ambiguous).
  """
  @spec fuzzy_find(String.t(), String.t()) :: {:ok, String.t()} | :no_match
  def fuzzy_find(content, pattern) do
    norm_pattern = normalize(pattern)
    norm_content = normalize(content)

    case count_occurrences(norm_content, norm_pattern) do
      # No match even after normalization
      0 ->
        :no_match

      # Unique match — map back to the original text
      1 ->
        {:ok, extract_original(content, norm_content, norm_pattern)}

      # Multiple matches — ambiguous, refuse to guess
      _n ->
        :no_match
    end
  end

  # -- Normalization functions ------------------------------------------------

  # Strips trailing whitespace from each line. The LLM's output never
  # includes trailing spaces or tabs, but source files often do.
  defp strip_trailing_whitespace(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.join("\n")
  end

  # Curly/smart single quotes → straight single quote
  # Curly/smart double quotes → straight double quote
  # Includes guillemets and low quotation marks.
  defp normalize_quotes(text) do
    text
    |> String.replace(~r/[\x{2018}\x{2019}\x{201A}\x{2039}\x{203A}]/u, "'")
    |> String.replace(~r/[\x{201C}\x{201D}\x{201E}\x{00AB}\x{00BB}]/u, "\"")
  end

  # En-dash (–), em-dash (—), horizontal bar (―), math minus (−) → hyphen (-)
  defp normalize_dashes(text) do
    String.replace(text, ~r/[\x{2013}\x{2014}\x{2015}\x{2212}]/u, "-")
  end

  # Non-breaking space, various Unicode spaces → regular ASCII space
  defp normalize_spaces(text) do
    String.replace(text, ~r/[\x{00A0}\x{2000}-\x{200A}\x{202F}\x{205F}\x{3000}]/u, " ")
  end

  # -- Helpers ----------------------------------------------------------------

  # Counts non-overlapping occurrences of `pattern` in `content`.
  defp count_occurrences(content, pattern) do
    content |> String.split(pattern) |> length() |> Kernel.-(1)
  end

  # Maps a match position in normalized space back to the original text.
  #
  # Strategy: split the normalized content at the pattern to find the
  # character offset of the match, then extract the same character span
  # from the original string. This works because normalization preserves
  # character count (each replacement is 1-for-1 in characters).
  defp extract_original(original, normalized, norm_pattern) do
    case String.split(normalized, norm_pattern, parts: 2) do
      [before, _after] ->
        start_chars = String.length(before)
        pattern_chars = String.length(norm_pattern)

        original
        |> String.graphemes()
        |> Enum.drop(start_chars)
        |> Enum.take(pattern_chars)
        |> Enum.join()

      # Shouldn't happen if count_occurrences returned 1, but be safe
      _ ->
        norm_pattern
    end
  end
end
