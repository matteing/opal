import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import React, { type FC } from "react";
import { render } from "ink-testing-library";
import { Text } from "ink";
import { useOpal, type OpalState, type OpalActions } from "../hooks/use-opal.js";
import { createMockSession, createEventStream, type MockSession } from "./helpers/mock-session.js";
import type { SessionOptions } from "../sdk/session.js";

// Mock the Session module so we control what Session.start returns
vi.mock("../sdk/session.js", () => {
  return {
    Session: {
      start: vi.fn(),
    },
  };
});

import { Session } from "../sdk/session.js";

// A wrapper component that renders hook state as text for assertions
let capturedState: OpalState | null = null;
let capturedActions: OpalActions | null = null;

const HookWrapper: FC<{ opts?: SessionOptions }> = ({ opts = {} }) => {
  const [state, actions] = useOpal(opts);
  // eslint-disable-next-line react-hooks/globals -- test harness: capture for assertions
  capturedState = state;
  // eslint-disable-next-line react-hooks/globals -- test harness: capture for assertions
  capturedActions = actions;
  return React.createElement(
    Text,
    null,
    JSON.stringify({
      sessionReady: state.sessionReady,
      isRunning: state.main.isRunning,
      error: state.error,
      timelineLength: state.main.timeline.length,
      currentModel: state.currentModel,
      hasAuthFlow: !!state.authFlow,
      hasModelPicker: !!state.modelPicker,
      hasOpalMenu: !!state.opalMenu,
      hasConfirmation: !!state.confirmation,
      hasAskUser: !!state.askUser,
      activeTab: state.activeTab,
    }),
  );
};

function tick(ms = 20) {
  return new Promise((r) => setTimeout(r, ms));
}

