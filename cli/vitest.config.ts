import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    globals: true,
    environment: "node",
    include: ["src/**/*.test.ts"],
    coverage: {
      provider: "v8",
      include: ["src/sdk/**/*.ts", "src/lib/**/*.ts"],
      exclude: ["src/**/*.test.ts", "src/sdk/protocol.ts"],
    },
  },
});
