import React, { useState, useEffect, useRef, useCallback, type FC } from "react";
import { Box, Text, useApp, useInput, useStdout, type Key } from "ink";
import { useOpal } from "./hooks/use-opal.js";
import { MessageList } from "./components/message-list.js";
import { BottomBar } from "./components/bottom-bar.js";
import { ThinkingIndicator } from "./components/thinking.js";
import { ConfirmDialog } from "./components/confirm-dialog.js";
import { AskUserDialog } from "./components/ask-user-dialog.js";
import { ModelPicker } from "./components/model-picker.js";
import { OpalMenu } from "./components/opal-menu.js";
import { ShimmerText } from "./components/shimmer-text.js";
import { SetupWizard } from "./components/device-auth.js";
import { RpcPanel } from "./components/rpc-panel.js";
import { openPlanInEditor } from "./open-editor.js";
import type { SessionOptions } from "./sdk/session.js";
import { colors } from "./lib/palette.js";

export interface AppProps {
  sessionOpts: SessionOptions;
  initialPrompt?: string;
  onSessionId?: (id: string) => void;
}

export const App: FC<AppProps> = ({ sessionOpts, initialPrompt, onSessionId }) => {
  const [state, actions] = useOpal(sessionOpts);
  const { exit } = useApp();
  const { stdout } = useStdout();
  const [stalled, setStalled] = useState(false);
  const [showToolOutput, setShowToolOutput] = useState(false);
  const lastDeltaRef = useRef(0);
  // Fill the viewport on initial load; once the user starts interacting, let
  // content flow naturally so it scrolls like a regular terminal program.
  const [initialFill, setInitialFill] = useState(true);

  // Drop the viewport constraint once the first user prompt is submitted.
  useEffect(() => {
    if (state.main.timeline.length > 0) {
      setInitialFill(false);
    }
  }, [state.main.timeline.length]);

  // Notify parent of the session ID for the exit resume hint.
  useEffect(() => {
    if (state.sessionId) onSessionId?.(state.sessionId);
  }, [state.sessionId, onSessionId]);

  // Send initial prompt once the session is ready.
  const initialPromptSent = useRef(false);
  useEffect(() => {
    if (initialPrompt && state.sessionId && !initialPromptSent.current) {
      initialPromptSent.current = true;
      actions.submitPrompt(initialPrompt);
    }
  }, [initialPrompt, state.sessionId, actions]);

  // Resolve the active agent view (main or a sub-agent tab)
  const activeView =
    state.activeTab === "main" ? state.main : (state.subAgents[state.activeTab] ?? state.main);

  // Keep ref in sync so the interval can read it without re-creating
  useEffect(() => {
    lastDeltaRef.current = state.lastDeltaAt;
  }, [state.lastDeltaAt]);

  // Detect when the model goes quiet mid-stream (e.g. composing a long file)
  useEffect(() => {
    if (!state.main.isRunning) {
      setStalled(false);
      return;
    }
    const timer = setInterval(() => {
      const last = lastDeltaRef.current;
      setStalled(last > 0 && Date.now() - last > 2000);
    }, 500);
    return () => clearInterval(timer);
  }, [state.main.isRunning]);

  // Track the last running tool name to avoid scanning timeline in the title effect
  const runningToolRef = useRef<string | null>(null);

  // Update running tool ref cheaply — only look at the last timeline entry
  useEffect(() => {
    const tl = activeView.timeline;
    let toolName: string | null = null;
    for (let i = tl.length - 1; i >= 0; i--) {
      const e = tl[i];
      if (e.kind === "tool" && e.task.status === "running") {
        toolName = e.task.tool;
        break;
      }
      // Stop early — once we hit a non-tool entry, no running tool is visible
      if (e.kind === "message") break;
    }
    runningToolRef.current = toolName;
  });

  // Update terminal tab title based on current activity
  useEffect(() => {
    let status: string;
    if (!state.sessionReady) {
      status = "starting…";
    } else if (activeView.statusMessage) {
      status = activeView.statusMessage;
    } else if (activeView.thinking !== null) {
      status = "thinking…";
    } else if (activeView.isRunning) {
      status = runningToolRef.current ?? "responding…";
    } else {
      status = "idle";
    }
    process.stdout.write(`\x1b]0;✦ opal · ${status}\x07`);
  }, [state.sessionReady, activeView.isRunning, activeView.thinking, activeView.statusMessage]);

  // Restore terminal title on unmount
  useEffect(() => {
    return () => {
      process.stdout.write("\x1b]0;\x07");
    };
  }, []);

  // Keep mutable refs so the useInput handler is reference-stable and Ink
  // never tears down / re-adds the stdin listener during streaming.
  const isRunningRef = useRef(state.main.isRunning);
  isRunningRef.current = state.main.isRunning;
  const actionsRef = useRef(actions);
  actionsRef.current = actions;
  const sessionDirRef = useRef(state.sessionDir);
  sessionDirRef.current = state.sessionDir;

  const appInputHandler = useCallback(
    (input: string, key: Key) => {
      if (input === "c" && key.ctrl) {
        if (isRunningRef.current) {
          actionsRef.current.abort();
        } else {
          exit();
        }
      }
      if (input === "o" && key.ctrl) {
        setShowToolOutput((v) => !v);
      }
      if (input === "y" && key.ctrl) {
        openPlanInEditor(sessionDirRef.current);
      }
    },
    [exit],
  );

  useInput(appInputHandler);

  const rows = stdout?.rows ?? 24;

  if (state.error && !state.sessionReady) {
    return (
      <Box flexDirection="column" padding={1} minHeight={rows}>
        <Text color={colors.error} bold>
          Error: {state.error}
        </Text>
      </Box>
    );
  }

  if (state.authFlow) {
    return (
      <Box flexDirection="column" minHeight={rows}>
        <SetupWizard flow={state.authFlow} actions={actions} error={state.error} />
      </Box>
    );
  }

  if (!state.sessionReady) {
    return (
      <Box flexDirection="column" padding={1} minHeight={rows}>
        <ShimmerText>Starting Opal…</ShimmerText>
        {state.serverLogs.length > 0 && (
          <Box flexDirection="column" marginTop={1}>
            {state.serverLogs.slice(-8).map((line, i) => (
              <Text key={i} dimColor>
                {line}
              </Text>
            ))}
          </Box>
        )}
      </Box>
    );
  }

  const subAgentCount = Object.keys(state.subAgents).length;
  const rpcPanelHeight = Math.min(12, Math.floor(rows * 0.35));

  return (
    <Box flexDirection="column" width="100%" minHeight={initialFill ? rows : undefined}>
      {state.error && (
        <Box paddingX={1}>
          <Text color={colors.error}>⚠ {state.error}</Text>
        </Box>
      )}

      <MessageList
        view={activeView}
        subAgents={state.subAgents}
        workingDir={state.workingDir}
        showToolOutput={showToolOutput}
        sessionReady={state.sessionReady}
      />

      {(activeView.thinking !== null ||
        stalled ||
        (activeView.isRunning && !lastEntryIsAssistant(activeView.timeline))) && (
        <Box paddingX={1} justifyContent="space-between">
          <ThinkingIndicator label={activeView.statusMessage ?? "thinking…"} />
          {subAgentCount > 0 && (
            <Text dimColor>
              {subAgentCount} sub-agent{subAgentCount > 1 ? "s" : ""} · <Text bold>/agents</Text>
            </Text>
          )}
        </Box>
      )}

      {state.confirmation && (
        <ConfirmDialog request={state.confirmation} onResolve={actions.resolveConfirmation} />
      )}

      {state.askUser && (
        <AskUserDialog
          question={state.askUser.question}
          choices={state.askUser.choices}
          onResolve={actions.resolveAskUser}
        />
      )}

      {state.modelPicker && (
        <ModelPicker
          models={state.modelPicker.models}
          current={state.modelPicker.current}
          currentThinkingLevel={state.modelPicker.currentThinkingLevel}
          onSelect={actions.selectModel}
          onDismiss={actions.dismissModelPicker}
        />
      )}

      {state.opalMenu && (
        <OpalMenu
          config={state.opalMenu}
          onToggleFeature={actions.toggleOpalFeature}
          onToggleTool={actions.toggleOpalTool}
          onDismiss={actions.dismissOpalMenu}
        />
      )}

      <BottomBar state={state} actions={actions} />

      {state.showDebugPanel && <RpcPanel messages={state.rpcMessages} height={rpcPanelHeight} />}
    </Box>
  );
};

function lastEntryIsAssistant(timeline: { kind: string; message?: { role: string } }[]): boolean {
  for (let i = timeline.length - 1; i >= 0; i--) {
    const entry = timeline[i];
    if (entry.kind === "message") return entry.message?.role === "assistant";
  }
  return false;
}
