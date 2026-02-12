defmodule Opal.Tool.Edit do
  @moduledoc """
  Applies a search-and-replace edit to a file.

  The old string must match exactly one location in the file. Implements
  the `Opal.Tool` behaviour and resolves paths relative to the session's
  working directory using `Opal.Path.safe_relative/2`.

  ## Encoding Awareness

  Before matching, the tool strips UTF-8 BOM and normalizes CRLF to LF.
  After a successful edit, the original encoding is restored — the file
  retains its BOM and line-ending style.

  ## Fuzzy Matching

  When exact match fails (0 occurrences), the tool falls back to fuzzy
  matching via `Opal.Tool.Edit.Fuzzy`. This handles smart quotes,
  em-dashes, Unicode spaces, and trailing whitespace that the LLM
  silently "corrects" when reproducing text.
  """

  @behaviour Opal.Tool

  alias Opal.Tool.Encoding
  alias Opal.Tool.Edit.Fuzzy

  @impl true
  @spec name() :: String.t()
  def name, do: "edit_file"

  @impl true
  @spec description() :: String.t()
  def description,
    do:
      "Apply a search-and-replace edit to a file. The old_string must match exactly one location in the file."

  @impl true
  def meta(%{"path" => path}), do: "Edit #{path}"
  def meta(_), do: "Edit file"

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path to the file to edit"},
        "old_string" => %{"type" => "string", "description" => "Exact string to find in the file"},
        "new_string" => %{
          "type" => "string",
          "description" => "String to replace old_string with"
        }
      },
      "required" => ["path", "old_string", "new_string"]
    }
  end

  @impl true
  @spec execute(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(
        %{"path" => path, "old_string" => old_string, "new_string" => new_string},
        %{working_dir: working_dir}
      ) do
    with {:ok, resolved} <- resolve_path(path, working_dir),
         {:ok, raw_content} <- read_file(resolved) do
      # Strip encoding artifacts before matching — the LLM never
      # includes BOM or \r in its old_string.
      {had_bom, content} = Encoding.strip_bom(raw_content)
      {had_crlf, content} = Encoding.normalize_line_endings(content)

      # Normalize the search/replace strings too (LLM won't include \r)
      old_string = String.replace(old_string, "\r\n", "\n")
      new_string = String.replace(new_string, "\r\n", "\n")

      with {:ok, new_content} <- apply_edit(content, old_string, new_string) do
        # Restore original encoding so the file keeps its BOM and line endings
        restored =
          new_content
          |> Encoding.restore_line_endings(had_crlf)
          |> Encoding.restore_bom(had_bom)

        case File.write(resolved, restored) do
          :ok -> {:ok, "Edit applied to: #{resolved}"}
          {:error, reason} -> {:error, "Failed to write file: #{reason}"}
        end
      end
    end
  end

  def execute(%{"path" => _, "old_string" => _, "new_string" => _}, _context),
    do: {:error, "Missing working_dir in context"}

  def execute(_args, _context),
    do: {:error, "Missing required parameters: path, old_string, and new_string"}

  defp resolve_path(path, working_dir) do
    case Opal.Path.safe_relative(path, working_dir) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, :outside_base_dir} -> {:error, "Path escapes working directory: #{path}"}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, "File not found: #{path}"}
      {:error, reason} -> {:error, "Failed to read file: #{reason}"}
    end
  end

  defp apply_edit(_content, old_string, _new_string) when byte_size(old_string) == 0 do
    {:error, "old_string must not be empty"}
  end

  defp apply_edit(content, old_string, new_string) do
    case count_occurrences(content, old_string) do
      0 ->
        # Exact match failed — try fuzzy normalization (smart quotes,
        # em-dashes, trailing whitespace, Unicode spaces).
        fuzzy_fallback(content, old_string, new_string)

      1 ->
        {:ok, String.replace(content, old_string, new_string, global: false)}

      n ->
        {:error, "old_string found #{n} times — must match exactly once. Add surrounding context to disambiguate."}
    end
  end

  # Attempts fuzzy matching when exact match returns zero occurrences.
  # The fuzzy module normalizes both sides, finds the original substring
  # that corresponds to the match, and verifies it's unique.
  defp fuzzy_fallback(content, old_string, new_string) do
    case Fuzzy.fuzzy_find(content, old_string) do
      {:ok, original_match} ->
        # Verify the recovered original text is still unique
        case count_occurrences(content, original_match) do
          1 ->
            {:ok, String.replace(content, original_match, new_string, global: false)}

          _ ->
            {:error, "old_string not found in file (fuzzy match was ambiguous)"}
        end

      :no_match ->
        {:error, "old_string not found in file"}
    end
  end

  defp count_occurrences(content, pattern) do
    content
    |> String.split(pattern)
    |> length()
    |> Kernel.-(1)
  end
end
