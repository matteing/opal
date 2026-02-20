/**
 * useOverlay — manages modal overlay state for OpalView.
 *
 * Owns the overlay discriminant, model/agent selection handlers,
 * and config panel get/set callbacks.
 *
 * @module
 */

import { useState, useCallback } from "react";
import { useOpalStore } from "../state/index.js";
import type {
  OpalConfigSetParams,
  OpalConfigGetResult,
  OpalConfigSetResult,
} from "../sdk/protocol.js";

export type Overlay = "models" | "agents" | "opal" | null;

export interface UseOverlayReturn {
  readonly overlay: Overlay;
  readonly setOverlay: (o: Overlay) => void;
  readonly handleModelSelect: (modelId: string, thinkingLevel?: string) => void;
  readonly handleAgentSelect: (id: string) => void;
  readonly dismissOverlay: () => void;
  readonly getOpalConfig: () => Promise<OpalConfigGetResult>;
  readonly setOpalConfig: (
    patch: Omit<OpalConfigSetParams, "sessionId">,
  ) => Promise<OpalConfigSetResult>;
}

export function useOverlay(showFlash: (msg: string) => void): UseOverlayReturn {
  const session = useOpalStore((s) => s.session);
  const selectModel = useOpalStore((s) => s.selectModel);
  const focusAgent = useOpalStore((s) => s.focusAgent);

  const [overlay, setOverlay] = useState<Overlay>(null);

  const handleModelSelect = useCallback(
    (modelId: string, thinkingLevel?: string) => {
      setOverlay(null);
      if (!session) return;
      void selectModel(session, modelId, thinkingLevel).then(() => {
        showFlash(`Model: ${modelId}`);
      });
    },
    [session, selectModel, showFlash],
  );

  const handleAgentSelect = useCallback(
    (id: string) => {
      setOverlay(null);
      focusAgent(id);
    },
    [focusAgent],
  );

  const dismissOverlay = useCallback(() => setOverlay(null), []);

  const getOpalConfig = useCallback(async () => {
    if (!session) throw new Error("No active session");
    return session.config.getRuntime();
  }, [session]);

  const setOpalConfig = useCallback(
    async (patch: Omit<OpalConfigSetParams, "sessionId">) => {
      if (!session) throw new Error("No active session");
      return session.config.setRuntime(patch);
    },
    [session],
  );

  return {
    overlay,
    setOverlay,
    handleModelSelect,
    handleAgentSelect,
    dismissOverlay,
    getOpalConfig,
    setOpalConfig,
  };
}
