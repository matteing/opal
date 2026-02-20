/**
 * useModels — React hook for model listing and selection.
 *
 * Encapsulates fetching available models, reading the current model,
 * and switching models via the SDK2 {@link Session}. Stateless until
 * a session is provided.
 *
 * @example
 * ```tsx
 * function ModelPicker() {
 *   const { session } = useSession({ workingDir: "." });
 *   const models = useModels(session);
 *
 *   if (!models.current) return <Text>Loading…</Text>;
 *
 *   return (
 *     <SelectInput
 *       items={models.available.map((m) => ({ label: m.name, value: m.id }))}
 *       onSelect={(item) => models.select(item.value)}
 *     />
 *   );
 * }
 * ```
 *
 * @module
 */

import { useState, useEffect, useCallback } from "react";
import type { Session } from "../sdk/session.js";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/** A model available for selection. */
export interface ModelInfo {
  readonly id: string;
  readonly name: string;
  readonly provider: string;
  readonly supportsThinking: boolean;
  readonly thinkingLevels: readonly string[];
}

/** The currently active model. */
export interface ActiveModel {
  readonly id: string;
  readonly provider: string;
  readonly thinkingLevel: string;
  /** Display string: `provider:id` for non-copilot, just `id` for copilot. */
  readonly displayName: string;
}

/** State managed by the useModels hook. */
export interface ModelsState {
  /** Available models (empty until fetched). */
  readonly available: readonly ModelInfo[];
  /** Currently active model (null until fetched). */
  readonly current: ActiveModel | null;
  /** Whether a fetch or switch operation is in progress. */
  readonly loading: boolean;
  /** Last error message, if any. */
  readonly error: string | null;
}

/** Actions returned by the useModels hook. */
export interface ModelsActions {
  /** Switch to a different model, optionally setting a thinking level. */
  readonly select: (modelId: string, thinkingLevel?: string) => void;
  /** Refresh the available models list and current model. */
  readonly refresh: () => void;
}

/** Return type of the useModels hook. */
export type UseModelsReturn = ModelsState & ModelsActions;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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

function toActiveModel(model: {
  id: string;
  provider: string;
  thinkingLevel: string;
}): ActiveModel {
  return {
    id: model.id,
    provider: model.provider,
    thinkingLevel: model.thinkingLevel,
    displayName: displayName(model),
  };
}

// ---------------------------------------------------------------------------
// Hook
// ---------------------------------------------------------------------------

/**
 * Manage model listing and selection for an Opal session.
 *
 * Pass a `Session` (from `useSession`) once connected. The hook fetches
 * available models and current model on first render, and exposes
 * `select` / `refresh` actions.
 *
 * Pass `null` when the session isn't ready yet — the hook stays idle.
 */
export function useModels(session: Session | null): UseModelsReturn {
  const [available, setAvailable] = useState<readonly ModelInfo[]>([]);
  const [current, setCurrent] = useState<ActiveModel | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(() => {
    if (!session) return;
    setLoading(true);
    setError(null);

    Promise.all([session.models(), session.state()])
      .then(([modelsRes, stateRes]) => {
        setAvailable(modelsRes.models.map(toModelInfo));
        setCurrent(toActiveModel(stateRes.model));
      })
      .catch((err: unknown) => {
        setError(err instanceof Error ? err.message : String(err));
      })
      .finally(() => setLoading(false));
  }, [session]);

  // Fetch on first session connect
  useEffect(() => {
    if (session) refresh();
  }, [session, refresh]);

  const select = useCallback(
    (modelId: string, thinkingLevel?: string) => {
      if (!session) return;
      setLoading(true);
      setError(null);

      session
        .setModel(thinkingLevel ? { id: modelId, thinkingLevel } : modelId)
        .then((res) => {
          setCurrent(toActiveModel(res.model));
        })
        .catch((err: unknown) => {
          setError(err instanceof Error ? err.message : String(err));
        })
        .finally(() => setLoading(false));
    },
    [session],
  );

  return { available, current, loading, error, select, refresh };
}
