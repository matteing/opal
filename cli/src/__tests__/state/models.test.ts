import { describe, it, expect, beforeEach, vi } from "vitest";
import { createStore } from "zustand/vanilla";
import { createModelsSlice, type ModelsSlice } from "../../state/models.js";
import type { Session } from "../../sdk/session.js";

function makeStore() {
  return createStore<ModelsSlice>()(createModelsSlice);
}

/** Create a mock session with the methods the slice calls. */
function mockSession(
  overrides: {
    models?: () => Promise<{ models: Record<string, unknown>[] }>;
    state?: () => Promise<{ model: { id: string; provider: string; thinkingLevel: string } }>;
    setModel?: (
      spec: unknown,
    ) => Promise<{ model: { id: string; provider: string; thinkingLevel: string } }>;
  } = {},
): Session {
  return {
    models:
      overrides.models ??
      vi.fn().mockResolvedValue({
        models: [
          {
            id: "gpt-4",
            name: "GPT-4",
            provider: "copilot",
            supportsThinking: false,
            thinkingLevels: [],
          },
          {
            id: "claude-sonnet",
            name: "Claude Sonnet",
            provider: "anthropic",
            supportsThinking: true,
            thinkingLevels: ["low", "high"],
          },
        ],
      }),
    state:
      overrides.state ??
      vi.fn().mockResolvedValue({
        model: { id: "gpt-4", provider: "copilot", thinkingLevel: "off" },
      }),
    setModel:
      overrides.setModel ??
      vi.fn().mockResolvedValue({
        model: { id: "claude-sonnet", provider: "anthropic", thinkingLevel: "high" },
      }),
  } as unknown as Session;
}

describe("ModelsSlice", () => {
  let store: ReturnType<typeof makeStore>;

  beforeEach(() => {
    store = makeStore();
  });

  it("starts with empty state", () => {
    const s = store.getState();
    expect(s.availableModels).toEqual([]);
    expect(s.currentModel).toBeNull();
    expect(s.modelsLoading).toBe(false);
    expect(s.modelsError).toBeNull();
  });

  describe("fetchModels", () => {
    it("fetches and populates available models and current model", async () => {
      const session = mockSession();
      await store.getState().fetchModels(session);

      const s = store.getState();
      expect(s.availableModels).toHaveLength(2);
      expect(s.availableModels[0].id).toBe("gpt-4");
      expect(s.availableModels[1].provider).toBe("anthropic");
      expect(s.currentModel).toEqual({
        id: "gpt-4",
        provider: "copilot",
        thinkingLevel: "off",
        displayName: "gpt-4",
      });
      expect(s.modelsLoading).toBe(false);
    });

    it("sets modelsLoading during fetch", async () => {
      let resolve!: () => void;
      const session = mockSession({
        models: () =>
          new Promise((r) => {
            resolve = () => r({ models: [] });
          }),
        state: () =>
          Promise.resolve({ model: { id: "x", provider: "copilot", thinkingLevel: "off" } }),
      });

      const promise = store.getState().fetchModels(session);
      expect(store.getState().modelsLoading).toBe(true);

      resolve();
      await promise;
      expect(store.getState().modelsLoading).toBe(false);
    });

    it("handles fetch errors", async () => {
      const session = mockSession({
        models: () => Promise.reject(new Error("network error")),
      });

      await store.getState().fetchModels(session);
      expect(store.getState().modelsError).toBe("network error");
      expect(store.getState().modelsLoading).toBe(false);
    });
  });

  describe("selectModel", () => {
    it("updates current model on success", async () => {
      const session = mockSession();
      await store.getState().selectModel(session, "claude-sonnet", "high");

      const s = store.getState();
      expect(s.currentModel).toEqual({
        id: "claude-sonnet",
        provider: "anthropic",
        thinkingLevel: "high",
        displayName: "anthropic:claude-sonnet",
      });
      expect(s.modelsLoading).toBe(false);
    });

    it("handles selection errors", async () => {
      const session = mockSession({
        setModel: () => Promise.reject(new Error("invalid model")),
      });

      await store.getState().selectModel(session, "nonexistent");
      expect(store.getState().modelsError).toBe("invalid model");
    });

    it("passes model spec without thinkingLevel when omitted", async () => {
      const setModel = vi.fn().mockResolvedValue({
        model: { id: "gpt-4", provider: "copilot", thinkingLevel: "off" },
      });
      const session = mockSession({ setModel });

      await store.getState().selectModel(session, "gpt-4");
      expect(setModel).toHaveBeenCalledWith("gpt-4");
    });

    it("passes model spec with thinkingLevel when provided", async () => {
      const setModel = vi.fn().mockResolvedValue({
        model: { id: "claude-sonnet", provider: "anthropic", thinkingLevel: "high" },
      });
      const session = mockSession({ setModel });

      await store.getState().selectModel(session, "claude-sonnet", "high");
      expect(setModel).toHaveBeenCalledWith({ id: "claude-sonnet", thinkingLevel: "high" });
    });
  });

  describe("displayName", () => {
    it("uses bare id for copilot provider", async () => {
      const session = mockSession({
        setModel: vi.fn().mockResolvedValue({
          model: { id: "gpt-4o", provider: "copilot", thinkingLevel: "off" },
        }),
      });
      await store.getState().selectModel(session, "gpt-4o");
      expect(store.getState().currentModel?.displayName).toBe("gpt-4o");
    });

    it("uses provider:id for non-copilot provider", async () => {
      const session = mockSession({
        setModel: vi.fn().mockResolvedValue({
          model: { id: "claude-3", provider: "anthropic", thinkingLevel: "off" },
        }),
      });
      await store.getState().selectModel(session, "claude-3");
      expect(store.getState().currentModel?.displayName).toBe("anthropic:claude-3");
    });
  });
});
