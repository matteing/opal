/**
 * Models slice — model listing and selection.
 *
 * Fetches available models on session connect, tracks the active model,
 * and provides a `selectModel` action to switch.
 *
 * @module
 */

import type { StateCreator } from "zustand";
import type { Session } from "../sdk/session.js";
import type { ModelInfo, ActiveModel } from "./types.js";

// ── Slice state + actions ────────────────────────────────────────

export interface ModelsSlice {
  availableModels: readonly ModelInfo[];
  currentModel: ActiveModel | null;
  modelsLoading: boolean;
  modelsError: string | null;

  /** Fetch models from the session and update state. */
  fetchModels: (session: Session) => Promise<void>;
  /** Switch to a different model. */
  selectModel: (session: Session, modelId: string, thinkingLevel?: string) => Promise<void>;
}

// ── Helpers ──────────────────────────────────────────────────────

function displayName(model: { id: string; provider: string }): string {
  return model.provider !== "copilot" ? `${model.provider}:${model.id}` : model.id;
}

function toModelInfo(raw: Record<string, unknown>): ModelInfo {
  return {
    id: (raw.id as string) ?? "",
    name: (raw.name as string) ?? (raw.id as string) ?? "",
    provider: (raw.provider as string) ?? "copilot",
    supportsThinking: (raw.supportsThinking as boolean) ?? false,
    thinkingLevels: (raw.thinkingLevels as string[]) ?? [],
  };
}

function toActiveModel(raw: { id: string; provider: string; thinkingLevel: string }): ActiveModel {
  return { ...raw, displayName: displayName(raw) };
}

// ── Slice creator ────────────────────────────────────────────────

export const createModelsSlice: StateCreator<ModelsSlice, [], [], ModelsSlice> = (set) => ({
  availableModels: [],
  currentModel: null,
  modelsLoading: false,
  modelsError: null,

  fetchModels: async (session) => {
    set({ modelsLoading: true, modelsError: null });
    try {
      const [modelsRes, stateRes] = await Promise.all([session.models(), session.state()]);
      set({
        availableModels: modelsRes.models.map(toModelInfo),
        currentModel: toActiveModel(stateRes.model),
        modelsLoading: false,
      });
    } catch (err: unknown) {
      set({
        modelsError: err instanceof Error ? err.message : String(err),
        modelsLoading: false,
      });
    }
  },

  selectModel: async (session, modelId, thinkingLevel) => {
    set({ modelsLoading: true, modelsError: null });
    try {
      const res = await session.setModel(thinkingLevel ? { id: modelId, thinkingLevel } : modelId);
      set({
        currentModel: toActiveModel(res.model),
        modelsLoading: false,
      });
    } catch (err: unknown) {
      set({
        modelsError: err instanceof Error ? err.message : String(err),
        modelsLoading: false,
      });
    }
  },
});
