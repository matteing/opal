import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    globals: true,
    environment: "node",
    include: ["src/**/*.test.{ts,tsx}"],
    coverage: {
      provider: "v8",
      include: ["src/sdk/**/*.ts", "src/lib/**/*.ts", "src/hooks/**/*.ts", "src/open-*.ts"],
      exclude: ["src/**/*.test.{ts,tsx}", "src/sdk/protocol.ts"],
    },
  },
});
