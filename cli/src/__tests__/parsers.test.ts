import { describe, it, expect } from "vitest";
import {
  outputToText,
  parseStructuredTasksOutput,
  parseTasksOutput,
  parseTaskNotes,
} from "../lib/parsers.js";

describe("outputToText", () => {
  it("returns string as-is", () => {
    expect(outputToText("hello")).toBe("hello");
  });

  it("returns empty string for null/undefined", () => {
    expect(outputToText(null)).toBe("");
    expect(outputToText(undefined)).toBe("");
  });

  it("converts number to string", () => {
    expect(outputToText(42)).toBe("42");
  });

  it("converts boolean to string", () => {
    expect(outputToText(true)).toBe("true");
  });

  it("JSON-stringifies objects", () => {
    const result = outputToText({ key: "value" });
    expect(JSON.parse(result)).toEqual({ key: "value" });
  });

  it("handles circular references gracefully", () => {
    const obj: Record<string, unknown> = {};
    obj.self = obj;
    expect(outputToText(obj)).toBe("[non-serializable output]");
  });
});

describe("parseStructuredTasksOutput", () => {
  it("parses a valid tasks payload", () => {
    const payload = {
      kind: "tasks",
      action: "list",
      total: 2,
      tasks: [
        { id: 1, label: "Task one", status: "done", priority: "high", groupName: "default" },
        { id: "2", label: "Task two", status: "open", priority: "low", groupName: "work" },
      ],
      notes: ["A note"],
      counts: { open: 1, inProgress: 0, done: 1, blocked: 0 },
    };
    const result = parseStructuredTasksOutput(payload);
    expect(result).not.toBeNull();
    expect(result!.tasks).toHaveLength(2);
    expect(result!.tasks[0]).toEqual({
      id: "1",
      label: "Task one",
      status: "done",
      priority: "high",
      group: "default",
    });
    expect(result!.notes).toEqual(["A note"]);
    expect(result!.summary).toContain("list: 2 total");
    expect(result!.summary).toContain("1 open");
    expect(result!.summary).toContain("1 done");
  });

  it("returns null for non-object input", () => {
    expect(parseStructuredTasksOutput("string")).toBeNull();
    expect(parseStructuredTasksOutput(null)).toBeNull();
    expect(parseStructuredTasksOutput(123)).toBeNull();
    expect(parseStructuredTasksOutput([1, 2])).toBeNull();
  });

  it("returns null when kind is not 'tasks'", () => {
    expect(parseStructuredTasksOutput({ kind: "other", tasks: [] })).toBeNull();
  });

  it("returns null when tasks is not an array", () => {
    expect(parseStructuredTasksOutput({ kind: "tasks", tasks: "not array" })).toBeNull();
  });

  it("appends error notes from failed operations", () => {
    const payload = {
      kind: "tasks",
      tasks: [{ id: 1, label: "X", status: "open" }],
      operations: [{ ok: false, action: "delete", error: "not found" }],
    };
    const result = parseStructuredTasksOutput(payload);
    expect(result!.notes).toContain("delete: not found");
  });

  it("defaults status from done flag", () => {
    const payload = {
      kind: "tasks",
      tasks: [{ id: 1, label: "Y", done: true }],
    };
    const result = parseStructuredTasksOutput(payload);
    expect(result!.tasks[0].status).toBe("done");
  });

  it("skips non-object entries in tasks array", () => {
    const payload = {
      kind: "tasks",
      tasks: [null, "invalid", { id: 1, label: "Valid" }],
    };
    const result = parseStructuredTasksOutput(payload);
    expect(result!.tasks).toHaveLength(1);
    expect(result!.tasks[0].label).toBe("Valid");
  });
});

describe("parseTasksOutput", () => {
  it("parses a valid plain-text task table", () => {
    const table = [
      "id | label | status | priority | group",
      "---|-------|--------|----------|------",
      "1 | Do thing | done | high | default",
      "2 | Other thing | open | low | work",
      "2 task(s)",
    ].join("\n");
    const result = parseTasksOutput(table);
    expect(result).toHaveLength(2);
    expect(result![0]).toEqual({
      id: "1",
      label: "Do thing",
      status: "done",
      priority: "high",
      group: "default",
    });
  });

  it("returns null when no header found", () => {
    expect(parseTasksOutput("no table here")).toBeNull();
  });

  it("returns null when header exists but no data rows", () => {
    const table = [
      "id | label | status | priority | group",
      "---|-------|--------|----------|------",
    ].join("\n");
    expect(parseTasksOutput(table)).toBeNull();
  });

  it("stops at task count line", () => {
    const table = [
      "id | label | status | priority | group",
      "---|-------|--------|----------|------",
      "1 | A | done | high | g",
      "1 task(s)",
      "extra | data | here | x | y",
    ].join("\n");
    const result = parseTasksOutput(table);
    expect(result).toHaveLength(1);
  });

  it("handles CRLF line endings", () => {
    const table =
      "id | label | status | priority | group\r\n" +
      "---|-------|--------|----------|------\r\n" +
      "1 | Test | open | low | g\r\n";
    const result = parseTasksOutput(table);
    expect(result).toHaveLength(1);
  });
});

describe("parseTaskNotes", () => {
  it("filters lines starting with [+], [-], [~]", () => {
    const text = "[+] Added task\n[-] Removed task\n[~] Updated task\nRegular line";
    const result = parseTaskNotes(text);
    expect(result).toEqual(["[+] Added task", "[-] Removed task", "[~] Updated task"]);
  });

  it("returns empty array when no matching lines", () => {
    expect(parseTaskNotes("no notes here\njust text")).toEqual([]);
  });

  it("handles empty string", () => {
    expect(parseTaskNotes("")).toEqual([]);
  });
});
