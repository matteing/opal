defmodule Opal.SkillTest do
  use ExUnit.Case, async: true

  alias Opal.Skill

  describe "parse/1" do
    test "parses valid SKILL.md with all fields" do
      content = """
      ---
      name: pdf-processing
      description: Extract text and tables from PDF files.
      license: Apache-2.0
      compatibility: Requires poppler-utils
      metadata:
        author: example-org
        version: "1.0"
      allowed-tools: Bash(git:*) Read
      ---

      # PDF Processing

      Step 1: Use poppler to extract text.
      """

      assert {:ok, skill} = Skill.parse(content)
      assert skill.name == "pdf-processing"
      assert skill.description == "Extract text and tables from PDF files."
      assert skill.license == "Apache-2.0"
      assert skill.compatibility == "Requires poppler-utils"
      assert skill.metadata == %{"author" => "example-org", "version" => "1.0"}
      assert skill.allowed_tools == ["Bash(git:*)", "Read"]
      assert skill.instructions =~ "PDF Processing"
      assert skill.instructions =~ "Step 1"
    end

    test "parses minimal SKILL.md (name + description only)" do
      content = """
      ---
      name: test-skill
      description: A test skill for testing.
      ---

      Do the thing.
      """

      assert {:ok, skill} = Skill.parse(content)
      assert skill.name == "test-skill"
      assert skill.description == "A test skill for testing."
      assert skill.license == nil
      assert skill.compatibility == nil
      assert skill.metadata == nil
      assert skill.allowed_tools == nil
      assert skill.instructions == "Do the thing."
    end

    test "parses SKILL.md with empty body" do
      content = """
      ---
      name: empty-body
      description: No instructions provided.
      ---
      """

      assert {:ok, skill} = Skill.parse(content)
      assert skill.name == "empty-body"
      assert skill.instructions == ""
    end

    test "returns error for missing frontmatter" do
      assert {:error, :no_frontmatter} = Skill.parse("# Just markdown\n\nNo frontmatter here.")
    end

    test "returns error for invalid YAML" do
      content = """
      ---
      name: [invalid
      ---

      Body.
      """

      assert {:error, {:yaml_parse_error, _}} = Skill.parse(content)
    end

    test "preserves multiline instructions" do
      content = """
      ---
      name: multi
      description: Multi-line instructions.
      ---

      # Step 1

      Do this first.

      # Step 2

      Then do this.

      ```python
      print("hello")
      ```
      """

      assert {:ok, skill} = Skill.parse(content)
      assert skill.instructions =~ "Step 1"
      assert skill.instructions =~ "Step 2"
      assert skill.instructions =~ "print(\"hello\")"
    end
  end

  describe "parse_file/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "opal_skill_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "parses a file from disk", %{dir: dir} do
      path = Path.join(dir, "SKILL.md")

      File.write!(path, """
      ---
      name: file-test
      description: Testing file parsing.
      ---

      Instructions here.
      """)

      assert {:ok, skill} = Skill.parse_file(path)
      assert skill.name == "file-test"
      assert skill.path == path
    end

    test "returns error for missing file" do
      assert {:error, {:file_error, :enoent, _}} = Skill.parse_file("/nonexistent/SKILL.md")
    end
  end

  describe "validate/2" do
    test "valid skill passes" do
      skill = %Skill{
        name: "valid-skill",
        description: "A valid skill.",
        instructions: "Do things."
      }

      assert :ok = Skill.validate(skill)
    end

    test "validates name is required" do
      skill = %Skill{name: nil, description: "Desc.", instructions: ""}
      assert {:error, errors} = Skill.validate(skill)
      assert "name is required" in errors
    end

    test "validates name format — no uppercase" do
      skill = %Skill{name: "Bad-Name", description: "Desc.", instructions: ""}
      assert {:error, errors} = Skill.validate(skill)
      assert Enum.any?(errors, &String.contains?(&1, "lowercase"))
    end

    test "validates name format — no consecutive hyphens" do
      skill = %Skill{name: "bad--name", description: "Desc.", instructions: ""}
      assert {:error, errors} = Skill.validate(skill)
      assert Enum.any?(errors, &String.contains?(&1, "consecutive hyphens"))
    end

    test "validates name format — no leading hyphen" do
      skill = %Skill{name: "-leading", description: "Desc.", instructions: ""}
      assert {:error, errors} = Skill.validate(skill)
      assert Enum.any?(errors, &String.contains?(&1, "lowercase"))
    end

    test "validates name format — no trailing hyphen" do
      skill = %Skill{name: "trailing-", description: "Desc.", instructions: ""}
      assert {:error, errors} = Skill.validate(skill)
      assert Enum.any?(errors, &String.contains?(&1, "lowercase"))
    end

    test "validates name length — max 64" do
      long_name = String.duplicate("a", 65)
      skill = %Skill{name: long_name, description: "Desc.", instructions: ""}
      assert {:error, errors} = Skill.validate(skill)
      assert Enum.any?(errors, &String.contains?(&1, "64"))
    end

    test "validates description is required" do
      skill = %Skill{name: "ok", description: nil, instructions: ""}
      assert {:error, errors} = Skill.validate(skill)
      assert "description is required" in errors
    end

    test "validates description length — max 1024" do
      long_desc = String.duplicate("a", 1025)
      skill = %Skill{name: "ok", description: long_desc, instructions: ""}
      assert {:error, errors} = Skill.validate(skill)
      assert Enum.any?(errors, &String.contains?(&1, "1024"))
    end

    test "validates compatibility length — max 500" do
      skill = %Skill{
        name: "ok",
        description: "Desc.",
        compatibility: String.duplicate("a", 501),
        instructions: ""
      }

      assert {:error, errors} = Skill.validate(skill)
      assert Enum.any?(errors, &String.contains?(&1, "500"))
    end

    test "validates dir_name match" do
      skill = %Skill{name: "my-skill", description: "Desc.", instructions: ""}
      assert :ok = Skill.validate(skill, dir_name: "my-skill")
      assert {:error, errors} = Skill.validate(skill, dir_name: "other-name")
      assert Enum.any?(errors, &String.contains?(&1, "must match directory"))
    end

    test "accepts single-character name" do
      skill = %Skill{name: "a", description: "Desc.", instructions: ""}
      assert :ok = Skill.validate(skill)
    end

    test "accepts name with numbers" do
      skill = %Skill{name: "skill-v2", description: "Desc.", instructions: ""}
      assert :ok = Skill.validate(skill)
    end

    test "validates non-binary name" do
      skill = %Skill{name: 123, description: "Desc.", instructions: ""}
      assert {:error, errors} = Skill.validate(skill)
      assert "name must be a string" in errors
    end

    test "validates non-binary description" do
      skill = %Skill{name: "ok", description: 123, instructions: ""}
      assert {:error, errors} = Skill.validate(skill)
      assert "description must be a string" in errors
    end

    test "validates non-binary compatibility" do
      skill = %Skill{name: "ok", description: "Desc.", compatibility: 42, instructions: ""}
      assert {:error, errors} = Skill.validate(skill)
      assert "compatibility must be a string" in errors
    end

    test "validates empty description" do
      skill = %Skill{name: "ok", description: "", instructions: ""}
      assert {:error, errors} = Skill.validate(skill)
      assert Enum.any?(errors, &String.contains?(&1, "empty"))
    end

    test "collects multiple validation errors" do
      skill = %Skill{name: nil, description: nil, instructions: ""}
      assert {:error, errors} = Skill.validate(skill)
      assert length(errors) >= 2
    end
  end

  describe "summary/1" do
    test "returns formatted summary" do
      skill = %Skill{name: "my-skill", description: "Does cool things.", instructions: ""}
      assert Skill.summary(skill) == "- **my-skill**: Does cool things."
    end
  end

  describe "parse/1 — frontmatter edge cases" do
    test "returns error for non-map YAML" do
      content = """
      ---
      - item1
      - item2
      ---

      Body.
      """

      assert {:error, :invalid_frontmatter} = Skill.parse(content)
    end

    test "handles allowed-tools as non-string" do
      content = """
      ---
      name: test
      description: Test skill.
      allowed-tools: 42
      ---

      Body.
      """

      assert {:ok, skill} = Skill.parse(content)
      assert skill.allowed_tools == nil
    end

    test "ignores unknown frontmatter keys" do
      content = """
      ---
      name: test
      description: Test skill.
      globs: 42
      ---

      Body.
      """

      assert {:ok, skill} = Skill.parse(content)
      assert skill.name == "test"
    end
  end
end
