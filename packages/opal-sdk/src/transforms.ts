/**
 * Deep recursive key transforms between snake_case and camelCase.
 *
 * Applied at the transport boundary so all SDK code operates in camelCase
 * while the Elixir server communicates in snake_case.
 */

/** Recursively convert all object keys from snake_case to camelCase. */
export function snakeToCamel(obj: unknown): unknown {
  if (Array.isArray(obj)) return obj.map(snakeToCamel);
  if (obj !== null && typeof obj === "object") {
    const out: Record<string, unknown> = {};
    for (const [key, val] of Object.entries(obj)) {
      out[snakeToCamelKey(key)] = snakeToCamel(val);
    }
    return out;
  }
  return obj;
}

/** Recursively convert all object keys from camelCase to snake_case. */
export function camelToSnake(obj: unknown): unknown {
  if (Array.isArray(obj)) return obj.map(camelToSnake);
  if (obj !== null && typeof obj === "object") {
    const out: Record<string, unknown> = {};
    for (const [key, val] of Object.entries(obj)) {
      out[camelToSnakeKey(key)] = camelToSnake(val);
    }
    return out;
  }
  return obj;
}

function snakeToCamelKey(key: string): string {
  return key.replace(/_([a-z])/g, (_, c: string) => c.toUpperCase());
}

function camelToSnakeKey(key: string): string {
  return key.replace(/[A-Z]/g, (c) => `_${c.toLowerCase()}`);
}
