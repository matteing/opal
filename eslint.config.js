import eslint from "@eslint/js";
import tseslint from "typescript-eslint";
import reactHooks from "eslint-plugin-react-hooks";
import prettierConfig from "eslint-config-prettier";

export default tseslint.config(
  // Global ignores
  { ignores: ["**/dist/", "**/node_modules/", "packages/core/", "scripts/"] },

  // Base JS rules
  eslint.configs.recommended,

  // TypeScript rules (type-aware)
  ...tseslint.configs.recommendedTypeChecked,
  {
    languageOptions: {
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
  },

  // React Hooks rules (keep core hooks rules, disable React Compiler rules for Ink)
  {
    plugins: { "react-hooks": reactHooks },
    rules: {
      ...reactHooks.configs.recommended.rules,
      // React Compiler rules are too strict for Ink terminal apps
      "react-hooks/set-state-in-effect": "off",
      "react-hooks/refs": "off",
      "react-hooks/purity": "off",
      "react-hooks/preserve-manual-memoization": "off",
      "react-hooks/use-memo": "off",
    },
  },

  // Project-specific rule overrides
  {
    rules: {
      // Allow unused vars with _ prefix (common Elixir-adjacent convention)
      "@typescript-eslint/no-unused-vars": [
        "error",
        { argsIgnorePattern: "^_", varsIgnorePattern: "^_" },
      ],
      // Allow explicit any in SDK transport code
      "@typescript-eslint/no-explicit-any": "warn",
      // Floating promises must be handled
      "@typescript-eslint/no-floating-promises": "error",
      // Unsafe member access on any — warn, don't block (catch clauses are untyped)
      "@typescript-eslint/no-unsafe-member-access": "warn",
      "@typescript-eslint/no-unsafe-argument": "warn",
      // Non-null assertions are common in React/Ink patterns (entry! in arrays)
      "@typescript-eslint/no-non-null-assertion": "off",
      // Allow require-await to not block (some callbacks are async for interface conformance)
      "@typescript-eslint/require-await": "off",
      // Unnecessary type assertions — auto-fixable, keep as warning
      "@typescript-eslint/no-unnecessary-type-assertion": "warn",
      // Unsafe assignment and return from any — warn only
      "@typescript-eslint/no-unsafe-assignment": "warn",
      "@typescript-eslint/no-unsafe-return": "warn",
    },
  },

  // Auto-generated files get relaxed rules
  {
    files: ["**/protocol.ts"],
    rules: {
      "@typescript-eslint/no-empty-object-type": "off",
    },
  },

  // Prettier must be last to override formatting rules
  prettierConfig,
);