describe("useOpal hook", () => {
  let mockSession: MockSession;

  beforeEach(() => {
    capturedState = null;
    capturedActions = null;
    mockSession = createMockSession();
    // eslint-disable-next-line @typescript-eslint/unbound-method
    vi.mocked(Session.start).mockResolvedValue(mockSession as never);
    // Suppress stderr writes (bell on agentEnd)
    vi.spyOn(process.stderr, "write").mockReturnValue(true);
    // Suppress stdout writes (terminal title)
    vi.spyOn(process.stdout, "write").mockReturnValue(true);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  // --- Session lifecycle ---

  describe("session lifecycle", () => {
    it("initializes with sessionReady=false", () => {
      const { unmount } = render(React.createElement(HookWrapper));
      expect(capturedState?.sessionReady).toBe(false);
      unmount();
    });

    it("sets sessionReady after Session.start resolves", async () => {
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      expect(capturedState?.sessionReady).toBe(true);
      expect(capturedState?.nodeName).toBe("opal@test");
      unmount();
    });

    it("sets error when Session.start rejects", async () => {
      // eslint-disable-next-line @typescript-eslint/unbound-method
      vi.mocked(Session.start).mockRejectedValue(new Error("Server not found"));
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      expect(capturedState?.error).toBe("Server not found");
      expect(capturedState?.sessionReady).toBe(false);
      unmount();
    });

    it("sets authFlow when auth status is setup_required", async () => {
      mockSession.auth = {
        provider: "copilot",
        providers: [{ id: "copilot", name: "GitHub Copilot", method: "device_code", ready: false }],
        status: "setup_required",
      };
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      expect(capturedState?.authFlow).toBeDefined();
      expect(capturedState?.authFlow?.providers).toHaveLength(1);
      expect(capturedState?.sessionReady).toBe(false);
      unmount();
    });

    it("calls session.close on unmount", async () => {
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      unmount();
      expect(mockSession.close).toHaveBeenCalled();
    });

    it("adds context entry to timeline when context files exist", async () => {
      mockSession.contextFiles = ["AGENTS.md"];
      mockSession.availableSkills = ["git"];
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      const ctx = capturedState?.main.timeline.find((e) => e.kind === "context");
      expect(ctx).toBeDefined();
      unmount();
    });

    it("sets currentModel from getState after ready", async () => {
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      expect(capturedState?.currentModel).toBe("gpt-4");
      unmount();
    });

    it("formats non-copilot provider as provider:id", async () => {
      mockSession.getState.mockResolvedValue({
        model: { id: "claude-sonnet-4", provider: "anthropic", thinkingLevel: "off" },
      });
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      expect(capturedState?.currentModel).toBe("anthropic:claude-sonnet-4");
      unmount();
    });
  });

  // --- Submit prompt/steer ---

  describe("submitPrompt", () => {
    it("adds user message and sets isRunning", async () => {
      mockSession.prompt.mockReturnValue(createEventStream([{ type: "agentEnd" }]));
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      capturedActions?.submitPrompt("Hello world");
      await tick();
      const msgs = capturedState?.main.timeline.filter(
        (e) => e.kind === "message" && e.message.role === "user",
      );
      expect(msgs?.length).toBeGreaterThanOrEqual(1);
      unmount();
    });

    it("calls session.prompt", async () => {
      mockSession.prompt.mockReturnValue(createEventStream([{ type: "agentEnd" }]));
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      capturedActions?.submitPrompt("Test");
      await tick();
      expect(mockSession.prompt).toHaveBeenCalledWith("Test");
      unmount();
    });
  });

  describe("submitSteer", () => {
    it("adds queued steer message to timeline", async () => {
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      capturedActions?.submitSteer("Focus on tests");
      await tick();
      const msgs = capturedState?.main.timeline.filter(
        (e) => e.kind === "message" && e.message.queued === true,
      );
      expect(msgs?.length).toBeGreaterThanOrEqual(1);
      expect(msgs?.[0]?.kind === "message" && msgs[0].message.content).toBe("Focus on tests");
      unmount();
    });
  });

  // --- Command routing ---

  describe("runCommand", () => {
    it("/help opens help overlay", async () => {
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      capturedActions?.runCommand("/help");
      await tick();
      expect(capturedState?.showHelp).toBe(true);
      unmount();
    });

    it("/model with no arg shows current model", async () => {
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      capturedActions?.runCommand("/model");
      await tick(50);
      const msgs = capturedState?.main.timeline.filter(
        (e) => e.kind === "message" && e.message.content.includes("Current model"),
      );
      expect(msgs?.length).toBeGreaterThanOrEqual(1);
      unmount();
    });

    it("/model with arg calls setModel", async () => {
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      capturedActions?.runCommand("/model claude-sonnet-4");
      await tick(50);
      expect(mockSession.setModel).toHaveBeenCalledWith("claude-sonnet-4");
      unmount();
    });

    it("/model normalizes / to :", async () => {
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      capturedActions?.runCommand("/model anthropic/claude");
      await tick(50);
      expect(mockSession.setModel).toHaveBeenCalledWith("anthropic:claude");
      unmount();
    });

    it("/models opens model picker", async () => {
      mockSession.listModels.mockResolvedValue({
        models: [{ id: "gpt-4", name: "GPT-4", provider: "copilot" }],
      });
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      capturedActions?.runCommand("/models");
      await tick(50);
      expect(capturedState?.modelPicker).toBeDefined();
      expect(capturedState?.modelPicker?.models).toHaveLength(1);
      unmount();
    });

    it("/compact calls compact and adds message", async () => {
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      capturedActions?.runCommand("/compact");
      await tick();
      expect(mockSession.compact).toHaveBeenCalled();
      const msgs = capturedState?.main.timeline.filter(
        (e) => e.kind === "message" && e.message.content.includes("Compacting"),
      );
      expect(msgs?.length).toBeGreaterThanOrEqual(1);
      unmount();
    });

    it("/agents with no sub-agents shows message", async () => {
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      capturedActions?.runCommand("/agents");
      await tick();
      const msgs = capturedState?.main.timeline.filter(
        (e) => e.kind === "message" && e.message.content.includes("No active"),
      );
      expect(msgs?.length).toBeGreaterThanOrEqual(1);
      unmount();
    });

    it("/opal opens opal menu", async () => {
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      capturedActions?.runCommand("/opal");
      await tick(50);
      expect(capturedState?.opalMenu).toBeDefined();
      unmount();
    });

    it("/unknown shows error", async () => {
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      capturedActions?.runCommand("/foobar");
      await tick();
      const msgs = capturedState?.main.timeline.filter(
        (e) => e.kind === "message" && e.message.content.includes("Unknown command"),
      );
      expect(msgs?.length).toBeGreaterThanOrEqual(1);
      unmount();
    });
  });

  // --- UI interactions ---

  describe("UI interactions", () => {
    it("selectModel calls setModel and clears picker", async () => {
      mockSession.setModel.mockResolvedValue({
        model: { id: "claude-sonnet-4", provider: "copilot", thinkingLevel: "off" },
      });
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      capturedActions?.selectModel("claude-sonnet-4");
      await tick(50);
      expect(mockSession.setModel).toHaveBeenCalledWith("claude-sonnet-4", undefined);
      expect(capturedState?.modelPicker).toBeNull();
      unmount();
    });

    it("selectModel with thinkingLevel", async () => {
      mockSession.setModel.mockResolvedValue({
        model: { id: "claude-sonnet-4", provider: "copilot", thinkingLevel: "high" },
      });
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      capturedActions?.selectModel("claude-sonnet-4", "high");
      await tick(50);
      expect(mockSession.setModel).toHaveBeenCalledWith("claude-sonnet-4", "high");
      unmount();
    });

    it("dismissModelPicker clears picker", async () => {
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      capturedActions?.dismissModelPicker();
      await tick();
      expect(capturedState?.modelPicker).toBeNull();
      unmount();
    });

    it("dismissOpalMenu clears menu", async () => {
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      capturedActions?.dismissOpalMenu();
      await tick();
      expect(capturedState?.opalMenu).toBeNull();
      unmount();
    });

    it("showHelpMenu sets showHelp", async () => {
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      capturedActions?.showHelpMenu();
      await tick();
      expect(capturedState?.showHelp).toBe(true);
      unmount();
    });

    it("dismissHelpMenu clears showHelp", async () => {
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      capturedActions?.showHelpMenu();
      await tick();
      expect(capturedState?.showHelp).toBe(true);
      capturedActions?.dismissHelpMenu();
      await tick();
      expect(capturedState?.showHelp).toBe(false);
      unmount();
    });
    it("switchTab changes activeTab", async () => {
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      capturedActions?.switchTab("sub-1");
      await tick();
      expect(capturedState?.activeTab).toBe("sub-1");
      unmount();
    });

    it("abort calls session.abort", async () => {
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      capturedActions?.abort();
      await tick();
      expect(mockSession.abort).toHaveBeenCalled();
      unmount();
    });

    it("toggleOpalFeature does optimistic update", async () => {
      // Make setOpalConfig return the toggled state
      mockSession.setOpalConfig.mockResolvedValue({
        features: { subAgents: true, skills: true, mcp: true, debug: true },
        tools: { all: ["read_file", "shell"], enabled: ["read_file", "shell"], disabled: [] },
      });
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      capturedActions?.runCommand("/opal");
      await tick(100);
      expect(capturedState?.opalMenu).toBeDefined();
      capturedActions?.toggleOpalFeature("debug", true);
      await tick(100);
      expect(capturedState?.opalMenu?.features.debug).toBe(true);
      unmount();
    });

    it("toggleOpalTool does optimistic update", async () => {
      // Make setOpalConfig return with shell disabled
      mockSession.setOpalConfig.mockResolvedValue({
        features: { subAgents: true, skills: true, mcp: true, debug: false },
        tools: { all: ["read_file", "shell"], enabled: ["read_file"], disabled: ["shell"] },
      });
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      capturedActions?.runCommand("/opal");
      await tick(100);
      capturedActions?.toggleOpalTool("shell", false);
      await tick(100);
      expect(capturedState?.opalMenu?.tools.enabled).not.toContain("shell");
      expect(capturedState?.opalMenu?.tools.disabled).toContain("shell");
      unmount();
    });
  });

  // --- Auth flows ---

  describe("auth flows", () => {
    it("authStartDeviceFlow calls authLogin and sets deviceCode", async () => {
      // Make authPoll block indefinitely so we can inspect the intermediate state
      mockSession.authPoll.mockReturnValue(new Promise(() => {}));
      mockSession.auth = {
        provider: "copilot",
        providers: [{ id: "copilot", name: "GitHub Copilot", method: "device_code", ready: false }],
        status: "setup_required",
      };
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      expect(capturedState?.authFlow).toBeDefined();
      capturedActions?.authStartDeviceFlow();
      await tick(100);
      expect(mockSession.authLogin).toHaveBeenCalled();
      expect(capturedState?.authFlow?.deviceCode?.userCode).toBe("ABCD-1234");
      unmount();
    });

    it("authSubmitKey with empty key shows input screen", async () => {
      mockSession.auth = {
        provider: "copilot",
        providers: [{ id: "openai", name: "OpenAI", method: "api_key", ready: false }],
        status: "setup_required",
      };
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      capturedActions?.authSubmitKey("openai", "");
      await tick();
      expect(capturedState?.authFlow?.apiKeyInput?.providerId).toBe("openai");
      unmount();
    });

    it("authSubmitKey with key calls authSetKey and transitions to ready", async () => {
      mockSession.auth = {
        provider: "copilot",
        providers: [{ id: "openai", name: "OpenAI", method: "api_key", ready: false }],
        status: "setup_required",
      };
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      capturedActions?.authSubmitKey("openai", "sk-test-123");
      await tick(50);
      expect(mockSession.authSetKey).toHaveBeenCalledWith("openai", "sk-test-123");
      expect(capturedState?.sessionReady).toBe(true);
      unmount();
    });

    it("authSubmitKey failure sets error", async () => {
      mockSession.auth = {
        provider: "copilot",
        providers: [{ id: "openai", name: "OpenAI", method: "api_key", ready: false }],
        status: "setup_required",
      };
      mockSession.authSetKey.mockRejectedValue(new Error("Invalid key"));
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      capturedActions?.authSubmitKey("openai", "bad-key");
      await tick(50);
      expect(capturedState?.error).toBe("Invalid key");
      unmount();
    });
  });

  // --- Event processing ---

  describe("event processing", () => {
    it("processes events from prompt stream", async () => {
      mockSession.prompt.mockReturnValue(
        createEventStream([
          { type: "agentStart" },
          { type: "messageStart" },
          { type: "messageDelta", delta: "Hello" },
          { type: "agentEnd" },
        ]),
      );
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      capturedActions?.submitPrompt("test");
      await tick(100);
      // Should have user message + assistant message
      const msgs = capturedState?.main.timeline.filter((e) => e.kind === "message") ?? [];
      expect(msgs.length).toBeGreaterThanOrEqual(2);
      expect(capturedState?.main.isRunning).toBe(false);
      unmount();
    });
  });

  // --- Confirmation/AskUser ---

  describe("resolveConfirmation", () => {
    it("clears confirmation state", async () => {
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      capturedActions?.resolveConfirmation("allow");
      await tick();
      expect(capturedState?.confirmation).toBeNull();
      unmount();
    });
  });

  describe("resolveAskUser", () => {
    it("clears askUser state", async () => {
      const { unmount } = render(React.createElement(HookWrapper));
      await tick(50);
      capturedActions?.resolveAskUser("my answer");
      await tick();
      expect(capturedState?.askUser).toBeNull();
      unmount();
    });
  });
});
