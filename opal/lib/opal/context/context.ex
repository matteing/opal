defmodule Opal.Context do
  @moduledoc """
  Discovers project context files and agent skills from the filesystem.

  ## Context Files

  Starting from `working_dir`, walks up the directory tree to the root,
  collecting known instruction files at each level. Files closer to
  `working_dir` appear last (highest priority).

  Checked at every ancestor:

    * `AGENTS.md`, `OPAL.md`
    * `.agents/AGENTS.md`, `.opal/OPAL.md`

  ## Skills

  Scans well-known directories for skill subdirectories, each containing
  a `SKILL.md` per the [agentskills.io spec](https://agentskills.io/specification).

  Search locations (project-local then user-global):

    * `<working_dir>/.{agents,github,claude}/skills/*/SKILL.md`
    * `~/.{agents,opal,claude}/skills/*/SKILL.md`

  Only `name` and `description` are loaded upfront — full instructions
  load on activation (progressive disclosure).
  """

  @typedoc "A discovered context file with its absolute path and content."
  @type entry :: %{path: String.t(), content: String.t()}

  @context_filenames ~w(AGENTS.md OPAL.md)
  @hidden_dirs ~w(.agents .opal)
  @project_skill_dirs ~w(.agents .github .claude)
  @home_skill_dirs ~w(.agents .opal .claude)

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Discovers context files by walking up from `working_dir`.

  Returns entries ordered root-first (closest to `working_dir` last).

  ## Options

    * `:filenames` — filenames to look for (default: `#{inspect(@context_filenames)}`).
  """
  @spec discover_context(String.t(), keyword()) :: [entry()]
  def discover_context(working_dir, opts \\ []) do
    filenames = Keyword.get(opts, :filenames, @context_filenames)

    working_dir
    |> Opal.Path.ancestors()
    |> Enum.flat_map(&candidate_paths(&1, filenames))
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(fn path -> %{path: path, content: File.read!(path)} end)
  end

  @doc """
  Discovers skills from standard and configured directories.

  Returns valid `Opal.Skill.t()` structs; invalid `SKILL.md` files are
  silently skipped. Deduplicates by name (first occurrence wins).

  ## Options

    * `:extra_dirs` — additional directories containing skill subdirectories.
  """
  @spec discover_skills(String.t(), keyword()) :: [Opal.Skill.t()]
  def discover_skills(working_dir, opts \\ []) do
    project = Path.expand(working_dir)
    home = System.user_home!()
    extras = opts |> Keyword.get(:extra_dirs, []) |> Enum.map(&Path.expand/1)

    (skills_under(project, @project_skill_dirs) ++
       skills_under(home, @home_skill_dirs) ++
       extras)
    |> Enum.uniq()
    |> Enum.flat_map(&scan_skills_dir/1)
    |> Enum.uniq_by(& &1.name)
  end

  # ── Private ─────────────────────────────────────────────────────────

  @spec candidate_paths(String.t(), [String.t()]) :: [String.t()]
  defp candidate_paths(dir, filenames) do
    Enum.flat_map(filenames, fn file ->
      [Path.join(dir, file) | Enum.map(@hidden_dirs, &Path.join([dir, &1, file]))]
    end)
  end

  @spec skills_under(String.t(), [String.t()]) :: [String.t()]
  defp skills_under(base, prefixes) do
    Enum.map(prefixes, &Path.join([base, &1, "skills"]))
  end

  @spec scan_skills_dir(String.t()) :: [Opal.Skill.t()]
  defp scan_skills_dir(dir) do
    with true <- File.dir?(dir),
         {:ok, entries} <- File.ls(dir) do
      entries
      |> Enum.map(&Path.join(dir, &1))
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(&parse_skill/1)
    else
      _ -> []
    end
  end

  @spec parse_skill(String.t()) :: [Opal.Skill.t()]
  defp parse_skill(skill_dir) do
    skill_md = Path.join(skill_dir, "SKILL.md")

    with true <- File.regular?(skill_md),
         {:ok, skill} <- Opal.Skill.parse_file(skill_md),
         :ok <- Opal.Skill.validate(skill, dir_name: Path.basename(skill_dir)) do
      [skill]
    else
      _ -> []
    end
  end
end
