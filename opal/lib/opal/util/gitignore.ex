defmodule Opal.Gitignore do
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

    Enum.reduce(rules, false, fn rule, acc ->
      if matches_rule?(rule, normalized, is_dir), do: not rule.negated, else: acc
    end)
  end

  # ── Parsing ───────────────────────────────────────────────────────────

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
  defp strip_trailing_spaces(line), do: Regex.replace(~r/(?<!\\) +$/, line, "")

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
        if String.ends_with?(raw, "/"),
          do: {true, String.slice(raw, 0..-2//1)},
          else: {false, raw}

      %{pattern: pattern_to_regex(raw), negated: negated, dir_only: dir_only}
    end
  end

  # ── Pattern → Regex ───────────────────────────────────────────────────

  @spec pattern_to_regex(String.t()) :: Regex.t()
  defp pattern_to_regex(raw) do
    anchored? = String.starts_with?(raw, "/")
    raw = if anchored?, do: String.slice(raw, 1..-1//1), else: raw
    rooted? = anchored? or String.contains?(raw, "/")

    inner = raw |> tokenize() |> tokens_to_regex()

    regex_str = if rooted?, do: "^#{inner}$", else: "(?:^|/)#{inner}$"
    Regex.compile!(regex_str)
  end

  @spec tokenize(String.t()) :: [atom() | {:literal, String.t()}]
  defp tokenize(pattern), do: pattern |> String.split("/") |> build_tokens([], true)

  defp build_tokens([], acc, _first?), do: Enum.reverse(acc)

  defp build_tokens(["**" | rest], acc, true),
    do: build_tokens(rest, [:double_star_prefix | acc], false)

  defp build_tokens(["**"], acc, _first?), do: Enum.reverse([:double_star_suffix | acc])

  defp build_tokens(["**" | rest], acc, false),
    do: build_tokens(rest, [:double_star_middle | acc], false)

  defp build_tokens([part | rest], acc, _first?),
    do: build_tokens(rest, [{:literal, segment_to_regex(part)} | acc], false)

  @spec segment_to_regex(String.t()) :: String.t()
  defp segment_to_regex(segment) do
    segment |> String.graphemes() |> convert_chars([]) |> IO.iodata_to_binary()
  end

  defp convert_chars([], acc), do: Enum.reverse(acc)
  defp convert_chars(["*" | rest], acc), do: convert_chars(rest, ["[^/]*" | acc])
  defp convert_chars(["?" | rest], acc), do: convert_chars(rest, ["[^/]" | acc])

  defp convert_chars(["[" | rest], acc) do
    {class, remaining} = consume_char_class(rest, [])
    convert_chars(remaining, [class | acc])
  end

  defp convert_chars([ch | rest], acc), do: convert_chars(rest, [escape_char(ch) | acc])

  defp consume_char_class(["!" | rest], []), do: consume_char_class(rest, ["^"])

  defp consume_char_class(["]" | rest], inner),
    do: {"[" <> Enum.join(Enum.reverse(inner)) <> "]", rest}

  defp consume_char_class([ch | rest], inner), do: consume_char_class(rest, [ch | inner])
  defp consume_char_class([], inner), do: {"\\[" <> Enum.join(Enum.reverse(inner)), []}

  @spec tokens_to_regex([atom() | {:literal, String.t()}]) :: String.t()
  defp tokens_to_regex(tokens) do
    tokens = collapse_double_stars(tokens)
    ends_with_doublestar? = List.last(tokens) == :double_star_suffix

    regex =
      tokens
      |> Enum.reduce({[], false}, fn token, {parts, need_sep} ->
        case token do
          :double_star_prefix -> {["(?:.*/)?" | parts], false}
          :double_star_suffix -> {["/.*" | parts], false}
          :double_star_middle -> {["(?:/.*/|/)" | parts], false}
          {:literal, s} -> {[if(need_sep, do: "/" <> s, else: s) | parts], true}
        end
      end)
      |> elem(0)
      |> Enum.reverse()
      |> Enum.join()

    if ends_with_doublestar?, do: regex, else: regex <> "(?:/.*)?"
  end

  defp collapse_double_stars(tokens) do
    tokens
    |> Enum.reduce([], fn
      token, [] -> [token]
      :double_star_middle, [:double_star_prefix | _] = acc -> acc
      :double_star_suffix, [:double_star_prefix | rest] -> [:double_star_suffix | rest]
      :double_star_middle, [:double_star_middle | _] = acc -> acc
      :double_star_suffix, [:double_star_middle | rest] -> [:double_star_suffix | rest]
      token, acc -> [token | acc]
    end)
    |> Enum.reverse()
  end

  @regex_special ~r/[.+(){}|^$\\]/
  defp escape_char(ch), do: if(Regex.match?(@regex_special, ch), do: "\\#{ch}", else: ch)

  # ── Matching ──────────────────────────────────────────────────────────

  @spec matches_rule?(rule(), String.t(), boolean()) :: boolean()
  defp matches_rule?(rule, path, is_dir) do
    if rule.dir_only and not is_dir, do: false, else: Regex.match?(rule.pattern, path)
  end

  @spec normalize_path(String.t()) :: String.t()
  defp normalize_path(path), do: path |> String.replace("\\", "/") |> String.trim_leading("/")
end
