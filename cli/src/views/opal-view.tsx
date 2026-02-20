import React, { type FC } from "react";
import { Box } from "ink";
import { Welcome } from "../components/welcome.js";
import { useOpalStore } from "../state/index.js";
import { selectFocusedAgent } from "../state/selectors.js";
import { Timeline } from "../components/timeline.js";
import { InputBar } from "../components/input-bar.js";
import { QueuedMessages } from "../components/queued-messages.js";
import { ModelPicker } from "../components/model-picker.js";
import { AgentPicker } from "../components/agent-picker.js";
import { ConfigPanel } from "../components/config-panel.js";
import { DebugPanel } from "../components/debug-panel.js";
import { useOverlay } from "../hooks/use-overlay.js";
import { useOpalCommands } from "../hooks/use-opal-commands.js";

export const OpalView: FC = () => {
  const workingDir = useOpalStore((s) => s.workingDir);
  const contextFiles = useOpalStore((s) => s.contextFiles);
  const skills = useOpalStore((s) => s.availableSkills);
  const distributionNode = useOpalStore((s) => s.distributionNode);
  const queuedMessages = useOpalStore((s) => s.queuedMessages);
  const availableModels = useOpalStore((s) => s.availableModels);
  const currentModel = useOpalStore((s) => s.currentModel);
  const debugVisible = useOpalStore((s) => s.debugVisible);
  const rpcEntries = useOpalStore((s) => s.rpcEntries);
  const stderrLines = useOpalStore((s) => s.stderrLines);
  const clearDebug = useOpalStore((s) => s.clearDebug);
  const agents = useOpalStore((s) => s.agents);
  const focusStack = useOpalStore((s) => s.focusStack);
  const hasEntries = useOpalStore((s) => selectFocusedAgent(s).entries.length > 0);

  const [flash, setFlash] = React.useState<string | null>(null);
  const showFlash = React.useCallback((msg: string) => {
    setFlash(msg);
    setTimeout(() => setFlash(null), 1500);
  }, []);

  const overlay = useOverlay(showFlash);
  const { cmds, hotkeys, handleSubmit } = useOpalCommands(overlay.setOverlay, showFlash);

  const focusedId = focusStack[focusStack.length - 1] ?? "root";

  return (
    <Box flexDirection="column">
      <Welcome
        dimmed={hasEntries}
        workingDir={workingDir}
        contextFiles={contextFiles}
        skills={skills}
        distributionNode={distributionNode}
      />
      <Timeline />
      {debugVisible && (
        <DebugPanel rpcEntries={rpcEntries} stderrLines={stderrLines} onClear={clearDebug} />
      )}
      <QueuedMessages messages={queuedMessages} />
      {overlay.overlay === "models" && (
        <ModelPicker
          models={availableModels}
          current={currentModel?.id ?? ""}
          currentThinkingLevel={currentModel?.thinkingLevel}
          onSelect={overlay.handleModelSelect}
          onDismiss={overlay.dismissOverlay}
        />
      )}
      {overlay.overlay === "agents" && (
        <AgentPicker
          agents={agents}
          focusedId={focusedId}
          onSelect={overlay.handleAgentSelect}
          onDismiss={overlay.dismissOverlay}
        />
      )}
      {overlay.overlay === "opal" && (
        <ConfigPanel
          getConfig={overlay.getOpalConfig}
          setConfig={overlay.setOpalConfig}
          onDismiss={overlay.dismissOverlay}
        />
      )}
      <InputBar
        onSubmit={handleSubmit}
        focus={overlay.overlay === null}
        toast={flash}
        commands={cmds.commands}
        hotkeys={hotkeys}
      />
    </Box>
  );
};
