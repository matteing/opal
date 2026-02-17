defmodule Opal.Context do
  @moduledoc """
  Discovers project context files and agent skills from the filesystem.

  Context is gathered from two sources:

  ## Context Files (walk-up discovery)

  Starting from the agent's `working_dir`, walks up the directory tree to
  the filesystem root, collecting known context files at each level. These
  files provide project-specific instructions that are prepended to the
  agent's system prompt.

  Files checked at each directory level:
    * `AGENTS.md`
    * `OPAL.md`
    * `.agents/AGENTS.md`
    * `.opal/OPAL.md`

  The filename list is configurable via `Opal.Config.Features` `:context` subsystem.
  Files found closer to `working_dir` appear later in the list (higher priority).

  ## Skills (directory discovery)

  Scans well-known directories for skill subdirectories, each containing a
  `SKILL.md` file per the [agentskills.io spec](https://agentskills.io/specification).

  Standard search locations:
    * `<working_dir>/.agents/skills/*/SKILL.md`
    * `<working_dir>/.github/skills/*/SKILL.md`
    * `<working_dir>/.claude/skills/*/SKILL.md`
    * `~/.agents/skills/*/SKILL.md`
    * `~/.opal/skills/*/SKILL.md`
    * `~/.claude/skills/*/SKILL.md`

  Additional directories can be specified via `Opal.Config.Features` `:skills` subsystem.

  Skills use **progressive disclosure**: only `name` and `description` are
  loaded into the agent's context at startup. Full instructions are loaded
  when a skill is activated.
  """

  # ── Centralized directory & filename constants ──────────────────────────
  # Edit these to add/remove context files or skill search locations.

  # Filenames looked for at every directory level during walk-up discovery.
  @default_context_filenames ~w(AGENTS.md OPAL.md)

  # Hidden-directory prefixes checked for context files (e.g. `.agents/AGENTS.md`).
  @context_hidden_dirs ~w(.agents .opal)

  # Hidden-directory prefixes under `working_dir` that may contain a `skills/` folder.
  @project_skill_dirs ~w(.agents .github .claude)

  # Hidden-directory prefixes under `$HOME` that may contain a `skills/` folder.
  @home_skill_dirs ~w(.agents .opal .claude)

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Discovers context files by walking up from `working_dir`.

  Returns a list of `%{path: String.t(), content: String.t()}` maps,
  ordered from root-most to deepest (closest to `working_dir` comes last).

  ## Options

    * `:filenames` — list of filenames to look for (default from config).
      Also searches hidden-directory variants defined in `@context_hidden_dirs`.
  """
  @spec discover_context(String.t(), keyword()) :: [%{path: String.t(), content: String.t()}]
  def discover_context(working_dir, opts \\ []) do
    filenames = Keyword.get(opts, :filenames, @default_context_filenames)

    working_dir
    |> Path.expand()
    |> walk_up()
    |> Enum.flat_map(fn dir ->
      filenames
      |> Enum.flat_map(fn filename ->
        root = [Path.join(dir, filename)]
        hidden = Enum.map(@context_hidden_dirs, &Path.join([dir, &1, filename]))
        root ++ hidden
      end)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&%{path: &1, content: File.read!(&1)})
    end)
  end

  @doc """
  Discovers skills from standard and configured directories.

  Returns a list of `Opal.Skill.t()` structs with metadata parsed.
  Only valid skills (those that parse and pass validation) are included;
  invalid `SKILL.md` files are silently skipped.

  ## Options

    * `:extra_dirs` — additional directories containing skill subdirectories
      (default: `[]`).
  """
  @spec discover_skills(String.t(), keyword()) :: [Opal.Skill.t()]
  def discover_skills(working_dir, opts \\ []) do
    extra_dirs = Keyword.get(opts, :extra_dirs, [])
    expanded = Path.expand(working_dir)
    home = System.user_home!()

    project = Enum.map(@project_skill_dirs, &Path.join([expanded, &1, "skills"]))
    user = Enum.map(@home_skill_dirs, &Path.join([home, &1, "skills"]))
    extra = Enum.map(extra_dirs, &Path.expand/1)

    (project ++ user ++ extra)
    |> Enum.uniq()
    |> Enum.flat_map(&scan_skills_dir/1)
    |> Enum.uniq_by(& &1.name)
  end

  # ── Private ─────────────────────────────────────────────────────────────

  # Returns directories from the given path up to the filesystem root.
  # Result is ordered root-first (deepest directory last).
  defp walk_up(path), do: do_walk_up(path, [])

  defp do_walk_up(path, acc) do
    parent = Path.dirname(path)

    if parent == path do
      # Filesystem root (Unix "/" or Windows "C:/")
      [path | acc]
    else
      do_walk_up(parent, [path | acc])
    end
  end

  # Scans a directory for skill subdirectories containing SKILL.md.
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

  defp parse_skill(skill_dir) do
    skill_md = Path.join(skill_dir, "SKILL.md")
    dir_name = Path.basename(skill_dir)

    with true <- File.regular?(skill_md),
         {:ok, skill} <- Opal.Skill.parse_file(skill_md),
         :ok <- Opal.Skill.validate(skill, dir_name: dir_name) do
      [skill]
    else
      _ -> []
    end
  end
end
