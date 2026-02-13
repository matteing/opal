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

  @doc """
  Discovers context files by walking up from `working_dir`.

  Returns a list of `%{path: String.t(), content: String.t()}` maps,
  ordered from root-most to deepest (closest to `working_dir` comes last).

  ## Options

    * `:filenames` — list of filenames to look for (default from config).
      Also searches `.agents/<filename>` and `.opal/<filename>` variants.
  """
  @spec discover_context(String.t(), keyword()) :: [%{path: String.t(), content: String.t()}]
  def discover_context(working_dir, opts \\ []) do
    filenames = Keyword.get(opts, :filenames, ["AGENTS.md", "OPAL.md"])

    working_dir
    |> Path.expand()
    |> walk_up()
    |> Enum.flat_map(fn dir ->
      candidates =
        Enum.flat_map(filenames, fn filename ->
          [
            Path.join(dir, filename),
            Path.join([dir, ".agents", filename]),
            Path.join([dir, ".opal", filename])
          ]
        end)

      candidates
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(fn path ->
        %{path: path, content: File.read!(path)}
      end)
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
    home = System.user_home!()

    search_dirs =
      [
        Path.join([Path.expand(working_dir), ".agents", "skills"]),
        Path.join([Path.expand(working_dir), ".github", "skills"]),
        Path.join([Path.expand(working_dir), ".claude", "skills"]),
        Path.join([home, ".agents", "skills"]),
        Path.join([home, ".opal", "skills"]),
        Path.join([home, ".claude", "skills"])
      ] ++ Enum.map(extra_dirs, &Path.expand/1)

    search_dirs
    |> Enum.uniq()
    |> Enum.flat_map(&scan_skills_dir/1)
    |> Enum.uniq_by(& &1.name)
  end

  @doc """
  Builds the context string to inject into the system prompt.

  Concatenates discovered context files and skill summaries into a single
  string block. Returns an empty string if no context is found.

  ## Options

    * `:filenames` — context filenames (default: `["AGENTS.md", "OPAL.md"]`)
    * `:extra_dirs` — additional skill directories (default: `[]`)
    * `:skip_skills` — if `true`, skip skill discovery entirely (default: `false`)
  """
  @spec build_context(String.t(), keyword()) :: String.t()
  def build_context(working_dir, opts \\ []) do
    context_files = discover_context(working_dir, opts)
    skip_skills = Keyword.get(opts, :skip_skills, false)

    skills =
      if skip_skills do
        []
      else
        discover_skills(working_dir, opts)
      end

    parts = []

    # Context files
    parts =
      if context_files != [] do
        file_blocks =
          Enum.map_join(context_files, "\n\n", fn %{path: path, content: content} ->
            "<!-- From: #{path} -->\n#{content}"
          end)

        parts ++ ["\n## Project Context\n\n#{file_blocks}"]
      else
        parts
      end

    # Skills summary
    parts =
      if skills != [] do
        skill_lines =
          Enum.map_join(skills, "\n", fn skill ->
            "- **#{skill.name}**: #{skill.description}"
          end)

        parts ++ ["\n## Available Skills\n\n#{skill_lines}"]
      else
        parts
      end

    Enum.join(parts, "\n")
  end

  # --- Private ---

  # Returns directories from the given path up to the filesystem root.
  # Result is ordered root-first (deepest directory last).
  defp walk_up(path) do
    do_walk_up(path, [])
  end

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
    if File.dir?(dir) do
      case File.ls(dir) do
        {:ok, entries} ->
          entries
          |> Enum.map(fn entry -> Path.join(dir, entry) end)
          |> Enum.filter(&File.dir?/1)
          |> Enum.flat_map(fn skill_dir ->
            skill_md = Path.join(skill_dir, "SKILL.md")

            if File.regular?(skill_md) do
              dir_name = Path.basename(skill_dir)

              case Opal.Skill.parse_file(skill_md) do
                {:ok, skill} ->
                  case Opal.Skill.validate(skill, dir_name: dir_name) do
                    :ok -> [skill]
                    {:error, _} -> []
                  end

                {:error, _} ->
                  []
              end
            else
              []
            end
          end)

        {:error, _} ->
          []
      end
    else
      []
    end
  end
end
