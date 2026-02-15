import { describe, it, expect } from "vitest";
import { snakeToCamel, camelToSnake } from "../sdk/transforms.js";

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
      const result = snakeToCamel(input) as Record<string, unknown>;
      const l1 = result.levelOne as Record<string, unknown>;
      const l2 = l1.levelTwo as Record<string, unknown>;
      const l3 = l2.levelThree as Record<string, unknown>;
      const l4 = l3.levelFour as Record<string, unknown>;
      const l5 = l4.levelFive as Record<string, unknown>;
      expect(l5.deepKey).toBe("value");
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
      // Leading underscore should be handled (implementation-dependent)
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
      const result = snakeToCamel({ someKey: "val" }) as Record<string, unknown>;
      expect(result.someKey).toBe("val");
    });

    it("handles empty string key", () => {
      const result = snakeToCamel({ "": "val" }) as Record<string, unknown>;
      expect(result[""]).toBe("val");
    });

    it("handles large objects without stack overflow", () => {
      const input: Record<string, number> = {};
      for (let i = 0; i < 1000; i++) {
        input[`key_${i}`] = i;
      }
      const result = snakeToCamel(input) as Record<string, number>;
      expect(Object.keys(result)).toHaveLength(1000);
    });
  });

  describe("camelToSnake edge cases", () => {
    it("handles deeply nested objects", () => {
      const input = { levelOne: { levelTwo: { deepKey: "value" } } };
      const result = camelToSnake(input) as Record<string, unknown>;
      const l1 = result.level_one as Record<string, unknown>;
      const l2 = l1.level_two as Record<string, unknown>;
      expect(l2.deep_key).toBe("value");
    });

    it("leaves already-snake_case keys unchanged", () => {
      const result = camelToSnake({ some_key: "val" }) as Record<string, unknown>;
      expect(result.some_key).toBe("val");
    });

    it("handles arrays with mixed types", () => {
      const input = [{ someKey: 1 }, "plain", null];
      const result = camelToSnake(input) as unknown[];
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
      const roundtripped = camelToSnake(snakeToCamel(original));
      expect(roundtripped).toEqual(original);
    });

    it("handles large objects without stack overflow", () => {
      const input: Record<string, number> = {};
      for (let i = 0; i < 1000; i++) {
        input[`key${i}`] = i;
      }
      const result = camelToSnake(input) as Record<string, number>;
      expect(Object.keys(result)).toHaveLength(1000);
    });
  });
});
