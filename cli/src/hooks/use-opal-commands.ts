/**
 * useOpalCommands — slash commands, hotkeys, flash toast, and submit handler.
 *
 * Bundles all command/hotkey/input-handling logic that was previously
 * inline in OpalView.
 *
 * @module
 */

import { useCallback, useMemo } from "react";
import { useOpalStore } from "../state/index.js";
import { useHotkeys } from "./use-hotkeys.js";
import { useCommands, type CommandRegistry } from "./use-commands.js";
import { copyToClipboard } from "../lib/desktop.js";
import type { Overlay } from "./use-overlay.js";

export interface UseOpalCommandsReturn {
  readonly cmds: ReturnType<typeof useCommands>;
  readonly hotkeys: ReturnType<typeof useHotkeys>["hotkeys"];
  readonly handleSubmit: (text: string) => void;
}

export function useOpalCommands(
  setOverlay: (o: Overlay) => void,
  showFlash: (msg: string) => void,
): UseOpalCommandsReturn {
  const session = useOpalStore((s) => s.session);
  const sendMessage = useOpalStore((s) => s.sendMessage);
  const pushStatus = useOpalStore((s) => s.pushStatus);
  const toggleDebug = useOpalStore((s) => s.toggleDebug);
  const rpcEntries = useOpalStore((s) => s.rpcEntries);
  const toggleToolOutput = useOpalStore((s) => s.toggleToolOutput);
  const showToolOutput = useOpalStore((s) => s.showToolOutput);
  const addToHistory = useOpalStore((s) => s.addToHistory);

  // ── Slash commands ───────────────────────────────────────────

  const commandDefs = useMemo<CommandRegistry>(
    () => ({
      models: {
        description: "Select a model",
        execute: () => {
          setOverlay("models");
        },
      },
      compact: {
        description: "Compact conversation history",
        execute: async () => {
          if (!session) return "No active session.";
          pushStatus("Compacting conversation…", "info");
          try {
            await session.compact();
            pushStatus("Conversation compacted", "success");
          } catch (e: unknown) {
            pushStatus(`Compaction failed: ${e instanceof Error ? e.message : String(e)}`, "error");
          }
        },
      },
      agents: {
        description: "Switch between agents",
        execute: () => {
          setOverlay("agents");
        },
      },
      debug: {
        description: "Toggle RPC debug panel",
        execute: () => {
          toggleDebug();
        },
      },
      opal: {
        description: "Configure features and tools",
        execute: () => {
          setOverlay("opal");
        },
      },
    }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [session],
  );

  const cmds = useCommands(commandDefs);

  // ── Hotkeys ──────────────────────────────────────────────────

  const { hotkeys } = useHotkeys({
    "ctrl+d": {
      description: "Copy RPC debug log to clipboard",
      handler: () => {
        const json = JSON.stringify(rpcEntries, null, 2);
        const ok = copyToClipboard(json);
        showFlash(ok ? "RPC log copied to clipboard" : "Clipboard unavailable");
      },
    },
    "ctrl+o": {
      description: "Toggle tool output",
      handler: () => {
        toggleToolOutput();
        showFlash(showToolOutput ? "Tool output hidden" : "Tool output visible");
      },
    },
  });

  // ── Submit handler ───────────────────────────────────────────

  const handleSubmit = useCallback(
    (text: string) => {
      // Save to local history
      addToHistory(text);

      if (cmds.isCommand(text)) {
        const result = cmds.run(text);
        const handleResult = (r: { ok: boolean; message?: string }) => {
          if (r.message) showFlash(r.message);
        };
        if (result instanceof Promise) {
          void result.then(handleResult);
        } else {
          handleResult(result);
        }
        return;
      }
      sendMessage(text);
    },
    [cmds, sendMessage, showFlash, addToHistory],
  );

  return { cmds, hotkeys, handleSubmit };
}
