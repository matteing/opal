import { describe, it, expect } from "vitest";
import { snakeToCamel, camelToSnake } from "../sdk/transforms.js";

/** Traverse nested objects by key path, e.g. `dig(obj, "a", "b", "c")`. */
function dig(obj: unknown, ...keys: string[]): unknown {
  let current = obj;
  for (const key of keys) {
    current = (current as Record<string, unknown>)[key];
  }
  return current;
}

describe("transforms — edge cases", () => {
  describe("snakeToCamel edge cases", () => {
    it("handles deeply nested objects (5+ levels)", () => {
      const input = {
        level_one: {
          level_two: {
            level_three: {
              level_four: {
                level_five: { deep_key: "value" },
              },
            },
          },
        },
      };
      const result = snakeToCamel(input);
      expect(
        dig(result, "levelOne", "levelTwo", "levelThree", "levelFour", "levelFive", "deepKey"),
      ).toBe("value");
    });

    it("handles arrays with mixed types", () => {
      const input = [{ some_key: 1 }, "plain", 42, null, { other_key: true }];
      const result = snakeToCamel(input) as unknown[];
      expect(result[0]).toEqual({ someKey: 1 });
      expect(result[1]).toBe("plain");
      expect(result[2]).toBe(42);
      expect(result[3]).toBeNull();
      expect(result[4]).toEqual({ otherKey: true });
    });

    it("handles keys with leading underscore", () => {
      const result = snakeToCamel({ _private_key: "val" }) as Record<string, unknown>;
      const keys = Object.keys(result);
      expect(keys).toHaveLength(1);
      expect(result[keys[0]]).toBe("val");
    });

    it("handles keys with trailing underscore", () => {
      const result = snakeToCamel({ key_: "val" }) as Record<string, unknown>;
      const keys = Object.keys(result);
      expect(keys).toHaveLength(1);
      expect(result[keys[0]]).toBe("val");
    });

    it("leaves already-camelCase keys unchanged", () => {
      expect(dig(snakeToCamel({ someKey: "val" }), "someKey")).toBe("val");
    });

    it("handles empty string key", () => {
      expect(dig(snakeToCamel({ "": "val" }), "")).toBe("val");
    });

    it("handles 1 000 keys without stack overflow", () => {
      const input = Object.fromEntries(Array.from({ length: 1000 }, (_, i) => [`key_${i}`, i]));
      const result = snakeToCamel(input) as Record<string, number>;
      expect(Object.keys(result)).toHaveLength(1000);
    });
  });

  describe("camelToSnake edge cases", () => {
    it("handles deeply nested objects", () => {
      const input = { levelOne: { levelTwo: { deepKey: "value" } } };
      expect(dig(camelToSnake(input), "level_one", "level_two", "deep_key")).toBe("value");
    });

    it("leaves already-snake_case keys unchanged", () => {
      expect(dig(camelToSnake({ some_key: "val" }), "some_key")).toBe("val");
    });

    it("handles arrays with mixed types", () => {
      const result = camelToSnake([{ someKey: 1 }, "plain", null]) as unknown[];
      expect(result[0]).toEqual({ some_key: 1 });
      expect(result[1]).toBe("plain");
      expect(result[2]).toBeNull();
    });

    it("roundtrip preserves data", () => {
      const original = {
        session_id: "abc",
        context_files: ["a.md"],
        nested: { deep_val: 42 },
      };
      expect(camelToSnake(snakeToCamel(original))).toEqual(original);
    });

    it("handles 1 000 keys without stack overflow", () => {
      const input = Object.fromEntries(Array.from({ length: 1000 }, (_, i) => [`key${i}`, i]));
      const result = camelToSnake(input) as Record<string, number>;
      expect(Object.keys(result)).toHaveLength(1000);
    });
  });
});
