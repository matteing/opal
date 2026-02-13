defmodule Opal.Skill do
  @moduledoc """
  Parses and validates Agent Skills following the [agentskills.io specification](https://agentskills.io/specification).

  A skill is a directory containing a `SKILL.md` file with YAML frontmatter
  (metadata) and a Markdown body (instructions). Skills support progressive
  disclosure: metadata is loaded at discovery time, and full instructions are
  loaded on demand when the agent activates the skill.

  ## SKILL.md Format

      ---
      name: my-skill
      description: What this skill does and when to use it.
      ---

      # Instructions

      Step-by-step instructions for the agent...

  ## Required Fields

    * `name` — 1–64 characters, lowercase alphanumeric and hyphens only.
      Must not start/end with `-` or contain `--`. Must match the parent
      directory name.

    * `description` — 1–1024 characters describing what the skill does
      and when to use it.

  ## Optional Fields

    * `globs` — File-path glob patterns (e.g. `docs/**`). When a tool
      writes to a path matching any pattern, the skill is auto-loaded.
    * `license` — License name or reference to a bundled file.
    * `compatibility` — 1–500 characters indicating environment requirements.
    * `metadata` — Arbitrary key-value map for additional properties.
    * `allowed-tools` — Space-delimited list of pre-approved tools (experimental).

  ## Usage

      # Parse a single SKILL.md file
      {:ok, skill} = Opal.Skill.parse_file("/path/to/my-skill/SKILL.md")

      # Parse raw markdown content
      {:ok, skill} = Opal.Skill.parse("---\\nname: my-skill\\n...")

      # Validate a parsed skill against its directory
      :ok = Opal.Skill.validate(skill, dir_name: "my-skill")
  """

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          globs: [String.t()] | nil,
          license: String.t() | nil,
          compatibility: String.t() | nil,
          metadata: map() | nil,
          allowed_tools: [String.t()] | nil,
          instructions: String.t(),
          path: String.t() | nil
        }

  defstruct [
    :name,
    :description,
    :globs,
    :license,
    :compatibility,
    :metadata,
    :allowed_tools,
    :instructions,
    :path
  ]

  @name_pattern ~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/

  @doc """
  Parses a `SKILL.md` file from disk.

  Returns `{:ok, skill}` with the full struct including `:path`, or
  `{:error, reason}` if the file cannot be read or parsed.
  """
  @spec parse_file(String.t()) :: {:ok, t()} | {:error, term()}
  def parse_file(path) do
    case File.read(path) do
      {:ok, content} ->
        case parse(content) do
          {:ok, skill} -> {:ok, %{skill | path: path}}
          error -> error
        end

      {:error, reason} ->
        {:error, {:file_error, reason, path}}
    end
  end

  @doc """
  Parses raw SKILL.md content (YAML frontmatter + Markdown body).

  The content must begin with `---` followed by YAML frontmatter and
  a closing `---`. Everything after the closing delimiter is treated
  as the Markdown instructions body.

  Returns `{:ok, skill}` or `{:error, reason}`.

  ## Examples

      iex> Opal.Skill.parse("---\\nname: test\\ndescription: A test skill.\\n---\\n# Hello")
      {:ok, %Opal.Skill{name: "test", description: "A test skill.", instructions: "# Hello"}}
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(content) when is_binary(content) do
    case split_frontmatter(content) do
      {:ok, yaml_str, body} ->
        case YamlElixir.read_from_string(yaml_str) do
          {:ok, frontmatter} when is_map(frontmatter) ->
            build_skill(frontmatter, body)

          {:ok, _} ->
            {:error, :invalid_frontmatter}

          {:error, reason} ->
            {:error, {:yaml_parse_error, reason}}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Validates a parsed skill struct.

  Checks all field constraints from the agentskills.io spec. Returns
  `:ok` or `{:error, reasons}` where `reasons` is a list of validation
  error strings.

  ## Options

    * `:dir_name` — if provided, validates that `skill.name` matches
      the parent directory name.
  """
  @spec validate(t(), keyword()) :: :ok | {:error, [String.t()]}
  def validate(%__MODULE__{} = skill, opts \\ []) do
    errors =
      []
      |> validate_name(skill.name)
      |> validate_description(skill.description)
      |> validate_compatibility(skill.compatibility)
      |> validate_dir_name(skill.name, Keyword.get(opts, :dir_name))

    case errors do
      [] -> :ok
      errs -> {:error, Enum.reverse(errs)}
    end
  end

  @doc """
  Returns a short summary string for progressive disclosure.

  Only includes `name` and `description` — suitable for injecting into
  the agent's context at startup without loading full instructions.
  """
  @spec summary(t()) :: String.t()
  def summary(%__MODULE__{name: name, description: desc}) do
    "- **#{name}**: #{desc}"
  end

  @doc """
  Returns `true` if the given relative path matches any of the skill's
  glob patterns.

  Returns `false` when the skill has no globs defined (`nil`).

  ## Examples

      iex> skill = %Opal.Skill{name: "docs", globs: ["docs/**"], description: "", instructions: ""}
      iex> Opal.Skill.matches_path?(skill, "docs/tools/edit.md")
      true

      iex> skill = %Opal.Skill{name: "docs", globs: nil, description: "", instructions: ""}
      iex> Opal.Skill.matches_path?(skill, "docs/tools/edit.md")
      false
  """
  @spec matches_path?(t(), String.t()) :: boolean()
  def matches_path?(%__MODULE__{globs: nil}, _path), do: false
  def matches_path?(%__MODULE__{globs: []}, _path), do: false

  def matches_path?(%__MODULE__{globs: globs}, path) when is_list(globs) do
    Enum.any?(globs, &glob_match?(&1, path))
  end

  # Converts a glob pattern to a regex and tests the path.
  defp glob_match?(pattern, path) do
    regex_str =
      pattern
      # Temporarily replace ** so single-* replacement doesn't eat it
      |> String.replace("**", "\0GLOBSTAR\0")
      |> Regex.escape()
      |> String.replace("\\*", "[^/]*")
      |> String.replace("\\?", "[^/]")
      |> String.replace("\0GLOBSTAR\0", ".*")

    case Regex.compile("^#{regex_str}$") do
      {:ok, regex} -> Regex.match?(regex, path)
      _ -> false
    end
  end

  # --- Private ---

  # Splits "---\nyaml\n---\nbody" into {yaml, body}.
  defp split_frontmatter(content) do
    content = String.trim_leading(content)

    case String.split(content, ~r/\n---\s*\n/, parts: 2) do
      [front, body] ->
        case String.starts_with?(front, "---") do
          true ->
            yaml = String.trim_leading(front, "---") |> String.trim()
            {:ok, yaml, String.trim(body)}

          false ->
            {:error, :no_frontmatter}
        end

      _ ->
        # Try trailing --- at end of file (no body)
        if String.starts_with?(content, "---") do
          trimmed = String.trim_leading(content, "---") |> String.trim()

          if String.ends_with?(trimmed, "---") do
            yaml = String.trim_trailing(trimmed, "---") |> String.trim()
            {:ok, yaml, ""}
          else
            {:error, :no_frontmatter}
          end
        else
          {:error, :no_frontmatter}
        end
    end
  end

  defp build_skill(frontmatter, body) do
    allowed_tools =
      case Map.get(frontmatter, "allowed-tools") do
        nil -> nil
        str when is_binary(str) -> String.split(str, ~r/\s+/, trim: true)
        _ -> nil
      end

    globs =
      case Map.get(frontmatter, "globs") do
        nil -> nil
        str when is_binary(str) -> [str]
        list when is_list(list) -> Enum.filter(list, &is_binary/1)
        _ -> nil
      end

    skill = %__MODULE__{
      name: Map.get(frontmatter, "name"),
      description: Map.get(frontmatter, "description"),
      globs: globs,
      license: Map.get(frontmatter, "license"),
      compatibility: Map.get(frontmatter, "compatibility"),
      metadata: Map.get(frontmatter, "metadata"),
      allowed_tools: allowed_tools,
      instructions: body
    }

    {:ok, skill}
  end

  # --- Validation helpers ---

  defp validate_name(errors, nil), do: ["name is required" | errors]
  defp validate_name(errors, name) when not is_binary(name), do: ["name must be a string" | errors]

  defp validate_name(errors, name) do
    cond do
      String.length(name) < 1 ->
        ["name must be at least 1 character" | errors]

      String.length(name) > 64 ->
        ["name must be at most 64 characters" | errors]

      String.contains?(name, "--") ->
        ["name must not contain consecutive hyphens" | errors]

      not Regex.match?(@name_pattern, name) ->
        ["name must contain only lowercase alphanumeric characters and hyphens, and must not start or end with a hyphen" | errors]

      true ->
        errors
    end
  end

  defp validate_description(errors, nil), do: ["description is required" | errors]

  defp validate_description(errors, desc) when not is_binary(desc),
    do: ["description must be a string" | errors]

  defp validate_description(errors, desc) do
    cond do
      String.length(desc) < 1 -> ["description must not be empty" | errors]
      String.length(desc) > 1024 -> ["description must be at most 1024 characters" | errors]
      true -> errors
    end
  end

  defp validate_compatibility(errors, nil), do: errors

  defp validate_compatibility(errors, compat) when not is_binary(compat),
    do: ["compatibility must be a string" | errors]

  defp validate_compatibility(errors, compat) do
    if String.length(compat) > 500 do
      ["compatibility must be at most 500 characters" | errors]
    else
      errors
    end
  end

  defp validate_dir_name(errors, _name, nil), do: errors

  defp validate_dir_name(errors, name, dir_name) do
    if name != dir_name do
      ["name '#{name}' must match directory name '#{dir_name}'" | errors]
    else
      errors
    end
  end
end
