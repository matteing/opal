defmodule Opal.Tool.ReadFile do
  @moduledoc """
  Reads file contents, optionally returning a slice of lines.

  Strips BOM and normalizes CRLF so the LLM sees clean text.
  Large outputs are head-truncated with continuation hints.
  """

  @behaviour Opal.Tool

  alias Opal.{FileIO, Hashline}
  alias Opal.Tool.Args, as: ToolArgs

  @max_lines 2_000
  @max_bytes 50 * 1024

  @args_schema [
    path: [type: :string, required: true],
    offset: [type: :integer],
    limit: [type: :integer]
  ]

  @impl true
  @spec name() :: String.t()
  def name, do: "read_file"

  @impl true
  @spec description() :: String.t()
  def description, do: "Read the contents of a file at the given path."

  @impl true
  def meta(%{"path" => path}), do: "Read #{path}"
  def meta(_), do: "Read file"

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path to the file to read"},
        "offset" => %{
          "type" => "integer",
          "description" => "Line number to start reading from (1-indexed)"
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Maximum number of lines to read"
        }
      },
      "required" => ["path"]
    }
  end

  @impl true
  @spec execute(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(args, %{working_dir: working_dir} = context) when is_map(args) do
    with {:ok, opts} <-
           ToolArgs.validate(args, @args_schema,
             required_message: "Missing required parameter: path"
           ),
         {:ok, resolved} <-
           FileIO.resolve_path(opts[:path], working_dir,
             allow_bases: FileIO.allowed_bases(context)
           ),
         {:ok, raw} <- FileIO.read_file(resolved) do
      {_enc, content} = FileIO.normalize_encoding(raw)
      offset = Keyword.get(opts, :offset)
      limit = Keyword.get(opts, :limit)

      content |> maybe_slice(offset, limit) |> truncate_output(offset)
    end
  end

  def execute(%{"path" => _}, _context), do: {:error, "Missing working_dir in context"}
  def execute(_args, _context), do: {:error, "Missing required parameter: path"}

  defp maybe_slice(content, nil, nil), do: Hashline.tag_lines(content)

  defp maybe_slice(content, offset, limit) do
    lines = String.split(content, "\n")
    start = max((offset || 1) - 1, 0)
    selected = if limit, do: Enum.slice(lines, start, limit), else: Enum.drop(lines, start)

    selected
    |> Enum.with_index(start + 1)
    |> Enum.map_join("\n", fn {line, num} -> Hashline.tag_line(line, num) end)
  end

  # Head-truncation: keeps the beginning (imports/structure live at the top).
  defp truncate_output(content, offset) do
    lines = String.split(content, "\n")
    total_lines = length(lines)
    start = offset || 1

    cond do
      byte_size(content) > @max_bytes and total_lines <= 1 ->
        kb = Float.round(byte_size(content) / 1024, 1)

        {:ok,
         "[Line 1 is #{kb}KB, exceeds #{div(@max_bytes, 1024)}KB limit. " <>
           "Use read_file with offset=1 and limit=#{@max_lines}, or split with a shell command.]"}

      total_lines > @max_lines ->
        text = lines |> Enum.take(@max_lines) |> Enum.join("\n")
        end_line = start + @max_lines - 1

        {:ok,
         text <>
           "\n\n[Showing lines #{start}-#{end_line} of #{total_lines}. " <>
           "Use offset=#{end_line + 1} to continue.]"}

      byte_size(content) > @max_bytes ->
        truncated = FileIO.truncate_at_line(content, @max_bytes)
        shown_count = length(String.split(truncated, "\n"))
        end_line = start + shown_count - 1

        {:ok,
         truncated <>
           "\n\n[Output truncated at #{div(@max_bytes, 1024)}KB. " <>
           "Showing lines #{start}-#{end_line} of #{total_lines}. " <>
           "Use offset=#{end_line + 1} to continue.]"}

      true ->
        {:ok, content}
    end
  end
end
