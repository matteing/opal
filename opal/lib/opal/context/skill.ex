defmodule Opal.Skill do
  @moduledoc """
  Parses and validates Agent Skills per the [agentskills.io spec](https://agentskills.io/specification).

  A skill is a directory with a `SKILL.md` — YAML frontmatter for metadata,
  Markdown body for instructions. Metadata loads at discovery; full
  instructions load on activation (progressive disclosure).

  ## Frontmatter Fields

  | Field           | Required | Constraint                         |
  |-----------------|----------|------------------------------------|
  | `name`          | yes      | 1–64 chars, `[a-z0-9-]`, no `--`  |
  | `description`   | yes      | 1–1024 chars                       |
  | `license`       | no       | free-form string                   |
  | `compatibility` | no       | ≤ 500 chars                        |
  | `metadata`      | no       | arbitrary map                      |
  | `allowed-tools` | no       | space-delimited list               |
  """

  @type t :: %__MODULE__{
          name: String.t() | nil,
          description: String.t() | nil,
          license: String.t() | nil,
          compatibility: String.t() | nil,
          metadata: map() | nil,
          allowed_tools: [String.t()] | nil,
          instructions: String.t(),
          path: Path.t() | nil
        }

  defstruct [
    :name,
    :description,
    :license,
    :compatibility,
    :metadata,
    :allowed_tools,
    :instructions,
    :path
  ]

  @name_re ~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/
  @frontmatter_re ~r/\A\s*---\n(.*?)\n---[ \t]*(?:\n(.*))?\z/s

  # ── Public API ──────────────────────────────────────────────────────

  @doc "Parses a `SKILL.md` from disk, setting `:path` on success."
  @spec parse_file(Path.t()) :: {:ok, t()} | {:error, term()}
  def parse_file(path) do
    with {:ok, content} <- read(path),
         {:ok, skill} <- parse(content) do
      {:ok, %{skill | path: path}}
    end
  end

  @doc "Parses raw SKILL.md content (YAML frontmatter + Markdown body)."
  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(content) when is_binary(content) do
    with {:ok, yaml, body} <- split_frontmatter(content),
         {:ok, fm} <- decode_yaml(yaml) do
      {:ok, from_frontmatter(fm, body)}
    end
  end

  @doc """
  Validates field constraints per the agentskills.io spec.

  ## Options

    * `:dir_name` — asserts `skill.name` matches the parent directory.
  """
  @spec validate(t(), keyword()) :: :ok | {:error, [String.t()]}
  def validate(%__MODULE__{} = skill, opts \\ []) do
    case Enum.flat_map(checks(opts), & &1.(skill)) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  @doc "Formats a one-line summary for progressive disclosure."
  @spec summary(t()) :: String.t()
  def summary(%__MODULE__{name: name, description: desc}),
    do: "- **#{name}**: #{desc}"

  # ── Parsing ─────────────────────────────────────────────────────────

  @spec read(Path.t()) :: {:ok, binary()} | {:error, term()}
  defp read(path) do
    case File.read(path) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, {:file_error, reason, path}}
    end
  end

  @spec split_frontmatter(String.t()) :: {:ok, String.t(), String.t()} | {:error, :no_frontmatter}
  defp split_frontmatter(content) do
    case Regex.run(@frontmatter_re, content, capture: :all_but_first) do
      [yaml, body] -> {:ok, String.trim(yaml), String.trim(body)}
      [yaml] -> {:ok, String.trim(yaml), ""}
      _ -> {:error, :no_frontmatter}
    end
  end

  @spec decode_yaml(String.t()) :: {:ok, map()} | {:error, term()}
  defp decode_yaml(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, %{} = fm} -> {:ok, fm}
      {:ok, _} -> {:error, :invalid_frontmatter}
      {:error, reason} -> {:error, {:yaml_parse_error, reason}}
    end
  end

  @spec from_frontmatter(map(), String.t()) :: t()
  defp from_frontmatter(fm, body) do
    %__MODULE__{
      name: fm["name"],
      description: fm["description"],
      license: fm["license"],
      compatibility: fm["compatibility"],
      metadata: fm["metadata"],
      allowed_tools: parse_tools(fm["allowed-tools"]),
      instructions: body
    }
  end

  @spec parse_tools(term()) :: [String.t()] | nil
  defp parse_tools(tools) when is_binary(tools), do: String.split(tools)
  defp parse_tools(_), do: nil

  # ── Validation ──────────────────────────────────────────────────────

  @spec checks(keyword()) :: [(t() -> [String.t()])]
  defp checks(opts) do
    base = [&check_name/1, &check_description/1, &check_compatibility/1]
    if dir = opts[:dir_name], do: base ++ [&check_dir_name(&1, dir)], else: base
  end

  @spec check_name(t()) :: [String.t()]
  defp check_name(%{name: nil}), do: ["name is required"]
  defp check_name(%{name: n}) when not is_binary(n), do: ["name must be a string"]

  defp check_name(%{name: n}) do
    cond do
      String.length(n) > 64 ->
        ["name must be at most 64 characters"]

      String.contains?(n, "--") ->
        ["name must not contain consecutive hyphens"]

      not Regex.match?(@name_re, n) ->
        [
          "name must contain only lowercase alphanumeric characters and hyphens, " <>
            "and must not start or end with a hyphen"
        ]

      true ->
        []
    end
  end

  @spec check_description(t()) :: [String.t()]
  defp check_description(%{description: nil}), do: ["description is required"]

  defp check_description(%{description: d}) when not is_binary(d),
    do: ["description must be a string"]

  defp check_description(%{description: d}) do
    cond do
      byte_size(d) == 0 -> ["description must not be empty"]
      String.length(d) > 1024 -> ["description must be at most 1024 characters"]
      true -> []
    end
  end

  @spec check_compatibility(t()) :: [String.t()]
  defp check_compatibility(%{compatibility: nil}), do: []

  defp check_compatibility(%{compatibility: c}) when not is_binary(c),
    do: ["compatibility must be a string"]

  defp check_compatibility(%{compatibility: c}) do
    if String.length(c) > 500, do: ["compatibility must be at most 500 characters"], else: []
  end

  @spec check_dir_name(t(), String.t()) :: [String.t()]
  defp check_dir_name(%{name: name}, dir) when name != dir,
    do: ["name '#{name}' must match directory name '#{dir}'"]

  defp check_dir_name(_, _), do: []
end
