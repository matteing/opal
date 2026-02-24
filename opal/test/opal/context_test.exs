defmodule Opal.ContextTest do
  use ExUnit.Case, async: true

  alias Opal.Context

  setup do
    base = Path.join(System.tmp_dir!(), "opal_ctx_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base}
  end

  describe "discover_context/2" do
    test "finds AGENTS.md walking up", %{base: base} do
      # Create nested dirs: base/project/src
      project = Path.join(base, "project")
      src = Path.join(project, "src")
      File.mkdir_p!(src)

      # Place AGENTS.md at project root
      agents_path = Path.join(project, "AGENTS.md")
      File.write!(agents_path, "Project context here.")

      result = Context.discover_context(src, filenames: ["AGENTS.md"])
      assert length(result) == 1
      assert hd(result).content == "Project context here."
      assert hd(result).path == agents_path
    end

    test "finds files in .agents/ subdirectory", %{base: base} do
      agents_dir = Path.join(base, ".agents")
      File.mkdir_p!(agents_dir)
      path = Path.join(agents_dir, "AGENTS.md")
      File.write!(path, "Dot-agents context.")

      result = Context.discover_context(base, filenames: ["AGENTS.md"])
      assert Enum.any?(result, &(&1.content == "Dot-agents context."))
    end

    test "finds files in .opal/ subdirectory", %{base: base} do
      opal_dir = Path.join(base, ".opal")
      File.mkdir_p!(opal_dir)
      path = Path.join(opal_dir, "OPAL.md")
      File.write!(path, "Opal context.")

      result = Context.discover_context(base, filenames: ["OPAL.md"])
      assert Enum.any?(result, &(&1.content == "Opal context."))
    end

    test "collects from multiple levels (root-first order)", %{base: base} do
      child = Path.join(base, "child")
      File.mkdir_p!(child)

      File.write!(Path.join(base, "AGENTS.md"), "Root context.")
      File.write!(Path.join(child, "AGENTS.md"), "Child context.")

      result =
        Context.discover_context(child, filenames: ["AGENTS.md"])
        |> Enum.filter(&String.starts_with?(&1.path, base))

      assert length(result) == 2
      # Root-first ordering: root comes first, child comes last (higher priority)
      [first, second] = result
      assert first.content == "Root context."
      assert second.content == "Child context."
    end

    test "returns empty list when no context files exist", %{base: base} do
      result = Context.discover_context(base, filenames: ["AGENTS.md"])
      # May find files in parent dirs; filter to just our base
      base_results = Enum.filter(result, &String.starts_with?(&1.path, base))
      assert base_results == []
    end
  end

  describe "discover_skills/2" do
    test "discovers valid skills from directory", %{base: base} do
      skills_dir = Path.join([base, ".agents", "skills"])

      # Create a valid skill
      skill_dir = Path.join(skills_dir, "my-skill")
      File.mkdir_p!(skill_dir)

      File.write!(Path.join(skill_dir, "SKILL.md"), """
      ---
      name: my-skill
      description: A test skill for discovery.
      ---

      Instructions for my-skill.
      """)

      skills = Context.discover_skills(base)
      assert length(skills) == 1
      assert hd(skills).name == "my-skill"
      assert hd(skills).description == "A test skill for discovery."
    end

    test "skips invalid skills silently", %{base: base} do
      skills_dir = Path.join([base, ".agents", "skills"])

      # Create an invalid skill (name mismatch)
      skill_dir = Path.join(skills_dir, "wrong-dir")
      File.mkdir_p!(skill_dir)

      File.write!(Path.join(skill_dir, "SKILL.md"), """
      ---
      name: different-name
      description: Name doesn't match dir.
      ---

      Instructions.
      """)

      skills = Context.discover_skills(base)
      assert skills == []
    end

    test "discovers from extra_dirs", %{base: base} do
      extra = Path.join(base, "extra-skills")
      skill_dir = Path.join(extra, "extra-skill")
      File.mkdir_p!(skill_dir)

      File.write!(Path.join(skill_dir, "SKILL.md"), """
      ---
      name: extra-skill
      description: From extra dir.
      ---

      Extra instructions.
      """)

      skills = Context.discover_skills(base, extra_dirs: [extra])
      assert Enum.any?(skills, &(&1.name == "extra-skill"))
    end

    test "deduplicates skills by name", %{base: base} do
      # Create same-named skill in two places
      dir1 = Path.join([base, ".agents", "skills", "dup-skill"])
      dir2 = Path.join(base, "extra")
      dir2_skill = Path.join(dir2, "dup-skill")
      File.mkdir_p!(dir1)
      File.mkdir_p!(dir2_skill)

      content = """
      ---
      name: dup-skill
      description: Duplicated skill.
      ---

      Instructions.
      """

      File.write!(Path.join(dir1, "SKILL.md"), content)
      File.write!(Path.join(dir2_skill, "SKILL.md"), content)

      skills = Context.discover_skills(base, extra_dirs: [dir2])
      matching = Enum.filter(skills, &(&1.name == "dup-skill"))
      assert length(matching) == 1
    end

    test "discovers multiple skills", %{base: base} do
      skills_dir = Path.join([base, ".agents", "skills"])

      for name <- ["alpha", "beta", "gamma"] do
        dir = Path.join(skills_dir, name)
        File.mkdir_p!(dir)

        File.write!(Path.join(dir, "SKILL.md"), """
        ---
        name: #{name}
        description: Skill #{name}.
        ---

        Instructions for #{name}.
        """)
      end

      skills = Context.discover_skills(base)
      names = Enum.map(skills, & &1.name) |> Enum.sort()
      assert names == ["alpha", "beta", "gamma"]
    end

    test "returns empty list when no skills directory exists", %{base: base} do
      skills = Context.discover_skills(base)
      assert skills == []
    end

    test "discovers skills from .github/skills", %{base: base} do
      skill_dir = Path.join([base, ".github", "skills", "gh-skill"])
      File.mkdir_p!(skill_dir)

      File.write!(Path.join(skill_dir, "SKILL.md"), """
      ---
      name: gh-skill
      description: A GitHub-style skill.
      ---

      GitHub skill instructions.
      """)

      skills = Context.discover_skills(base)
      assert length(skills) == 1
      assert hd(skills).name == "gh-skill"
    end
  end
end
