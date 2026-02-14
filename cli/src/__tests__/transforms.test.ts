import { describe, it, expect } from "vitest";
import { snakeToCamel, camelToSnake } from "../sdk/transforms.js";

describe("snakeToCamel", () => {
  it("converts simple snake_case keys", () => {
    expect(snakeToCamel({ foo_bar: 1 })).toEqual({ fooBar: 1 });
  });

  it("converts nested objects recursively", () => {
    const input = { outer_key: { inner_key: "value" } };
    expect(snakeToCamel(input)).toEqual({ outerKey: { innerKey: "value" } });
  });

  it("converts arrays of objects", () => {
    const input = [{ foo_bar: 1 }, { baz_qux: 2 }];
    expect(snakeToCamel(input)).toEqual([{ fooBar: 1 }, { bazQux: 2 }]);
  });

  it("passes primitives through unchanged", () => {
    expect(snakeToCamel("hello")).toBe("hello");
    expect(snakeToCamel(42)).toBe(42);
    expect(snakeToCamel(null)).toBe(null);
    expect(snakeToCamel(true)).toBe(true);
    expect(snakeToCamel(undefined)).toBe(undefined);
  });

  it("handles empty object and array", () => {
    expect(snakeToCamel({})).toEqual({});
    expect(snakeToCamel([])).toEqual([]);
  });

  it("handles multiple underscores", () => {
    expect(snakeToCamel({ a_b_c: 1 })).toEqual({ aBC: 1 });
  });

  it("handles keys with no underscores", () => {
    expect(snakeToCamel({ already: 1 })).toEqual({ already: 1 });
  });

  it("handles deeply nested mixed structures", () => {
    const input = {
      top_level: [{ nested_key: { deep_value: true } }],
    };
    expect(snakeToCamel(input)).toEqual({
      topLevel: [{ nestedKey: { deepValue: true } }],
    });
  });
});

describe("camelToSnake", () => {
  it("converts simple camelCase keys", () => {
    expect(camelToSnake({ fooBar: 1 })).toEqual({ foo_bar: 1 });
  });

  it("converts nested objects recursively", () => {
    const input = { outerKey: { innerKey: "value" } };
    expect(camelToSnake(input)).toEqual({ outer_key: { inner_key: "value" } });
  });

  it("converts arrays of objects", () => {
    const input = [{ fooBar: 1 }, { bazQux: 2 }];
    expect(camelToSnake(input)).toEqual([{ foo_bar: 1 }, { baz_qux: 2 }]);
  });

  it("passes primitives through unchanged", () => {
    expect(camelToSnake("hello")).toBe("hello");
    expect(camelToSnake(42)).toBe(42);
    expect(camelToSnake(null)).toBe(null);
  });

  it("handles keys that are already snake_case", () => {
    expect(camelToSnake({ already_snake: 1 })).toEqual({ already_snake: 1 });
  });
});

describe("roundtrip", () => {
  it("snake → camel → snake preserves original", () => {
    const original = {
      session_id: "abc",
      context_files: ["a.md"],
      auth: { provider: "copilot", device_code: "123" },
    };
    expect(camelToSnake(snakeToCamel(original))).toEqual(original);
  });

  it("camel → snake → camel preserves original", () => {
    const original = {
      sessionId: "abc",
      contextFiles: ["a.md"],
      auth: { provider: "copilot", deviceCode: "123" },
    };
    expect(snakeToCamel(camelToSnake(original))).toEqual(original);
  });
});
