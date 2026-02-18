defmodule Opal.GitignoreTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Opal.Gitignore

  describe "load/1" do
    test "returns empty struct when .gitignore doesn't exist", %{tmp_dir: tmp_dir} do
      gitignore = Gitignore.load(tmp_dir)

      assert %Gitignore{rules: [], root: ^tmp_dir} = gitignore
      refute Gitignore.ignored?(gitignore, "anything.txt")
    end

    test "loads and parses .gitignore from directory", %{tmp_dir: tmp_dir} do
      gitignore_path = Path.join(tmp_dir, ".gitignore")

      File.write!(gitignore_path, """
      *.log
      build/
      """)

      gitignore = Gitignore.load(tmp_dir)

      assert %Gitignore{root: ^tmp_dir} = gitignore
      assert Gitignore.ignored?(gitignore, "error.log")
      assert Gitignore.ignored?(gitignore, "build", true)
    end

    test "handles missing directory gracefully" do
      gitignore = Gitignore.load("/nonexistent/path")

      assert %Gitignore{rules: [], root: "/nonexistent/path"} = gitignore
      refute Gitignore.ignored?(gitignore, "anything.txt")
    end
  end

  describe "parse/2" do
    test "handles empty content" do
      gitignore = Gitignore.parse("", "/root")

      assert %Gitignore{rules: [], root: "/root"} = gitignore
      refute Gitignore.ignored?(gitignore, "anything.txt")
    end

    test "ignores blank lines" do
      gitignore =
        Gitignore.parse(
          """


          *.log

          """,
          "/root"
        )

      assert Gitignore.ignored?(gitignore, "error.log")
      refute Gitignore.ignored?(gitignore, "file.txt")
    end

    test "ignores comment lines" do
      gitignore =
        Gitignore.parse(
          """
          # This is a comment
          *.log
          # Another comment
          ## Double hash
          """,
          "/root"
        )

      assert Gitignore.ignored?(gitignore, "error.log")
      refute Gitignore.ignored?(gitignore, "# This is a comment")
    end

    test "handles inline comments (not standard but common)" do
      gitignore =
        Gitignore.parse(
          """
          *.log # ignore all logs
          """,
          "/root"
        )

      # Gitignore does NOT support inline comments. The whole line including
      # " # ignore all logs" is part of the pattern, so "error.log" alone won't match.
      refute Gitignore.ignored?(gitignore, "error.log")
      assert Gitignore.ignored?(gitignore, "error.log # ignore all logs")
    end
  end

  describe "simple filename patterns" do
    test "matches extension patterns anywhere" do
      gitignore =
        Gitignore.parse(
          """
          *.log
          *.tmp
          """,
          "/root"
        )

      assert Gitignore.ignored?(gitignore, "error.log")
      assert Gitignore.ignored?(gitignore, "debug.tmp")
      assert Gitignore.ignored?(gitignore, "src/nested/file.log")
      assert Gitignore.ignored?(gitignore, "deep/path/to/temp.tmp")
      refute Gitignore.ignored?(gitignore, "file.txt")
      refute Gitignore.ignored?(gitignore, "logfile")
    end

    test "matches exact filenames anywhere" do
      gitignore =
        Gitignore.parse(
          """
          .DS_Store
          Thumbs.db
          """,
          "/root"
        )

      assert Gitignore.ignored?(gitignore, ".DS_Store")
      assert Gitignore.ignored?(gitignore, "folder/.DS_Store")
      assert Gitignore.ignored?(gitignore, "deep/nested/path/Thumbs.db")
      refute Gitignore.ignored?(gitignore, "DS_Store")
      refute Gitignore.ignored?(gitignore, ".DS_Store.bak")
    end
  end

  describe "directory-only patterns" do
    test "trailing slash matches directories only" do
      gitignore =
        Gitignore.parse(
          """
          build/
          tmp/
          """,
          "/root"
        )

      assert Gitignore.ignored?(gitignore, "build", true)
      assert Gitignore.ignored?(gitignore, "src/build", true)
      assert Gitignore.ignored?(gitignore, "tmp", true)

      refute Gitignore.ignored?(gitignore, "build", false)
      refute Gitignore.ignored?(gitignore, "src/build", false)
      refute Gitignore.ignored?(gitignore, "tmp", false)
    end

    test "patterns without trailing slash match both files and directories" do
      gitignore =
        Gitignore.parse(
          """
          build
          """,
          "/root"
        )

      assert Gitignore.ignored?(gitignore, "build", true)
      assert Gitignore.ignored?(gitignore, "build", false)
      assert Gitignore.ignored?(gitignore, "src/build", true)
      assert Gitignore.ignored?(gitignore, "src/build", false)
    end
  end

  describe "negation patterns" do
    test "! prefix negates a pattern" do
      gitignore =
        Gitignore.parse(
          """
          *.log
          !important.log
          """,
          "/root"
        )

      assert Gitignore.ignored?(gitignore, "error.log")
      assert Gitignore.ignored?(gitignore, "debug.log")
      refute Gitignore.ignored?(gitignore, "important.log")
    end

    test "negation works with nested paths" do
      gitignore =
        Gitignore.parse(
          """
          *.log
          !src/important.log
          """,
          "/root"
        )

      assert Gitignore.ignored?(gitignore, "error.log")
      assert Gitignore.ignored?(gitignore, "src/debug.log")
      refute Gitignore.ignored?(gitignore, "src/important.log")
    end

    test "last matching rule wins" do
      gitignore =
        Gitignore.parse(
          """
          *.log
          !important.log
          secret.log
          """,
          "/root"
        )

      assert Gitignore.ignored?(gitignore, "error.log")
      refute Gitignore.ignored?(gitignore, "important.log")
      assert Gitignore.ignored?(gitignore, "secret.log")
    end

    test "re-negation brings back ignored files" do
      gitignore =
        Gitignore.parse(
          """
          *.log
          !important.log
          *.log
          """,
          "/root"
        )

      assert Gitignore.ignored?(gitignore, "important.log")
    end

    test "negating a directory" do
      gitignore =
        Gitignore.parse(
          """
          build/
          !build/keep/
          """,
          "/root"
        )

      assert Gitignore.ignored?(gitignore, "build", true)
      refute Gitignore.ignored?(gitignore, "build/keep", true)
    end
  end

  describe "rooted patterns" do
    test "leading slash matches only at root" do
      gitignore =
        Gitignore.parse(
          """
          /TODO
          /build
          """,
          "/root"
        )

      assert Gitignore.ignored?(gitignore, "TODO")
      assert Gitignore.ignored?(gitignore, "build")
      refute Gitignore.ignored?(gitignore, "src/TODO")
      refute Gitignore.ignored?(gitignore, "docs/build")
    end

    test "patterns with slash but not leading match from root" do
      gitignore =
        Gitignore.parse(
          """
          src/generated
          """,
          "/root"
        )

      assert Gitignore.ignored?(gitignore, "src/generated")
      assert Gitignore.ignored?(gitignore, "src/generated/file.txt")
      refute Gitignore.ignored?(gitignore, "generated")
      refute Gitignore.ignored?(gitignore, "other/src/generated")
    end

    test "rooted directory patterns" do
      gitignore =
        Gitignore.parse(
          """
          /dist/
          """,
          "/root"
        )

      assert Gitignore.ignored?(gitignore, "dist", true)
      refute Gitignore.ignored?(gitignore, "src/dist", true)
      refute Gitignore.ignored?(gitignore, "dist", false)
    end
  end

  describe "wildcard patterns" do
    test "* matches anything except slash" do
      gitignore =
        Gitignore.parse(
          """
          *.log
          test_*.ex
          *_backup
          """,
          "/root"
        )

      assert Gitignore.ignored?(gitignore, "error.log")
      assert Gitignore.ignored?(gitignore, "test_helper.ex")
      assert Gitignore.ignored?(gitignore, "file_backup")
      assert Gitignore.ignored?(gitignore, "src/test_helper.ex")
    end

    test "? matches single character except slash" do
      gitignore =
        Gitignore.parse(
          """
          file?.txt
          test_?.ex
          """,
          "/root"
        )

      assert Gitignore.ignored?(gitignore, "file1.txt")
      assert Gitignore.ignored?(gitignore, "fileA.txt")
      assert Gitignore.ignored?(gitignore, "test_1.ex")
      refute Gitignore.ignored?(gitignore, "file10.txt")
      refute Gitignore.ignored?(gitignore, "file.txt")
    end

    test "character classes [...]" do
      gitignore =
        Gitignore.parse(
          """
          *.[oa]
          file[0-9].txt
          [A-Z]*.log
          """,
          "/root"
        )

      assert Gitignore.ignored?(gitignore, "lib.o")
      assert Gitignore.ignored?(gitignore, "lib.a")
      assert Gitignore.ignored?(gitignore, "file0.txt")
      assert Gitignore.ignored?(gitignore, "file9.txt")
      assert Gitignore.ignored?(gitignore, "Error.log")
      assert Gitignore.ignored?(gitignore, "Z123.log")
      refute Gitignore.ignored?(gitignore, "lib.so")
      refute Gitignore.ignored?(gitignore, "fileA.txt")
      refute Gitignore.ignored?(gitignore, "error.log")
    end

    test "negated character classes [!...]" do
      gitignore =
        Gitignore.parse(
          """
          *.[!o]
          file[!0-9].txt
          """,
          "/root"
        )

      assert Gitignore.ignored?(gitignore, "lib.a")
      assert Gitignore.ignored?(gitignore, "lib.c")
      assert Gitignore.ignored?(gitignore, "fileA.txt")
      assert Gitignore.ignored?(gitignore, "file_.txt")
      refute Gitignore.ignored?(gitignore, "lib.o")
      refute Gitignore.ignored?(gitignore, "file0.txt")
      refute Gitignore.ignored?(gitignore, "file9.txt")
    end
  end

  describe "double-star patterns" do
    test "**/foo matches foo at any depth" do
      gitignore =
        Gitignore.parse(
          """
          **/node_modules
          **/generated
          """,
          "/root"
        )

      assert Gitignore.ignored?(gitignore, "node_modules")
      assert Gitignore.ignored?(gitignore, "src/node_modules")
      assert Gitignore.ignored?(gitignore, "deep/nested/path/node_modules")
      assert Gitignore.ignored?(gitignore, "generated")
      assert Gitignore.ignored?(gitignore, "src/generated")
      refute Gitignore.ignored?(gitignore, "my_node_modules")
    end

    test "foo/** matches everything under foo" do
      gitignore =
        Gitignore.parse(
          """
          build/**
          target/**
          """,
          "/root"
        )

      assert Gitignore.ignored?(gitignore, "build/output.js")
      assert Gitignore.ignored?(gitignore, "build/dist/bundle.js")
      assert Gitignore.ignored?(gitignore, "build/deep/nested/file.txt")
      assert Gitignore.ignored?(gitignore, "target/classes/Main.class")
      refute Gitignore.ignored?(gitignore, "build")
      refute Gitignore.ignored?(gitignore, "src/build/file.txt")
    end

    test "a/**/b matches b under a at any depth" do
      gitignore =
        Gitignore.parse(
          """
          src/**/generated
          test/**/fixtures
          """,
          "/root"
        )

      assert Gitignore.ignored?(gitignore, "src/generated")
      assert Gitignore.ignored?(gitignore, "src/nested/generated")
      assert Gitignore.ignored?(gitignore, "src/deep/nested/path/generated")
      assert Gitignore.ignored?(gitignore, "test/fixtures")
      assert Gitignore.ignored?(gitignore, "test/unit/fixtures")
      refute Gitignore.ignored?(gitignore, "generated")
      refute Gitignore.ignored?(gitignore, "other/src/generated")
      refute Gitignore.ignored?(gitignore, "src/generated_code")
    end

    test "**/*.log matches .log files at any depth" do
      gitignore =
        Gitignore.parse(
          """
          **/*.log
          **/*.tmp
          """,
          "/root"
        )

      assert Gitignore.ignored?(gitignore, "error.log")
      assert Gitignore.ignored?(gitignore, "src/debug.log")
      assert Gitignore.ignored?(gitignore, "deep/nested/path/error.log")
      assert Gitignore.ignored?(gitignore, "temp.tmp")
      refute Gitignore.ignored?(gitignore, "log")
      refute Gitignore.ignored?(gitignore, "errorlog.txt")
    end
  end

  describe "nested path matching" do
    test "matches nested directory patterns" do
      gitignore =
        Gitignore.parse(
          """
          src/generated/
          docs/api/build/
          """,
          "/root"
        )

      assert Gitignore.ignored?(gitignore, "src/generated", true)
      assert Gitignore.ignored?(gitignore, "docs/api/build", true)
      refute Gitignore.ignored?(gitignore, "generated", true)
      refute Gitignore.ignored?(gitignore, "other/src/generated", true)

      refute Gitignore.ignored?(gitignore, "src/generated", false)
      refute Gitignore.ignored?(gitignore, "src/generated/code.ex", false)
    end

    test "matches files in nested paths" do
      gitignore =
        Gitignore.parse(
          """
          src/generated/*.ex
          test/**/fixtures/*.json
          """,
          "/root"
        )

      assert Gitignore.ignored?(gitignore, "src/generated/code.ex")
      assert Gitignore.ignored?(gitignore, "test/fixtures/data.json")
      assert Gitignore.ignored?(gitignore, "test/unit/fixtures/data.json")
      refute Gitignore.ignored?(gitignore, "src/code.ex")
      refute Gitignore.ignored?(gitignore, "src/generated/nested/code.ex")
      refute Gitignore.ignored?(gitignore, "test/data.json")
    end
  end

  describe "merge/2" do
    test "combines rules from parent and child" do
      parent =
        Gitignore.parse(
          """
          *.log
          build/
          """,
          "/root"
        )

      child =
        Gitignore.parse(
          """
          *.tmp
          node_modules/
          """,
          "/root/src"
        )

      merged = Gitignore.merge(parent, child)

      assert Gitignore.ignored?(merged, "error.log")
      assert Gitignore.ignored?(merged, "temp.tmp")
      assert Gitignore.ignored?(merged, "build", true)
      assert Gitignore.ignored?(merged, "node_modules", true)
    end

    test "child rules override parent rules (last wins)" do
      parent = Gitignore.parse("*.log", "/root")
      child = Gitignore.parse("!important.log", "/root/src")

      merged = Gitignore.merge(parent, child)

      assert Gitignore.ignored?(merged, "error.log")
      refute Gitignore.ignored?(merged, "important.log")
    end

    test "merges empty gitignores" do
      parent = Gitignore.parse("", "/root")
      child = Gitignore.parse("*.log", "/root/src")

      merged = Gitignore.merge(parent, child)
      assert Gitignore.ignored?(merged, "error.log")

      parent = Gitignore.parse("*.log", "/root")
      child = Gitignore.parse("", "/root/src")

      merged = Gitignore.merge(parent, child)
      assert Gitignore.ignored?(merged, "error.log")
    end

    test "preserves parent root" do
      parent = Gitignore.parse("*.log", "/root")
      child = Gitignore.parse("*.tmp", "/root/src")

      merged = Gitignore.merge(parent, child)
      assert merged.root == "/root"
    end
  end

  describe "edge cases" do
    test "lines starting with # are comments" do
      gitignore = Gitignore.parse("# this is a comment\n*.log\n", "/root")
      assert length(gitignore.rules) == 1
      assert Gitignore.ignored?(gitignore, "error.log")
    end

    test "handles trailing spaces in patterns" do
      gitignore = Gitignore.parse("*.log   \nfile.txt  \n", "/root")

      assert Gitignore.ignored?(gitignore, "error.log")
      assert Gitignore.ignored?(gitignore, "file.txt")
      refute Gitignore.ignored?(gitignore, "file.txt  ")
    end

    test "handles patterns with multiple asterisks" do
      gitignore = Gitignore.parse("**/**/foo\n**/bar/**\n", "/root")

      assert Gitignore.ignored?(gitignore, "foo")
      assert Gitignore.ignored?(gitignore, "nested/foo")
      assert Gitignore.ignored?(gitignore, "bar/file.txt")
      assert Gitignore.ignored?(gitignore, "nested/bar/file.txt")
    end

    test "handles empty pattern (just whitespace)" do
      gitignore = Gitignore.parse("\n   \n\t\n*.log\n", "/root")

      assert Gitignore.ignored?(gitignore, "error.log")
      refute Gitignore.ignored?(gitignore, "file.txt")
    end

    test "handles very long paths" do
      gitignore = Gitignore.parse("*.log\na/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/\n", "/root")
      long_path = "a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p"

      assert Gitignore.ignored?(gitignore, long_path, true)
      refute Gitignore.ignored?(gitignore, "#{long_path}/file.txt", false)
    end

    test "handles patterns with only special characters" do
      gitignore = Gitignore.parse("*\n?\n**\n", "/root")

      assert Gitignore.ignored?(gitignore, "file.txt")
      assert Gitignore.ignored?(gitignore, "a")
      assert Gitignore.ignored?(gitignore, "nested/file.txt")
    end

    test "handles Unicode filenames" do
      gitignore = Gitignore.parse("*.日本語\nфайл.txt\n", "/root")

      assert Gitignore.ignored?(gitignore, "test.日本語")
      assert Gitignore.ignored?(gitignore, "файл.txt")
      refute Gitignore.ignored?(gitignore, "test.txt")
    end

    test "handles patterns with dots" do
      gitignore = Gitignore.parse(".\n..\n.git\n.env.local\n", "/root")

      assert Gitignore.ignored?(gitignore, ".git")
      assert Gitignore.ignored?(gitignore, ".env.local")
    end

    test "handles case sensitivity" do
      gitignore = Gitignore.parse("*.LOG\nBUILD/\n", "/root")

      assert Gitignore.ignored?(gitignore, "error.LOG")
      assert Gitignore.ignored?(gitignore, "BUILD", true)
    end
  end

  describe "complex real-world scenarios" do
    test "typical Node.js project gitignore" do
      gitignore =
        Gitignore.parse(
          """
          # Dependencies
          node_modules/
          npm-debug.log*

          # Production
          /build
          /dist

          # Misc
          .DS_Store
          .env.local
          .env.development.local
          .env.test.local
          .env.production.local

          # IDE
          .idea/
          .vscode/
          *.swp
          *.swo
          """,
          "/root"
        )

      assert Gitignore.ignored?(gitignore, "node_modules", true)
      assert Gitignore.ignored?(gitignore, "src/node_modules", true)
      assert Gitignore.ignored?(gitignore, "npm-debug.log")
      assert Gitignore.ignored?(gitignore, "npm-debug.log.1")
      assert Gitignore.ignored?(gitignore, "build")
      assert Gitignore.ignored?(gitignore, "dist")
      refute Gitignore.ignored?(gitignore, "src/build")
      refute Gitignore.ignored?(gitignore, "src/dist")
      assert Gitignore.ignored?(gitignore, ".DS_Store")
      assert Gitignore.ignored?(gitignore, "src/.DS_Store")
      assert Gitignore.ignored?(gitignore, ".env.local")
      assert Gitignore.ignored?(gitignore, ".idea", true)
      assert Gitignore.ignored?(gitignore, ".vscode", true)
      assert Gitignore.ignored?(gitignore, "file.swp")
    end

    test "typical Elixir project gitignore" do
      gitignore =
        Gitignore.parse(
          """
          # Mix
          /_build/
          /cover/
          /deps/
          /doc/
          /.fetch
          erl_crash.dump
          *.ez
          *-temp

          # IDE
          /.elixir_ls/
          .vscode/
          """,
          "/root"
        )

      assert Gitignore.ignored?(gitignore, "_build", true)
      assert Gitignore.ignored?(gitignore, "cover", true)
      assert Gitignore.ignored?(gitignore, "deps", true)
      refute Gitignore.ignored?(gitignore, "src/_build", true)
      assert Gitignore.ignored?(gitignore, "erl_crash.dump")
      assert Gitignore.ignored?(gitignore, "mylib.ez")
      assert Gitignore.ignored?(gitignore, "file-temp")
      assert Gitignore.ignored?(gitignore, ".elixir_ls", true)
    end

    test "overlapping patterns with negations" do
      gitignore =
        Gitignore.parse(
          """
          # Ignore all .env files
          .env*

          # But not the example
          !.env.example

          # Ignore all build output
          build/

          # But keep build scripts
          !build/*.sh

          # Ignore all logs
          **/*.log

          # But keep important logs
          !**/important.log
          """,
          "/root"
        )

      assert Gitignore.ignored?(gitignore, ".env")
      assert Gitignore.ignored?(gitignore, ".env.local")
      refute Gitignore.ignored?(gitignore, ".env.example")

      assert Gitignore.ignored?(gitignore, "build", true)
      refute Gitignore.ignored?(gitignore, "build/output.js")

      assert Gitignore.ignored?(gitignore, "error.log")
      assert Gitignore.ignored?(gitignore, "src/debug.log")
      refute Gitignore.ignored?(gitignore, "important.log")
      refute Gitignore.ignored?(gitignore, "logs/important.log")
    end
  end
end
