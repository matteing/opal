defmodule Opal.FileIO do
  @moduledoc """
  File I/O primitives for Opal tools.

  Consolidates encoding normalization, path resolution, content-addressed
  line tagging (hashlines), and output truncation into a single module
  used by every file-based tool.
  """

  # ── Types ─────────────────────────────────────────────────────────────

  @typedoc "Captured encoding metadata for round-trip restoration."
  @type encoding_info :: %{bom: boolean(), crlf: boolean()}

  @bom <<0xEF, 0xBB, 0xBF>>

  # ── Encoding ──────────────────────────────────────────────────────────
  #
  # Handles two invisible encoding artifacts that break LLM edits:
  #
  #   1. **UTF-8 BOM** — 3-byte prefix some editors add. The LLM never
  #      sees or reproduces it, causing edit mismatches.
  #
  #   2. **CRLF line endings** — Windows-style `\r\n` that the LLM
  #      always omits, breaking exact-match edits.
  #
  # Both are stripped before matching and restored after editing.

  @doc """
  Strips BOM and normalizes CRLF in one pass.

  Returns `{encoding_info, clean_content}` — pass the info to
  `restore_encoding/2` after editing to preserve the original encoding.
  """
  @spec normalize_encoding(binary()) :: {encoding_info(), String.t()}
  def normalize_encoding(raw) do
    {had_bom, content} = strip_bom(raw)
    {had_crlf, content} = normalize_crlf(content)
    {%{bom: had_bom, crlf: had_crlf}, content}
  end

  @doc "Restores original BOM and line endings from encoding info."
  @spec restore_encoding(String.t(), encoding_info()) :: binary()
  def restore_encoding(content, %{bom: bom, crlf: crlf}) do
    content |> restore_crlf(crlf) |> restore_bom(bom)
  end

  @spec strip_bom(binary()) :: {boolean(), binary()}
  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: {true, rest}
  defp strip_bom(content), do: {false, content}

  @spec restore_bom(binary(), boolean()) :: binary()
  defp restore_bom(content, true), do: @bom <> content
  defp restore_bom(content, false), do: content

  @spec normalize_crlf(binary()) :: {boolean(), binary()}
  defp normalize_crlf(content) do
    if String.contains?(content, "\r\n"),
      do: {true, String.replace(content, "\r\n", "\n")},
      else: {false, content}
  end

  @spec restore_crlf(binary(), boolean()) :: binary()
  defp restore_crlf(content, true), do: String.replace(content, ~r/(?<!\r)\n/, "\r\n")
  defp restore_crlf(content, false), do: content

  # ── Path Resolution ───────────────────────────────────────────────────

  @doc "Resolves a relative path safely against the working directory and optional allowed bases."
  @spec resolve_path(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def resolve_path(path, working_dir, opts \\ []) do
    bases = Keyword.get(opts, :allow_bases, [])

    with {:error, :outside_base_dir} <- Opal.Path.safe_relative(path, working_dir),
         {:error, :outside_base_dir} <- try_bases(path, bases) do
      {:error, "Path escapes working directory: #{path}"}
    end
  end

  @doc "Returns additional trusted base directories from tool context."
  @spec allowed_bases(map()) :: [String.t()]
  def allowed_bases(%{config: %Opal.Config{} = config}), do: [Opal.Config.data_dir(config)]
  def allowed_bases(_), do: []

  @spec try_bases(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, :outside_base_dir}
  defp try_bases(_path, []), do: {:error, :outside_base_dir}

  defp try_bases(path, [base | rest]) do
    case Opal.Path.safe_relative(path, base) do
      {:ok, _} = ok -> ok
      {:error, :outside_base_dir} -> try_bases(path, rest)
    end
  end

  # ── File Reading ──────────────────────────────────────────────────────

  @doc "Reads a file with friendly error messages."
  @spec read_file(String.t()) :: {:ok, binary()} | {:error, String.t()}
  def read_file(path) do
    case File.read(path) do
      {:ok, _} = ok -> ok
      {:error, :enoent} -> {:error, "File not found: #{path}"}
      {:error, :eisdir} -> {:error, "Path is a directory: #{path}"}
      {:error, reason} -> {:error, "Failed to read file: #{reason}"}
    end
  end

  # ── Truncation ────────────────────────────────────────────────────────

  @doc ~S"""
  Truncates a string to `max` characters, appending `"… (truncated)"`.

  Delegates to `Opal.Util.Text.truncate/3`.

      iex> Opal.FileIO.truncate("hello", 100)
      "hello"
  """
  @spec truncate(String.t(), pos_integer()) :: String.t()
  defdelegate truncate(str, max), to: Opal.Util.Text

  @doc """
  Truncates binary content at the last newline before `max_bytes`.

  Avoids splitting mid-line, which would corrupt hashline tags or
  produce confusing partial output.
  """
  @spec truncate_at_line(binary(), non_neg_integer()) :: binary()
  def truncate_at_line(content, max_bytes) do
    truncated = binary_part(content, 0, min(max_bytes, byte_size(content)))

    case :binary.matches(truncated, "\n") do
      [] -> truncated
      matches -> binary_part(truncated, 0, elem(List.last(matches), 0))
    end
  end
end
