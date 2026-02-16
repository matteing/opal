import { describe, it, expect } from "vitest";
import {
  errorMessage,
  parseCommand,
  buildDisplaySpec,
  normalizeModelSpec,
  buildHelpMessage,
  buildAgentListMessage,
} from "../lib/commands.js";
import type { SubAgent } from "../lib/reducers.js";

describe("errorMessage", () => {
  it("extracts message from Error", () => {
    expect(errorMessage(new Error("boom"))).toBe("boom");
  });
  it("stringifies non-Error values", () => {
    expect(errorMessage("string error")).toBe("string error");
    expect(errorMessage(42)).toBe("42");
    expect(errorMessage(null)).toBe("null");
  });
});

describe("parseCommand", () => {
  it("parses simple command", () => {
    expect(parseCommand("/help")).toEqual({ cmd: "help", arg: "" });
  });
  it("parses command with argument", () => {
    expect(parseCommand("/model foo/bar")).toEqual({ cmd: "model", arg: "foo/bar" });
  });
  it("lowercases command name", () => {
    expect(parseCommand("/MODELS")).toEqual({ cmd: "models", arg: "" });
  });
  it("handles multi-word argument", () => {
    expect(parseCommand("/agents main")).toEqual({ cmd: "agents", arg: "main" });
  });
  it("trims whitespace", () => {
    expect(parseCommand("  /compact   ")).toEqual({ cmd: "compact", arg: "" });
  });
  it("handles numeric argument", () => {
    expect(parseCommand("/agents 2")).toEqual({ cmd: "agents", arg: "2" });
  });
});

describe("buildDisplaySpec", () => {
  it("returns just id for copilot provider", () => {
    expect(buildDisplaySpec({ provider: "copilot", id: "gpt-4" })).toBe("gpt-4");
  });
  it("returns provider:id for non-copilot", () => {
    expect(buildDisplaySpec({ provider: "anthropic", id: "claude" })).toBe("anthropic:claude");
  });
});

describe("normalizeModelSpec", () => {
  it("converts / to :", () => {
    expect(normalizeModelSpec("anthropic/claude")).toBe("anthropic:claude");
  });
  it("leaves : unchanged", () => {
    expect(normalizeModelSpec("anthropic:claude")).toBe("anthropic:claude");
  });
  it("leaves plain id unchanged", () => {
    expect(normalizeModelSpec("gpt-4")).toBe("gpt-4");
  });
});

describe("buildHelpMessage", () => {
  it("contains all command names", () => {
    const msg = buildHelpMessage();
    expect(msg).toContain("/model");
    expect(msg).toContain("/models");
    expect(msg).toContain("/agents");
    expect(msg).toContain("/opal");
    expect(msg).toContain("/compact");
    expect(msg).toContain("/help");
  });
});

describe("buildAgentListMessage", () => {
  const makeSub = (overrides: Partial<SubAgent> = {}): SubAgent => ({
    sessionId: "sub-1234-5678",
    parentCallId: "call-1",
    label: "Test Agent",
    model: "gpt-4",
    tools: ["read_file"],
    startedAt: Date.now(),
    toolCount: 3,
    timeline: [],
    thinking: null,
    statusMessage: null,
    isRunning: true,
    ...overrides,
  });

  it("returns null when no sub-agents", () => {
    expect(buildAgentListMessage([], "main")).toBeNull();
  });

  it("formats agent list", () => {
    const msg = buildAgentListMessage([makeSub()], "main");
    expect(msg).toContain("Test Agent");
    expect(msg).toContain("gpt-4");
    expect(msg).toContain("3 tools");
    expect(msg).toContain("running");
  });

  it("shows done status", () => {
    const msg = buildAgentListMessage([makeSub({ isRunning: false })], "main");
    expect(msg).toContain("done");
  });

  it("shows currently viewing when activeTab matches sub-agent", () => {
    const sub = makeSub();
    const msg = buildAgentListMessage([sub], sub.sessionId);
    expect(msg).toContain("Currently viewing");
    expect(msg).toContain("Test Agent");
  });

  it("does not show currently viewing when on main tab", () => {
    const msg = buildAgentListMessage([makeSub()], "main");
    expect(msg).not.toContain("Currently viewing");
  });

  it("uses sessionId prefix when label is empty", () => {
    const msg = buildAgentListMessage([makeSub({ label: "" })], "main");
    expect(msg).toContain("sub-1234");
  });
});
