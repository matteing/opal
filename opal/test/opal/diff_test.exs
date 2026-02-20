defmodule Opal.DiffTest do
  use ExUnit.Case, async: true

  alias Opal.Diff

  describe "compute/4" do
    test "simple replacement - change one line in a 5-line file" do
      old_content = """
      line 1
      line 2
      line 3
      line 4
      line 5
      """

      new_content = """
      line 1
      line 2
      modified line 3
      line 4
      line 5
      """

      result = Diff.compute(old_content, new_content, "test.txt")

      assert result.path == "test.txt"
      assert result.lines_removed == 1
      assert result.lines_added == 1
      assert length(result.hunks) == 1

      hunk = hd(result.hunks)
      assert hunk.old_start == 1
      assert hunk.new_start == 1

      # Should have 3 lines of context before + change + 2 lines after (limited by file end)
      assert [
               %{op: :eq, old_no: 1, new_no: 1, text: "line 1"},
               %{op: :eq, old_no: 2, new_no: 2, text: "line 2"},
               %{op: :del, old_no: 3, text: "line 3"},
               %{op: :ins, new_no: 3, text: "modified line 3"},
               %{op: :eq, old_no: 4, new_no: 4, text: "line 4"},
               %{op: :eq, old_no: 5, new_no: 5, text: "line 5"},
               %{op: :eq, old_no: 6, new_no: 6, text: ""}
             ] = hunk.lines
    end

    test "new file - old_content is nil, everything is :ins" do
      new_content = "line 1\nline 2\nline 3"

      result = Diff.compute(nil, new_content, "new_file.txt")

      assert result.path == "new_file.txt"
      assert result.lines_removed == 1
      assert result.lines_added == 3
      assert length(result.hunks) == 1

      hunk = hd(result.hunks)
      assert hunk.new_start == 1

      assert [
               %{op: :del, old_no: 1, text: ""},
               %{op: :ins, new_no: 1, text: "line 1"},
               %{op: :ins, new_no: 2, text: "line 2"},
               %{op: :ins, new_no: 3, text: "line 3"}
             ] = hunk.lines

      # :ins operations should not have old_no
      hunk.lines
      |> Enum.filter(&(&1.op == :ins))
      |> Enum.each(fn line -> refute Map.has_key?(line, :old_no) end)
    end

    test "deletion - remove lines (new content is shorter)" do
      old_content = """
      line 1
      line 2
      line 3
      line 4
      line 5
      """

      new_content = """
      line 1
      line 5
      """

      result = Diff.compute(old_content, new_content, "test.txt")

      assert result.path == "test.txt"
      assert result.lines_removed == 3
      assert result.lines_added == 0
      assert length(result.hunks) == 1

      hunk = hd(result.hunks)

      assert [
               %{op: :eq, old_no: 1, new_no: 1, text: "line 1"},
               %{op: :del, old_no: 2, text: "line 2"},
               %{op: :del, old_no: 3, text: "line 3"},
               %{op: :del, old_no: 4, text: "line 4"},
               %{op: :eq, old_no: 5, new_no: 2, text: "line 5"},
               %{op: :eq, old_no: 6, new_no: 3, text: ""}
             ] = hunk.lines
    end

    test "deletion - empty new content" do
      old_content = "line 1\nline 2"

      new_content = ""

      result = Diff.compute(old_content, new_content, "deleted.txt")

      assert result.lines_removed == 2
      assert result.lines_added == 1
      assert length(result.hunks) == 1

      hunk = hd(result.hunks)

      assert [
               %{op: :del, old_no: 1, text: "line 1"},
               %{op: :del, old_no: 2, text: "line 2"},
               %{op: :ins, new_no: 1, text: ""}
             ] = hunk.lines
    end

    test "multiple hunks - changes far apart produce separate hunks" do
      old_content = """
      line 1
      line 2
      line 3
      line 4
      line 5
      line 6
      line 7
      line 8
      line 9
      line 10
      line 11
      line 12
      line 13
      line 14
      line 15
      """

      new_content = """
      modified 1
      line 2
      line 3
      line 4
      line 5
      line 6
      line 7
      line 8
      line 9
      line 10
      line 11
      line 12
      line 13
      line 14
      modified 15
      """

      result = Diff.compute(old_content, new_content, "test.txt")

      assert result.lines_removed == 2
      assert result.lines_added == 2
      # Changes at line 1 and 15 are far apart (default context=3)
      assert length(result.hunks) == 2

      [hunk1, hunk2] = result.hunks

      # First hunk: change at line 1 with context
      assert hunk1.old_start == 1
      assert hunk1.new_start == 1
      assert List.first(hunk1.lines) == %{op: :del, old_no: 1, text: "line 1"}
      assert Enum.at(hunk1.lines, 1) == %{op: :ins, new_no: 1, text: "modified 1"}

      # Second hunk: change at line 15 with context
      assert hunk2.old_start == 12
      assert hunk2.new_start == 12
      # Should have 3 lines of context before the change
      assert Enum.at(hunk2.lines, 0) == %{op: :eq, old_no: 12, new_no: 12, text: "line 12"}
      assert Enum.at(hunk2.lines, 1) == %{op: :eq, old_no: 13, new_no: 13, text: "line 13"}
      assert Enum.at(hunk2.lines, 2) == %{op: :eq, old_no: 14, new_no: 14, text: "line 14"}
      assert Enum.at(hunk2.lines, 3) == %{op: :del, old_no: 15, text: "line 15"}
      assert Enum.at(hunk2.lines, 4) == %{op: :ins, new_no: 15, text: "modified 15"}
    end

    test "merged hunks - changes close together merge into one hunk" do
      old_content = """
      line 1
      line 2
      line 3
      line 4
      line 5
      line 6
      line 7
      line 8
      """

      new_content = """
      modified 1
      line 2
      line 3
      modified 4
      line 5
      line 6
      line 7
      line 8
      """

      result = Diff.compute(old_content, new_content, "test.txt")

      assert result.lines_removed == 2
      assert result.lines_added == 2
      # Changes at lines 1 and 4 are close (within context), should merge
      assert length(result.hunks) == 1

      hunk = hd(result.hunks)
      assert hunk.old_start == 1
      assert hunk.new_start == 1

      # Should contain both changes with context
      assert Enum.any?(hunk.lines, &(&1 == %{op: :del, old_no: 1, text: "line 1"}))
      assert Enum.any?(hunk.lines, &(&1 == %{op: :ins, new_no: 1, text: "modified 1"}))
      assert Enum.any?(hunk.lines, &(&1 == %{op: :del, old_no: 4, text: "line 4"}))
      assert Enum.any?(hunk.lines, &(&1 == %{op: :ins, new_no: 4, text: "modified 4"}))
    end

    test "no changes - identical content produces empty hunks" do
      content = """
      line 1
      line 2
      line 3
      """

      result = Diff.compute(content, content, "test.txt")

      assert result.path == "test.txt"
      assert result.lines_removed == 0
      assert result.lines_added == 0
      assert result.hunks == []
    end

    test "custom context parameter - context=1" do
      old_content = """
      line 1
      line 2
      line 3
      line 4
      line 5
      """

      new_content = """
      line 1
      line 2
      modified
      line 4
      line 5
      """

      result = Diff.compute(old_content, new_content, "test.txt", 1)

      assert result.lines_removed == 1
      assert result.lines_added == 1
      assert length(result.hunks) == 1

      hunk = hd(result.hunks)

      # With context=1, should have 1 line before and after the change
      assert [
               %{op: :eq, old_no: 2, new_no: 2, text: "line 2"},
               %{op: :del, old_no: 3, text: "line 3"},
               %{op: :ins, new_no: 3, text: "modified"},
               %{op: :eq, old_no: 4, new_no: 4, text: "line 4"}
             ] = hunk.lines
    end

    test "custom context parameter - context=0" do
      old_content = """
      line 1
      line 2
      line 3
      line 4
      line 5
      """

      new_content = """
      line 1
      line 2
      modified
      line 4
      line 5
      """

      result = Diff.compute(old_content, new_content, "test.txt", 0)

      assert result.lines_removed == 1
      assert result.lines_added == 1
      assert length(result.hunks) == 1

      hunk = hd(result.hunks)

      # With context=0, should only have the changed lines
      assert [
               %{op: :del, old_no: 3, text: "line 3"},
               %{op: :ins, new_no: 3, text: "modified"}
             ] = hunk.lines
    end

    test "line numbers - verify old_no/new_no are correct through edits" do
      old_content = """
      a
      b
      c
      d
      e
      """

      new_content = """
      a
      x
      y
      d
      e
      """

      result = Diff.compute(old_content, new_content, "test.txt")

      hunk = hd(result.hunks)

      # Line numbers should track correctly:
      # old: 1=a, 2=b, 3=c, 4=d, 5=e
      # new: 1=a, 2=x, 3=y, 4=d, 5=e
      assert Enum.find(hunk.lines, &(&1[:text] == "a")).old_no == 1
      assert Enum.find(hunk.lines, &(&1[:text] == "a")).new_no == 1

      # b is deleted from old line 2
      assert Enum.find(hunk.lines, &(&1[:text] == "b")).old_no == 2
      refute Map.has_key?(Enum.find(hunk.lines, &(&1[:text] == "b")), :new_no)

      # c is deleted from old line 3
      assert Enum.find(hunk.lines, &(&1[:text] == "c")).old_no == 3

      # x is inserted at new line 2
      assert Enum.find(hunk.lines, &(&1[:text] == "x")).new_no == 2
      refute Map.has_key?(Enum.find(hunk.lines, &(&1[:text] == "x")), :old_no)

      # y is inserted at new line 3
      assert Enum.find(hunk.lines, &(&1[:text] == "y")).new_no == 3

      # d is at old line 4, new line 4
      assert Enum.find(hunk.lines, &(&1[:text] == "d")).old_no == 4
      assert Enum.find(hunk.lines, &(&1[:text] == "d")).new_no == 4

      # e is at old line 5, new line 5
      assert Enum.find(hunk.lines, &(&1[:text] == "e")).old_no == 5
      assert Enum.find(hunk.lines, &(&1[:text] == "e")).new_no == 5
    end

    test "line numbers - insertions shift new line numbers" do
      old_content = """
      a
      b
      c
      """

      new_content = """
      a
      x
      b
      y
      c
      """

      result = Diff.compute(old_content, new_content, "test.txt")

      hunk = hd(result.hunks)

      # a: old=1, new=1
      assert Enum.find(hunk.lines, &(&1[:text] == "a" and &1[:op] == :eq)).old_no == 1
      assert Enum.find(hunk.lines, &(&1[:text] == "a" and &1[:op] == :eq)).new_no == 1

      # x: inserted at new=2
      assert Enum.find(hunk.lines, &(&1[:text] == "x")).new_no == 2

      # b: old=2, new=3 (shifted by x)
      assert Enum.find(hunk.lines, &(&1[:text] == "b")).old_no == 2
      assert Enum.find(hunk.lines, &(&1[:text] == "b")).new_no == 3

      # y: inserted at new=4
      assert Enum.find(hunk.lines, &(&1[:text] == "y")).new_no == 4

      # c: old=3, new=5 (shifted by x and y)
      assert Enum.find(hunk.lines, &(&1[:text] == "c" and &1[:op] == :eq)).old_no == 3
      assert Enum.find(hunk.lines, &(&1[:text] == "c" and &1[:op] == :eq)).new_no == 5
    end

    test "line numbers - deletions shift old line numbers" do
      old_content = """
      a
      x
      b
      y
      c
      """

      new_content = """
      a
      b
      c
      """

      result = Diff.compute(old_content, new_content, "test.txt")

      hunk = hd(result.hunks)

      # a: old=1, new=1
      assert Enum.find(hunk.lines, &(&1[:text] == "a")).old_no == 1
      assert Enum.find(hunk.lines, &(&1[:text] == "a")).new_no == 1

      # x: deleted from old=2
      assert Enum.find(hunk.lines, &(&1[:text] == "x")).old_no == 2
      refute Map.has_key?(Enum.find(hunk.lines, &(&1[:text] == "x")), :new_no)

      # b: old=3, new=2 (shifted because x was deleted)
      assert Enum.find(hunk.lines, &(&1[:text] == "b" and &1[:op] == :eq)).old_no == 3
      assert Enum.find(hunk.lines, &(&1[:text] == "b" and &1[:op] == :eq)).new_no == 2

      # y: deleted from old=4
      assert Enum.find(hunk.lines, &(&1[:text] == "y")).old_no == 4

      # c: old=5, new=3 (shifted because x and y were deleted)
      assert Enum.find(hunk.lines, &(&1[:text] == "c" and &1[:op] == :eq)).old_no == 5
      assert Enum.find(hunk.lines, &(&1[:text] == "c" and &1[:op] == :eq)).new_no == 3
    end

    test "lines added/removed counts - complex edit" do
      old_content = """
      keep1
      delete1
      delete2
      keep2
      delete3
      keep3
      """

      new_content = """
      keep1
      insert1
      keep2
      insert2
      insert3
      keep3
      """

      result = Diff.compute(old_content, new_content, "test.txt")

      assert result.lines_removed == 3
      assert result.lines_added == 3
    end

    test "lines added/removed counts - only additions" do
      old_content = """
      line 1
      line 2
      """

      new_content = """
      line 1
      inserted
      line 2
      """

      result = Diff.compute(old_content, new_content, "test.txt")

      assert result.lines_removed == 0
      assert result.lines_added == 1
    end

    test "lines added/removed counts - only deletions" do
      old_content = """
      line 1
      to delete
      line 2
      """

      new_content = """
      line 1
      line 2
      """

      result = Diff.compute(old_content, new_content, "test.txt")

      assert result.lines_removed == 1
      assert result.lines_added == 0
    end

    test "hunk start positions - multiple hunks have correct starts" do
      old_content = """
      line 1
      line 2
      line 3
      line 4
      line 5
      line 6
      line 7
      line 8
      line 9
      line 10
      line 11
      line 12
      line 13
      line 14
      line 15
      line 16
      """

      new_content = """
      changed 1
      line 2
      line 3
      line 4
      line 5
      line 6
      line 7
      line 8
      line 9
      line 10
      line 11
      line 12
      line 13
      line 14
      line 15
      changed 16
      """

      result = Diff.compute(old_content, new_content, "test.txt", 2)

      assert length(result.hunks) == 2

      [hunk1, hunk2] = result.hunks

      # First hunk starts at line 1 (the change)
      assert hunk1.old_start == 1
      assert hunk1.new_start == 1

      # Second hunk starts at context before line 16
      # With context=2, should start at line 14
      assert hunk2.old_start == 14
      assert hunk2.new_start == 14
    end

    test "empty lines are handled correctly" do
      old_content = """
      line 1

      line 3
      """

      new_content = """
      line 1

      modified 3
      """

      result = Diff.compute(old_content, new_content, "test.txt")

      assert result.lines_removed == 1
      assert result.lines_added == 1

      hunk = hd(result.hunks)

      # Empty line should be preserved
      assert Enum.any?(hunk.lines, &(&1[:text] == "" and &1[:op] == :eq))
    end

    test "trailing newline handling" do
      # String.split on "\n" creates an empty final element
      old_content = "line 1\n"
      new_content = "line 1\nline 2\n"

      result = Diff.compute(old_content, new_content, "test.txt")

      assert result.lines_added == 1
      assert result.lines_removed == 0
    end

    test "large context doesn't cause issues" do
      old_content = """
      line 1
      line 2
      line 3
      """

      new_content = """
      line 1
      modified
      line 3
      """

      # Context larger than file
      result = Diff.compute(old_content, new_content, "test.txt", 100)

      assert length(result.hunks) == 1
      hunk = hd(result.hunks)

      # Should include all lines since context is huge (heredocs produce trailing "")
      assert length(hunk.lines) == 5
    end
  end
end
