import { describe, it, expect } from "vitest";
import { toggleFeature, toggleTool, type OpalRuntimeConfig } from "../lib/opal-menu.js";

function makeConfig(overrides: Partial<OpalRuntimeConfig> = {}): OpalRuntimeConfig {
  return {
    features: { subAgents: true, skills: true, mcp: true, debug: false },
    tools: {
      all: ["read_file", "write_file", "shell", "edit_file"],
      enabled: ["read_file", "write_file", "shell"],
      disabled: ["edit_file"],
    },
    ...overrides,
  };
}

describe("toggleFeature", () => {
  it("enables a feature", () => {
    const cfg = makeConfig();
    const result = toggleFeature(cfg, "debug", true);
    expect(result.features.debug).toBe(true);
    expect(result.features.mcp).toBe(true); // others unchanged
  });

  it("disables a feature", () => {
    const cfg = makeConfig();
    const result = toggleFeature(cfg, "skills", false);
    expect(result.features.skills).toBe(false);
    expect(result.features.subAgents).toBe(true); // others unchanged
  });

  it("does not mutate original config", () => {
    const cfg = makeConfig();
    toggleFeature(cfg, "debug", true);
    expect(cfg.features.debug).toBe(false);
  });
});

describe("toggleTool", () => {
  it("enables a disabled tool", () => {
    const cfg = makeConfig();
    const result = toggleTool(cfg, "edit_file", true);
    expect(result.tools.enabled).toContain("edit_file");
    expect(result.tools.disabled).not.toContain("edit_file");
  });

  it("disables an enabled tool", () => {
    const cfg = makeConfig();
    const result = toggleTool(cfg, "shell", false);
    expect(result.tools.enabled).not.toContain("shell");
    expect(result.tools.disabled).toContain("shell");
  });

  it("preserves order from all array", () => {
    const cfg = makeConfig();
    const result = toggleTool(cfg, "edit_file", true);
    // Order should match `all`: read_file, write_file, shell, edit_file
    expect(result.tools.enabled).toEqual(["read_file", "write_file", "shell", "edit_file"]);
  });

  it("does not mutate original config", () => {
    const cfg = makeConfig();
    toggleTool(cfg, "edit_file", true);
    expect(cfg.tools.enabled).not.toContain("edit_file");
  });

  it("enabling already-enabled tool is idempotent", () => {
    const cfg = makeConfig();
    const result = toggleTool(cfg, "read_file", true);
    expect(result.tools.enabled.filter((t) => t === "read_file")).toHaveLength(1);
  });
});
