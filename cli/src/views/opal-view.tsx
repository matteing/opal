import React, { useState, useCallback, useMemo, type FC } from "react";
import { Box } from "ink";
import { Welcome } from "../components/welcome.js";
import { useOpalStore } from "../state/index.js";
import { useActiveAgent } from "../state/selectors.js";
import { Timeline } from "../components/timeline.js";
import { InputBar } from "../components/input-bar.js";
import { QueuedMessages } from "../components/queued-messages.js";
import { ModelPicker } from "../components/model-picker.js";
import { AgentPicker } from "../components/agent-picker.js";
import { ConfigPanel } from "../components/config-panel.js";
import { useHotkeys } from "../hooks/use-hotkeys.js";
import { useCommands, type CommandRegistry } from "../hooks/use-commands.js";
import { DebugPanel } from "../components/debug-panel.js";
import { copyToClipboard } from "../lib/desktop.js";
import type { OpalConfigSetParams } from "../sdk/protocol.js";

type Overlay = "models" | "agents" | "opal" | null;

export const OpalView: FC = () => {
  const workingDir = useOpalStore((s) => s.workingDir);
  const contextFiles = useOpalStore((s) => s.contextFiles);
  const skills = useOpalStore((s) => s.availableSkills);
  const sendMessage = useOpalStore((s) => s.sendMessage);
  const session = useOpalStore((s) => s.session);
  const rpcEntries = useOpalStore((s) => s.rpcEntries);
  const queuedMessages = useOpalStore((s) => s.queuedMessages);
  const availableModels = useOpalStore((s) => s.availableModels);
  const currentModel = useOpalStore((s) => s.currentModel);
  const selectModel = useOpalStore((s) => s.selectModel);
  const toggleDebug = useOpalStore((s) => s.toggleDebug);
  const debugVisible = useOpalStore((s) => s.debugVisible) as boolean;
  const stderrLines = useOpalStore((s) => s.stderrLines);
  const clearDebug = useOpalStore((s) => s.clearDebug);
  const agents = useOpalStore((s) => s.agents);
  const focusStack = useOpalStore((s) => s.focusStack);
  const focusAgent = useOpalStore((s) => s.focusAgent);
  const pushStatus = useOpalStore((s) => s.pushStatus);
  const { entries } = useActiveAgent();

  const toggleToolOutput = useOpalStore((s) => s.toggleToolOutput) as () => void;
  const showToolOutput = useOpalStore((s) => s.showToolOutput) as boolean;

  const [flash, setFlash] = useState<string | null>(null);
  const [overlay, setOverlay] = useState<Overlay>(null);

  const showFlash = useCallback((msg: string) => {
    setFlash(msg);
    setTimeout(() => setFlash(null), 1500);
  }, []);

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
            pushStatus(
              `Compaction failed: ${e instanceof Error ? e.message : String(e)}`,
              "error",
            );
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

  // ── Overlay handlers ──────────────────────────────────────────

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

  // ── Submit handler ───────────────────────────────────────────

  const handleSubmit = useCallback(
    (text: string) => {
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
    [cmds, sendMessage, showFlash],
  );

  const focusedId = focusStack[focusStack.length - 1] ?? "root";

  return (
    <Box flexDirection="column">
      <Welcome
        dimmed={entries.length > 0}
        workingDir={workingDir}
        contextFiles={contextFiles}
        skills={skills}
      />
      <Timeline />
      {debugVisible && (
        <DebugPanel
          rpcEntries={rpcEntries as import("../state/types.js").RpcLogEntry[]}
          stderrLines={stderrLines as import("../state/types.js").StderrEntry[]}
          onClear={clearDebug as () => void}
        />
      )}
      <QueuedMessages messages={queuedMessages} />
      {overlay === "models" && (
        <ModelPicker
          models={availableModels as ModelPickerModel[]}
          current={currentModel?.id ?? ""}
          currentThinkingLevel={currentModel?.thinkingLevel}
          onSelect={handleModelSelect}
          onDismiss={dismissOverlay}
        />
      )}
      {overlay === "agents" && (
        <AgentPicker
          agents={agents as Record<string, import("../state/types.js").AgentView>}
          focusedId={focusedId}
          onSelect={handleAgentSelect}
          onDismiss={dismissOverlay}
        />
      )}
      {overlay === "opal" && (
        <ConfigPanel
          getConfig={getOpalConfig}
          setConfig={setOpalConfig}
          onDismiss={dismissOverlay}
        />
      )}
      <InputBar
        onSubmit={handleSubmit}
        focus={overlay === null}
        toast={flash}
        commands={cmds.commands}
        hotkeys={hotkeys}
      />
    </Box>
  );
};

type ModelPickerModel = {
  id: string;
  name: string;
  provider?: string;
  supportsThinking?: boolean;
  thinkingLevels?: string[];
};
