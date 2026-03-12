import { useEffect } from "react";
import { useAppStore } from "./state/store.js";
import { bridge } from "./sdk/bridge.js";
import { AppHeader } from "./components/AppHeader.js";
import { Conversation } from "./components/Conversation.js";
import { ThinkingIndicator } from "./components/ThinkingIndicator.js";
import { InputArea } from "./components/InputArea.js";
import { ConfirmDialog, AskUserDialog } from "./components/Dialogs.js";
import { ErrorBanner } from "./components/ErrorBanner.js";

export default function App() {
  const {
    sessionReady,
    workingDir,
    error,
    timeline,
    isRunning,
    thinkingText,
    statusMessage,
    currentModel,
    tokenUsage,
    confirmation,
    askUser,
    applyEvent,
    startSession,
    submitPrompt,
    submitSteer,
    abort,
    resolveConfirmation,
    resolveAskUser,
    setError,
  } = useAppStore();

  // Boot: start session and wire up event listeners
  useEffect(() => {
    startSession();

    const unsubEvent = bridge.onEvent((event) => {
      applyEvent(event);
    });

    const unsubConfirm = bridge.onConfirm((params) => {
      useAppStore.setState({
        confirmation: {
          id: (params as { id: string }).id,
          tool: (params as { tool: string }).tool,
          args: (params as { args: Record<string, unknown> }).args ?? {},
          message: (params as { message?: string }).message,
        },
      });
    });

    const unsubAsk = bridge.onAskUser((params) => {
      useAppStore.setState({
        askUser: {
          id: (params as { id: string }).id,
          question: (params as { question: string }).question,
          choices: (params as { choices?: string[] }).choices,
        },
      });
    });

    return () => {
      unsubEvent();
      unsubConfirm();
      unsubAsk();
    };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  if (!sessionReady) {
    return (
      <main>
        <p>Starting session…</p>
        {error && <ErrorBanner message={error} onDismiss={() => setError(null)} />}
      </main>
    );
  }

  return (
    <>
      <AppHeader workingDir={workingDir} model={currentModel} tokenUsage={tokenUsage} />

      <main>
        <Conversation timeline={timeline} isRunning={isRunning} />

        {isRunning && (
          <ThinkingIndicator text={thinkingText} statusMessage={statusMessage} />
        )}
      </main>

      <InputArea
        isRunning={isRunning}
        onSubmit={submitPrompt}
        onSteer={submitSteer}
        onAbort={abort}
      />

      {confirmation && (
        <ConfirmDialog request={confirmation} onResolve={resolveConfirmation} />
      )}

      {askUser && <AskUserDialog request={askUser} onResolve={resolveAskUser} />}

      {error && <ErrorBanner message={error} onDismiss={() => setError(null)} />}
    </>
  );
}
