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
import { AskUserPanel } from "../components/ask-user-panel.js";
import { DebugPanel } from "../components/debug-panel.js";
import { useOverlay } from "../hooks/use-overlay.js";
import { useOpalCommands } from "../hooks/use-opal-commands.js";

export const OpalView: FC = () => {
  const workingDir = useOpalStore((s) => s.workingDir);
  const contextFiles = useOpalStore((s) => s.contextFiles);
  const skills = useOpalStore((s) => s.availableSkills);
  const distributionNode = useOpalStore((s) => s.distributionNode);
  const askUserRequest = useOpalStore((s) => s.askUserRequest);
  const resolveAskUser = useOpalStore((s) => s.resolveAskUser);
  const queuedMessages = useOpalStore((s) => s.queuedMessages);
  const availableModels = useOpalStore((s) => s.availableModels);
  const currentModel = useOpalStore((s) => s.currentModel);
  const debugVisible = useOpalStore((s) => s.debugVisible);
  const hasEntries = useOpalStore((s) => selectFocusedAgent(s).entries.length > 0);

  const [flash, setFlash] = React.useState<string | null>(null);
  const showFlash = React.useCallback((msg: string) => {
    setFlash(msg);
    setTimeout(() => setFlash(null), 1500);
  }, []);

  const overlay = useOverlay(showFlash);
  const { cmds, hotkeys, handleSubmit } = useOpalCommands(overlay.setOverlay, showFlash);

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
      {debugVisible && <DebugPanel />}
      <QueuedMessages messages={queuedMessages} />
      {askUserRequest === null && overlay.overlay === "models" && (
        <ModelPicker
          models={availableModels}
          current={currentModel?.id ?? ""}
          currentThinkingLevel={currentModel?.thinkingLevel}
          onSelect={overlay.handleModelSelect}
          onDismiss={overlay.dismissOverlay}
        />
      )}
      {askUserRequest === null && overlay.overlay === "agents" && (
        <AgentPicker onSelect={overlay.handleAgentSelect} onDismiss={overlay.dismissOverlay} />
      )}
      {askUserRequest === null && overlay.overlay === "opal" && (
        <ConfigPanel
          getConfig={overlay.getOpalConfig}
          setConfig={overlay.setOpalConfig}
          onDismiss={overlay.dismissOverlay}
        />
      )}
      {askUserRequest && (
        <AskUserPanel
          question={askUserRequest.question}
          choices={askUserRequest.choices}
          onRespond={resolveAskUser}
        />
      )}
      <InputBar
        onSubmit={handleSubmit}
        focus={overlay.overlay === null && askUserRequest === null}
        toast={flash}
        commands={cmds.commands}
        hotkeys={hotkeys}
      />
    </Box>
  );
};
