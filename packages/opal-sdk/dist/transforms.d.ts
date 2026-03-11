/**
 * Deep recursive key transforms between snake_case and camelCase.
 *
 * Applied at the transport boundary so all SDK code operates in camelCase
 * while the Elixir server communicates in snake_case.
 */
/** Recursively convert all object keys from snake_case to camelCase. */
export declare function snakeToCamel(obj: unknown): unknown;
/** Recursively convert all object keys from camelCase to snake_case. */
export declare function camelToSnake(obj: unknown): unknown;
//# sourceMappingURL=transforms.d.ts.map