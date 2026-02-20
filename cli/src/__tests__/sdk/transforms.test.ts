import { describe, expect, it } from "vitest";
import { snakeToCamel, camelToSnake } from "../../sdk/transforms.js";

describe("snakeToCamel", () => {
  it("converts simple keys", () => {
    expect(snakeToCamel({ foo_bar: 1 })).toEqual({ fooBar: 1 });
  });

  it("converts nested objects", () => {
    expect(snakeToCamel({ outer_key: { inner_key: "v" } })).toEqual({
      outerKey: { innerKey: "v" },
    });
  });

  it("converts arrays of objects", () => {
    expect(snakeToCamel([{ a_b: 1 }, { c_d: 2 }])).toEqual([{ aB: 1 }, { cD: 2 }]);
  });

  it("passes primitives through", () => {
    expect(snakeToCamel("hello")).toBe("hello");
    expect(snakeToCamel(42)).toBe(42);
    expect(snakeToCamel(null)).toBeNull();
    expect(snakeToCamel(undefined)).toBeUndefined();
    expect(snakeToCamel(true)).toBe(true);
  });

  it("handles empty object and array", () => {
    expect(snakeToCamel({})).toEqual({});
    expect(snakeToCamel([])).toEqual([]);
  });

  it("handles multiple underscores", () => {
    expect(snakeToCamel({ a_b_c: 1 })).toEqual({ aBC: 1 });
  });
});

describe("camelToSnake", () => {
  it("converts simple keys", () => {
    expect(camelToSnake({ fooBar: 1 })).toEqual({ foo_bar: 1 });
  });

  it("converts nested objects", () => {
    expect(camelToSnake({ outerKey: { innerKey: "v" } })).toEqual({
      outer_key: { inner_key: "v" },
    });
  });

  it("passes primitives through", () => {
    expect(camelToSnake(null)).toBeNull();
    expect(camelToSnake(99)).toBe(99);
  });
});

describe("roundtrip", () => {
  it("snake → camel → snake preserves original", () => {
    const original = { my_key: { nested_val: [{ arr_item: 1 }] } };
    expect(camelToSnake(snakeToCamel(original))).toEqual(original);
  });

  it("camel → snake → camel preserves original", () => {
    const original = { myKey: { nestedVal: [{ arrItem: 1 }] } };
    expect(snakeToCamel(camelToSnake(original))).toEqual(original);
  });
});
