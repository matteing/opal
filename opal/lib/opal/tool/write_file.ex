defmodule Opal.Tool.WriteFile do
  @moduledoc """
  Writes content to a file, creating parent directories as needed.

  When overwriting an existing file, detects its BOM and line-ending style
  and applies them to the new content, preventing silent encoding corruption.
  """

  @behaviour Opal.Tool

  alias Opal.FileIO

  @impl true
  @spec name() :: String.t()
  def name, do: "write_file"

  @impl true
  @spec description() :: String.t()
  def description,
    do: "Write content to a file at the given path. Creates parent directories if needed."

  @impl true
  def meta(%{"path" => path}), do: "Write #{path}"
  def meta(_), do: "Write file"

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path to the file to write"},
        "content" => %{"type" => "string", "description" => "Content to write to the file"}
      },
      "required" => ["path", "content"]
    }
  end

  @impl true
  @spec execute(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"path" => path, "content" => content}, %{working_dir: working_dir} = context) do
    allow_bases = FileIO.allowed_bases(context)

    with {:ok, resolved} <- FileIO.resolve_path(path, working_dir, allow_bases: allow_bases) do
      resolved |> Path.dirname() |> File.mkdir_p!()
      content = match_existing_encoding(resolved, content)

      case File.write(resolved, content) do
        :ok -> {:ok, "File written: #{resolved}"}
        {:error, reason} -> {:error, "Failed to write file: #{reason}"}
      end
    end
  end

  def execute(%{"path" => _, "content" => _}, _context),
    do: {:error, "Missing working_dir in context"}

  def execute(_args, _context),
    do: {:error, "Missing required parameters: path and content"}

  # Detects encoding of an existing file and applies it to new content.
  defp match_existing_encoding(path, content) do
    case File.read(path) do
      {:ok, existing} ->
        {enc, _} = FileIO.normalize_encoding(existing)
        FileIO.restore_encoding(content, enc)

      {:error, _} ->
        content
    end
  end
end
