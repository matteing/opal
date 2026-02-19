defmodule Opal.Tool.Grep do
  @moduledoc """
  Cross-platform regex search across files.

  Returns matching lines in the same hashline-tagged format as `read_file`,
  so results are immediately usable with `edit_file`. Walks directories
  recursively, skipping binary files and common noise directories.

  ## Output Format

  Results are grouped by file path. Each matching line includes contextual
  surrounding lines, all tagged with `N:hash|content`:

      ## path/to/file.ex
      10:a3|  defp helper do
      11:f1|    :ok    ← match
      12:0e|  end

  ## Exclusions

  The following directories are always skipped to avoid noise:

  - `.git`, `.hg`, `.svn` — version control internals
  - `_build`, `deps`, `node_modules` — build artifacts
  - `.elixir_ls`, `.vscode` — editor metadata

  Additionally, `.gitignore` files are respected. Patterns in `.gitignore`
  at the search root (and nested `.gitignore` files in subdirectories) are
  parsed and applied during directory traversal, so ignored files and
  directories are skipped automatically.

  Set `no_ignore: true` to bypass `.gitignore` rules and search all
  non-binary files (hardcoded skip directories like `.git` are still
  excluded).

  Binary files (containing null bytes) are silently skipped.
  """

  @behaviour Opal.Tool

  @dialyzer {:no_opaque, [do_walk_dir: 6, walk_dir: 6]}

  alias Opal.{FileIO, Gitignore, Hashline}
  alias Opal.Tool.Args, as: ToolArgs

  # Directories that almost never contain interesting source code.
  @skip_dirs MapSet.new(~w(
    .git .hg .svn
    _build deps node_modules
    .elixir_ls .vscode .idea
    __pycache__ .mypy_cache
    vendor .bundle
    tmp
  ))

  # -- Truncation limits ------------------------------------------------------
  @max_results_default 50
  @max_context_default 2
  @max_output_bytes 50 * 1024
  @max_depth 25

  # Parallelism: only fan out when there are enough files to justify it.
  @parallel_threshold 4
  @max_concurrency System.schedulers_online()

  @args_schema [
    pattern: [type: :string, required: true],
    path: [type: :string, default: "."],
    include: [type: :string],
    context_lines: [type: :integer, default: @max_context_default],
    max_results: [type: :integer, default: @max_results_default],
    no_ignore: [type: :boolean, default: false]
  ]

  @impl true
  @spec name() :: String.t()
  def name, do: "grep"

  @impl true
  @spec description() :: String.t()
  def description,
    do:
      "Search file contents with a regex pattern. " <>
        "Returns matching lines with hashline tags compatible with edit_file."

  @impl true
  def meta(%{"pattern" => pat}), do: "Grep #{pat}"
  def meta(_), do: "Grep"

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{
          "type" => "string",
          "description" => "Regex pattern to search for (Elixir/PCRE syntax)"
        },
        "path" => %{
          "type" => "string",
          "description" =>
            "File or directory to search, relative to working dir. Defaults to working dir root."
        },
        "include" => %{
          "type" => "string",
          "description" =>
            "Glob to filter filenames (e.g. \"*.ex\", \"*.{ex,exs}\"). Applies to the basename only."
        },
        "context_lines" => %{
          "type" => "integer",
          "description" => "Lines of surrounding context per match (default: 2)"
        },
        "max_results" => %{
          "type" => "integer",
          "description" =>
            "Maximum number of matching lines returned across all files (default: 50)"
        },
        "no_ignore" => %{
          "type" => "boolean",
          "description" =>
            "When true, search files even if they are excluded by .gitignore rules (default: false)"
        }
      },
      "required" => ["pattern"]
    }
  end

  @impl true
  @spec execute(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(args, %{working_dir: working_dir} = context) when is_map(args) do
    with {:ok, opts} <-
           ToolArgs.validate(args, @args_schema,
             required_message: "Missing required parameter: pattern"
           ),
         {:ok, regex} <- compile_regex(opts[:pattern]) do
      ctx_lines = opts[:context_lines] |> Opal.Util.Number.clamp(0, 10)
      max_results = opts[:max_results] |> Opal.Util.Number.clamp(1, 500)

      case FileIO.resolve_path(opts[:path], working_dir,
             allow_bases: FileIO.allowed_bases(context)
           ) do
        {:ok, resolved} ->
          do_search(
            resolved,
            regex,
            Keyword.get(opts, :include),
            ctx_lines,
            max_results,
            working_dir,
            opts[:no_ignore]
          )

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def execute(%{"pattern" => _}, _context), do: {:error, "Missing working_dir in context"}
  def execute(_args, _context), do: {:error, "Missing required parameter: pattern"}

  defp compile_regex(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> {:ok, regex}
      {:error, {reason, _pos}} -> {:error, "Invalid regex pattern: #{reason}"}
    end
  end

  # -- Search implementation --------------------------------------------------

  defp do_search(resolved, regex, include, ctx_lines, max_results, working_dir, no_ignore) do
    glob = Opal.Platform.compile_glob(include)

    files = collect_files(resolved, glob, no_ignore)

    {results, total_matches, capped?} =
      search_files(files, regex, ctx_lines, max_results, working_dir)

    if results == [] do
      {:ok, "No matches found."}
    else
      output = format_results(results, total_matches, capped?)
      {:ok, maybe_truncate(output)}
    end
  end

  # -- File collection --------------------------------------------------------

  defp collect_files(path, glob, no_ignore) do
    if File.regular?(path) do
      if Opal.Platform.matches_glob?(Path.basename(path), glob), do: [path], else: []
    else
      gitignore = if no_ignore, do: %Gitignore{root: path}, else: Gitignore.load(path)
      walk_dir(path, glob, 0, MapSet.new(), gitignore, no_ignore)
    end
  end

  # Walks directories with depth limiting and symlink-loop protection.
  # `visited` tracks real (resolved) directory paths to break cycles.
  # `gitignore` accumulates rules from nested .gitignore files.
  # `no_ignore` bypasses .gitignore rules when true.
  defp walk_dir(dir, glob, depth, visited, gitignore, no_ignore) do
    if depth > @max_depth do
      []
    else
      do_walk_dir(dir, glob, depth, visited, gitignore, no_ignore)
    end
  end

  defp do_walk_dir(dir, glob, depth, visited, gitignore, no_ignore) do
    # Resolve symlinks to detect cycles on all platforms
    real_dir = Path.expand(dir)

    if MapSet.member?(visited, real_dir) do
      []
    else
      visited = MapSet.put(visited, real_dir)

      # Merge nested .gitignore when descending into subdirectories.
      # The root .gitignore is already loaded in collect_files, so skip
      # re-reading it at depth 0. Skip entirely when no_ignore is set.
      gitignore =
        if not no_ignore and depth > 0 do
          case File.read(Path.join(dir, ".gitignore")) do
            {:ok, content} ->
              child = Gitignore.parse(content, gitignore.root)
              Gitignore.merge(gitignore, child)

            {:error, _} ->
              gitignore
          end
        else
          gitignore
        end

      case File.ls(dir) do
        {:ok, entries} ->
          entries
          |> Enum.sort()
          |> Enum.flat_map(fn entry ->
            full = Path.join(dir, entry)
            rel = relative_to_root(full, gitignore.root)
            is_dir = File.dir?(full)

            cond do
              skip_dir?(entry) ->
                []

              not no_ignore and Gitignore.ignored?(gitignore, rel, is_dir) ->
                []

              is_dir ->
                walk_dir(full, glob, depth + 1, visited, gitignore, no_ignore)

              Opal.Platform.matches_glob?(entry, glob) ->
                [full]

              true ->
                []
            end
          end)

        {:error, _} ->
          []
      end
    end
  end

  # Returns a path relative to the gitignore root, using forward slashes.
  defp relative_to_root(path, root) do
    Path.relative_to(path, root)
  end

  defp skip_dir?(name), do: MapSet.member?(@skip_dirs, name)

  # -- Search across files ----------------------------------------------------
  #
  # Files are searched in parallel when there are enough to justify the
  # overhead.  Each task is fully independent (read → regex → hashline),
  # so there is no shared mutable state.  Results stream back in file
  # order via `ordered: true`, then we apply the max_results cap.

  defp search_files(files, regex, ctx_lines, max_results, working_dir) do
    if length(files) < @parallel_threshold do
      search_files_sequential(files, regex, ctx_lines, max_results, working_dir)
    else
      search_files_parallel(files, regex, ctx_lines, max_results, working_dir)
    end
  end

  defp search_files_sequential(files, regex, ctx_lines, max_results, working_dir) do
    Enum.reduce_while(files, {[], 0, false}, fn file, {acc, count, _capped?} ->
      case search_file(file, regex, ctx_lines, max_results - count, working_dir) do
        {:ok, matches, match_count} when match_count > 0 ->
          new_count = count + match_count
          new_acc = acc ++ [{file, matches}]

          if new_count >= max_results do
            {:halt, {new_acc, new_count, true}}
          else
            {:cont, {new_acc, new_count, false}}
          end

        _ ->
          {:cont, {acc, count, false}}
      end
    end)
  end

  defp search_files_parallel(files, regex, ctx_lines, max_results, working_dir) do
    # Each task searches with the full max_results cap.  We trim after
    # collecting, so individual tasks may do slightly more work than
    # strictly necessary — but each one is bounded and the fan-out
    # across schedulers more than compensates.
    files
    |> Task.async_stream(
      fn file -> {file, search_file(file, regex, ctx_lines, max_results, working_dir)} end,
      ordered: true,
      max_concurrency: @max_concurrency
    )
    |> Enum.reduce_while({[], 0, false}, fn {:ok, {file, result}}, {acc, count, _capped?} ->
      case result do
        {:ok, matches, match_count} when match_count > 0 ->
          # Trim this file's matches if adding all would exceed the cap.
          trimmed_count = min(match_count, max_results - count)

          matches =
            if trimmed_count < match_count do
              trim_matches(matches, trimmed_count)
            else
              matches
            end

          new_count = count + trimmed_count
          new_acc = acc ++ [{file, matches}]

          if new_count >= max_results do
            {:halt, {new_acc, new_count, true}}
          else
            {:cont, {new_acc, new_count, false}}
          end

        _ ->
          {:cont, {acc, count, false}}
      end
    end)
  end

  # Rebuild the tagged output keeping only the first `n` match lines.
  # Context lines around kept matches are preserved.
  defp trim_matches({rel_path, groups}, keep) do
    {trimmed_groups, _remaining} =
      Enum.reduce_while(groups, {[], keep}, fn group, {acc, remaining} ->
        match_lines_in_group = Enum.count(group, fn {_tagged, is_match} -> is_match end)

        if match_lines_in_group <= remaining do
          {:cont, {acc ++ [group], remaining - match_lines_in_group}}
        else
          # Partial group: keep only enough match lines.
          {partial, _} =
            Enum.reduce(group, {[], remaining}, fn {tagged, is_match} = entry, {kept, rem} ->
              cond do
                not is_match -> {kept ++ [entry], rem}
                rem > 0 -> {kept ++ [{tagged, true}], rem - 1}
                true -> {kept, 0}
              end
            end)

          {:halt, {acc ++ [partial], 0}}
        end
      end)

    {rel_path, trimmed_groups}
  end

  defp search_file(file, regex, ctx_lines, remaining, working_dir) do
    with {:ok, raw} <- File.read(file),
         true <- String.valid?(raw),
         false <- Opal.Platform.binary_content?(raw) do
      {_enc, content} = FileIO.normalize_encoding(raw)

      lines = String.split(content, "\n")
      match_indices = find_matching_lines(lines, regex)

      if match_indices == [] do
        {:ok, [], 0}
      else
        capped_indices = Enum.take(match_indices, remaining)
        context_ranges = build_context_ranges(capped_indices, ctx_lines, length(lines))
        # Normalize to forward slashes so output is consistent across platforms.
        rel_path = Opal.Path.posix_relative(file, working_dir)

        tagged =
          Enum.map(context_ranges, fn {range, match_set} ->
            Enum.map(range, fn idx ->
              line = Enum.at(lines, idx)
              num = idx + 1
              is_match = MapSet.member?(match_set, idx)
              {Hashline.tag_line(line, num), is_match}
            end)
          end)

        {:ok, {rel_path, tagged}, length(capped_indices)}
      end
    else
      # Not a text file, unreadable, or invalid
      _ -> {:skip, 0}
    end
  end

  defp find_matching_lines(lines, regex) do
    lines
    |> Enum.with_index()
    |> Enum.filter(fn {line, _idx} -> Regex.match?(regex, line) end)
    |> Enum.map(fn {_line, idx} -> idx end)
  end

  # Merges overlapping context windows so adjacent matches share context.
  defp build_context_ranges(match_indices, ctx_lines, total) do
    match_set = MapSet.new(match_indices)

    match_indices
    |> Enum.map(fn idx ->
      lo = max(idx - ctx_lines, 0)
      hi = min(idx + ctx_lines, total - 1)
      {lo, hi}
    end)
    |> merge_ranges()
    |> Enum.map(fn {lo, hi} -> {lo..hi, match_set} end)
  end

  defp merge_ranges([]), do: []

  defp merge_ranges([first | rest]) do
    Enum.reduce(rest, [first], fn {lo, hi}, [{prev_lo, prev_hi} | acc] ->
      if lo <= prev_hi + 1 do
        [{prev_lo, max(prev_hi, hi)} | acc]
      else
        [{lo, hi}, {prev_lo, prev_hi} | acc]
      end
    end)
    |> Enum.reverse()
  end

  # -- Formatting -------------------------------------------------------------

  defp format_results(results, total_matches, capped?) do
    file_sections =
      Enum.map_join(results, "\n\n", fn {_file, {rel_path, groups}} ->
        lines =
          Enum.map_join(groups, "\n---\n", fn group ->
            Enum.map_join(group, "\n", fn {tagged_line, _is_match} ->
              tagged_line
            end)
          end)

        "## #{rel_path}\n#{lines}"
      end)

    cap_note =
      if capped?,
        do: "\n\n[Showing #{total_matches} matches. Results capped — refine pattern or path.]",
        else: "\n\n#{total_matches} match#{if total_matches == 1, do: "", else: "es"} found."

    file_sections <> cap_note
  end

  defp maybe_truncate(output) when byte_size(output) > @max_output_bytes do
    truncated = FileIO.truncate_at_line(output, @max_output_bytes)

    truncated <>
      "\n\n[Output truncated at #{div(@max_output_bytes, 1024)}KB. Narrow pattern or path.]"
  end

  defp maybe_truncate(output), do: output
end
