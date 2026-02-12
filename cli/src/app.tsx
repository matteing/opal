import React, { useState, useEffect, useRef, type FC } from "react";
import { Box, Text, useApp, useInput } from "ink";
import { useOpal } from "./hooks/use-opal.js";
import { Header } from "./components/header.js";
import { MessageList } from "./components/message-list.js";
import { BottomBar } from "./components/bottom-bar.js";
import { ThinkingIndicator } from "./components/thinking.js";
import { ConfirmDialog } from "./components/confirm-dialog.js";
import { ModelPicker } from "./components/model-picker.js";
import { ShimmerText } from "./components/shimmer-text.js";
import type { SessionOptions } from "./sdk/session.js";

export interface AppProps {
  sessionOpts: SessionOptions;
}

export const App: FC<AppProps> = ({ sessionOpts }) => {
  const [state, actions] = useOpal(sessionOpts);
  const { exit } = useApp();
  const [stalled, setStalled] = useState(false);
  const [showToolOutput, setShowToolOutput] = useState(false);
  const lastDeltaRef = useRef(0);

  // Keep ref in sync so the interval can read it without re-creating
  useEffect(() => {
    lastDeltaRef.current = state.lastDeltaAt;
  }, [state.lastDeltaAt]);

  // Detect when the model goes quiet mid-stream (e.g. composing a long file)
  useEffect(() => {
    if (!state.isRunning) {
      setStalled(false);
      return;
    }
    const timer = setInterval(() => {
      const last = lastDeltaRef.current;
      setStalled(last > 0 && Date.now() - last > 2000);
    }, 500);
    return () => clearInterval(timer);
  }, [state.isRunning]);

  useInput((input, key) => {
    if (input === "c" && key.ctrl) {
      if (state.isRunning) {
        actions.abort();
      } else {
        exit();
      }
    }
    if (input === "o" && key.ctrl) {
      setShowToolOutput((v) => !v);
    }
  });

  if (state.error && !state.sessionReady) {
    return (
      <Box flexDirection="column" padding={1}>
        <Text color="red" bold>Error: {state.error}</Text>
      </Box>
    );
  }

  if (!state.sessionReady) {
    return (
      <Box padding={1}>
        <ShimmerText>Starting opal-server…</ShimmerText>
      </Box>
    );
  }

  return (
    <Box flexDirection="column" width="100%">
      <Header workingDir={state.workingDir} nodeName={state.nodeName} />

      <MessageList state={state} showToolOutput={showToolOutput} />

      {(state.thinking !== null || stalled || (state.isRunning && !lastEntryIsAssistant(state.timeline))) && (
        <Box paddingX={1}>
          <ThinkingIndicator label={state.statusMessage ?? "thinking…"} />
        </Box>
      )}

      {state.confirmation && (
        <ConfirmDialog
          request={state.confirmation}
          onResolve={actions.resolveConfirmation}
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

      <BottomBar state={state} actions={actions} />
    </Box>
  );
};

function lastEntryIsAssistant(timeline: { kind: string; message?: { role: string } }[]): boolean {
  for (let i = timeline.length - 1; i >= 0; i--) {
    const entry = timeline[i]!;
    if (entry.kind === "message") return entry.message?.role === "assistant";
  }
  return false;
}
