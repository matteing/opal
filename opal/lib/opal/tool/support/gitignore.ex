defmodule Opal.Tool.Gitignore do
  @moduledoc """
  Parses and matches `.gitignore` patterns.

  Supports loading `.gitignore` files from directories and checking whether
  a given path should be ignored. Handles hierarchical `.gitignore` files
  (nested in subdirectories override parent patterns).

  Implements the full gitignore specification including:
  - Wildcards (`*`, `?`, `[...]`)
  - Double-star `**` patterns
  - Negation with `!`
  - Directory-only patterns (trailing `/`)
  - Hierarchical pattern merging
  """

  @type rule :: %{
          pattern: Regex.t(),
          negated: boolean(),
          dir_only: boolean()
        }

  @typedoc "A compiled set of gitignore rules rooted at a directory."
  @type t :: %__MODULE__{
          rules: [rule()],
          root: String.t()
        }

  defstruct rules: [], root: "."

  @doc """
  Loads `.gitignore` from the given directory.

  Returns a `%Gitignore{}` struct. If no `.gitignore` exists, returns an
  empty struct that matches nothing.
  """
  @spec load(String.t()) :: t()
  def load(dir) do
    path = Path.join(dir, ".gitignore")

    case File.read(path) do
      {:ok, content} -> parse(content, dir)
      {:error, _} -> %__MODULE__{root: dir}
    end
  end

  @doc """
  Parses gitignore content into a `%Gitignore{}`.

  `root` is the directory the gitignore is relative to.
  """
  @spec parse(String.t(), String.t()) :: t()
  def parse(content, root) do
    rules =
      content
      |> String.split(~r/\r?\n/)
      |> Enum.flat_map(fn line ->
        case parse_line(line) do
          nil -> []
          rule -> [rule]
        end
      end)

    %__MODULE__{rules: rules, root: root}
  end

  @doc """
  Merges a child gitignore into a parent.

  Child rules are appended so they evaluate after parent rules,
  matching gitignore's last-matching-rule-wins semantics.
  """
  @spec merge(t(), t()) :: t()
  def merge(parent, child) do
    %__MODULE__{
      rules: parent.rules ++ child.rules,
      root: parent.root
    }
  end

  @doc """
  Returns `true` if the given relative path should be ignored.

  `is_dir` indicates whether the path is a directory (needed for
  dir-only patterns with trailing `/`). The path should be relative
  to the gitignore root.
  """
  @spec ignored?(t(), String.t(), boolean()) :: boolean()
  def ignored?(%__MODULE__{rules: rules}, rel_path, is_dir \\ false) do
    normalized = normalize_path(rel_path)

    # Last matching rule wins
    Enum.reduce(rules, false, fn rule, acc ->
      if matches_rule?(rule, normalized, is_dir) do
        not rule.negated
      else
        acc
      end
    end)
  end

  # -- Parsing ----------------------------------------------------------------

  @spec parse_line(String.t()) :: rule() | nil
  defp parse_line(line) do
    line = strip_trailing_spaces(line)

    cond do
      line == "" -> nil
      String.starts_with?(line, "#") -> nil
      true -> parse_pattern(line)
    end
  end

  @spec strip_trailing_spaces(String.t()) :: String.t()
  defp strip_trailing_spaces(line) do
    # Strip trailing unescaped spaces.  "foo\ " keeps the space.
    Regex.replace(~r/(?<!\\) +$/, line, "")
  end

  @spec parse_pattern(String.t()) :: rule() | nil
  defp parse_pattern(raw) do
    {negated, raw} =
      case raw do
        "!" <> rest -> {true, rest}
        _ -> {false, raw}
      end

    if raw == "" do
      nil
    else
      {dir_only, raw} =
        if String.ends_with?(raw, "/") do
          {true, String.slice(raw, 0..-2//1)}
        else
          {false, raw}
        end

      regex = pattern_to_regex(raw)

      %{pattern: regex, negated: negated, dir_only: dir_only}
    end
  end

  # -- Pattern → Regex --------------------------------------------------------
  #
  # Gitignore matching rules:
  #
  #   - A pattern without `/` (now that trailing `/` is stripped) matches the
  #     **basename** of any file or directory at any depth.
  #   - A pattern containing `/` matches relative to the gitignore root.
  #   - Leading `/` anchors to the root (then removed).
  #   - `*` matches anything except `/`.
  #   - `?` matches any single char except `/`.
  #   - `[...]` character classes, `[!...]` is negated.
  #   - `**/` at start = any leading directories (including none).
  #   - `/**` at end   = everything inside.
  #   - `/**/` middle  = zero or more directories.

  @spec pattern_to_regex(String.t()) :: Regex.t()
  defp pattern_to_regex(raw) do
    anchored? = String.starts_with?(raw, "/")
    raw = if anchored?, do: String.slice(raw, 1..-1//1), else: raw

    # A pattern is "rooted" (matches full path, not basename) if it contains
    # a `/` or was explicitly anchored with a leading `/`.
    rooted? = anchored? or String.contains?(raw, "/")

    # Tokenise the pattern into segments, handling ** specially.
    tokens = tokenize(raw)
    inner = tokens_to_regex(tokens)

    regex_str =
      if rooted? do
        "^#{inner}$"
      else
        "(?:^|/)#{inner}$"
      end

    Regex.compile!(regex_str)
  end

  # Tokenize a gitignore pattern into a list of tagged segments.
  # Splits on "/" and identifies ** tokens:
  #   :double_star_prefix  — **/ at the start
  #   :double_star_suffix  — /** at the end
  #   :double_star_middle  — /**/ in the middle
  #   {:literal, regex}    — a path segment converted to regex

  @spec tokenize(String.t()) :: [atom() | {:literal, String.t()}]
  defp tokenize(pattern) do
    parts = String.split(pattern, "/")
    build_tokens(parts, [], _first? = true)
  end

  defp build_tokens([], acc, _first?), do: Enum.reverse(acc)

  defp build_tokens(["**" | rest], acc, true) do
    build_tokens(rest, [:double_star_prefix | acc], false)
  end

  defp build_tokens(["**"], acc, _first?) do
    Enum.reverse([:double_star_suffix | acc])
  end

  defp build_tokens(["**" | rest], acc, false) do
    build_tokens(rest, [:double_star_middle | acc], false)
  end

  defp build_tokens([part | rest], acc, _first?) do
    token = {:literal, segment_to_regex(part)}
    build_tokens(rest, [token | acc], false)
  end

  # Convert a single path segment (between slashes) to a regex fragment.
  @spec segment_to_regex(String.t()) :: String.t()
  defp segment_to_regex(segment) do
    segment
    |> String.graphemes()
    |> convert_segment_chars([])
    |> IO.iodata_to_binary()
  end

  defp convert_segment_chars([], acc), do: Enum.reverse(acc)

  defp convert_segment_chars(["*" | rest], acc) do
    convert_segment_chars(rest, ["[^/]*" | acc])
  end

  defp convert_segment_chars(["?" | rest], acc) do
    convert_segment_chars(rest, ["[^/]" | acc])
  end

  defp convert_segment_chars(["[" | rest], acc) do
    {class, remaining} = consume_char_class(rest, [])
    convert_segment_chars(remaining, [class | acc])
  end

  defp convert_segment_chars([ch | rest], acc) do
    convert_segment_chars(rest, [escape_char(ch) | acc])
  end

  # Consume a [...] character class. Handles [!...] for negation.
  defp consume_char_class(["!" | rest], []) do
    consume_char_class(rest, ["^"])
  end

  defp consume_char_class(["]" | rest], inner) do
    {"[" <> Enum.join(Enum.reverse(inner)) <> "]", rest}
  end

  defp consume_char_class([ch | rest], inner) do
    consume_char_class(rest, [ch | inner])
  end

  defp consume_char_class([], inner) do
    # Unterminated bracket — treat as literal
    {"\\[" <> Enum.join(Enum.reverse(inner)), []}
  end

  # Build a regex string from tokens.
  # Each token type contributes a regex fragment; literals are joined with `/`.
  @spec tokens_to_regex([atom() | {:literal, String.t()}]) :: String.t()
  defp tokens_to_regex(tokens) do
    # Normalize: collapse consecutive ** tokens.
    # e.g. [prefix, middle, literal] → [prefix, literal]
    tokens = collapse_double_stars(tokens)

    # Check if pattern ends with ** (suffix) — if so, we don't add our own
    # trailing child matcher since the suffix already handles it.
    ends_with_doublestar? = List.last(tokens) == :double_star_suffix

    regex =
      tokens
      |> Enum.reduce({[], false}, fn token, {parts, need_sep} ->
        case token do
          :double_star_prefix ->
            # Matches zero or more leading directory components.
            # "(?:.*/)?" already includes the trailing slash.
            {["(?:.*/)?" | parts], false}

          :double_star_suffix ->
            # Matches everything inside (requires the leading slash + content).
            {["/.*" | parts], false}

          :double_star_middle ->
            # Matches zero or more middle directories including the separators.
            # `a/**/b` → `a` + middle + `b` should match `a/b`, `a/x/b`, `a/x/y/b`.
            # Always includes at least one `/` to separate the surrounding segments.
            {["(?:/.*/|/)" | parts], false}

          {:literal, s} ->
            if need_sep do
              {["/" <> s | parts], true}
            else
              {[s | parts], true}
            end
        end
      end)
      |> elem(0)
      |> Enum.reverse()
      |> Enum.join()

    # Append an optional child path matcher so that ignoring "foo" also
    # matches "foo/bar/baz". Skip if the pattern already ends with a
    # double-star suffix which handles this.
    if ends_with_doublestar? do
      regex
    else
      regex <> "(?:/.*)?"
    end
  end

  # Collapse consecutive double-star tokens. Multiple adjacent `**` segments
  # are equivalent to a single one. This prevents regex issues like
  # `(?:.*/)? (?:/.*/|/)` which would require a mandatory `/`.
  defp collapse_double_stars(tokens) do
    tokens
    |> Enum.reduce([], fn
      token, [] ->
        [token]

      # Absorb middle/suffix after prefix (prefix already matches everything)
      :double_star_middle, [:double_star_prefix | _] = acc ->
        acc

      :double_star_suffix, [:double_star_prefix | _] = acc ->
        # prefix + suffix → just suffix (matches everything everywhere)
        [:double_star_suffix | tl(acc)]

      # Absorb adjacent middles
      :double_star_middle, [:double_star_middle | _] = acc ->
        acc

      # Absorb suffix after middle
      :double_star_suffix, [:double_star_middle | rest] ->
        [:double_star_suffix | rest]

      token, acc ->
        [token | acc]
    end)
    |> Enum.reverse()
  end

  @regex_special ~r/[.+(){}|^$\\]/
  defp escape_char(ch) do
    if Regex.match?(@regex_special, ch), do: "\\#{ch}", else: ch
  end

  # -- Matching ---------------------------------------------------------------

  @spec matches_rule?(rule(), String.t(), boolean()) :: boolean()
  defp matches_rule?(rule, path, is_dir) do
    if rule.dir_only and not is_dir do
      false
    else
      Regex.match?(rule.pattern, path)
    end
  end

  @spec normalize_path(String.t()) :: String.t()
  defp normalize_path(path) do
    path
    |> String.replace("\\", "/")
    |> String.trim_leading("/")
  end
end
