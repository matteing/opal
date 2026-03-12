import { useEffect } from "react";
import { useAppStore } from "./state/store.js";
import { bridge } from "./sdk/bridge.js";
import { AppHeader } from "./components/AppHeader.js";
import { Conversation } from "./components/Conversation.js";
import { ThinkingIndicator } from "./components/ThinkingIndicator.js";
import { InputArea } from "./components/InputArea.js";
import { ConfirmDialog, AskUserDialog } from "./components/Dialogs.js";
import { ErrorBanner } from "./components/ErrorBanner.js";
import { Sidebar } from "./components/sidebar/index.js";

export default function App() {
  const {
    sessions,
    activeSessionId,
    currentView,
    workingDir,
    error,
    applyEvent,
    createSession,
    resumeSession,
    switchSession,
    deleteSession,
    refreshSessionList,
    submitPrompt,
    submitSteer,
    abort,
    resolveConfirmation,
    resolveAskUser,
    setError,
  } = useAppStore();

  // Wire up event listeners on mount
  useEffect(() => {
    const unsubEvent = bridge.onEvent((event) => {
      applyEvent(event);
    });

    const unsubConfirm = bridge.onConfirm((params) => {
      const sessionId = params.sessionId;
      const view = useAppStore.getState().sessionViews[sessionId];
      if (!view) return;
      const updated = {
        ...view,
        confirmation: {
          id: params.requestId,
          tool: params.tool,
          args: params.args ?? {},
          message: params.message,
        },
      };
      useAppStore.setState((s) => ({
        sessionViews: { ...s.sessionViews, [sessionId]: updated },
        currentView: sessionId === s.activeSessionId ? updated : s.currentView,
      }));
    });

    const unsubAsk = bridge.onAskUser((params) => {
      const sessionId = params.sessionId;
      const view = useAppStore.getState().sessionViews[sessionId];
      if (!view) return;
      const updated = {
        ...view,
        askUser: {
          id: params.requestId,
          question: params.question,
          choices: params.choices,
        },
      };
      useAppStore.setState((s) => ({
        sessionViews: { ...s.sessionViews, [sessionId]: updated },
        currentView: sessionId === s.activeSessionId ? updated : s.currentView,
      }));
    });

    // Load saved sessions list
    refreshSessionList();

    return () => {
      unsubEvent();
      unsubConfirm();
      unsubAsk();
    };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const hasSession = activeSessionId !== null && currentView !== null;

  return (
    <div id="app-layout">
      <Sidebar
        sessions={sessions}
        activeSessionId={activeSessionId}
        onCreateSession={() => createSession()}
        onResumeSession={(id) => resumeSession(id)}
        onSwitchSession={(id) => switchSession(id)}
        onDeleteSession={(id) => deleteSession(id)}
      />

      <div id="app-content">
        {hasSession ? (
          <>
            <AppHeader
              workingDir={workingDir}
              model={currentView.currentModel}
              tokenUsage={currentView.tokenUsage}
            />

            <main>
              <Conversation
                timeline={currentView.timeline}
                isRunning={currentView.isRunning}
              />

              {currentView.isRunning && (
                <ThinkingIndicator
                  text={currentView.thinkingText}
                  statusMessage={currentView.statusMessage}
                />
              )}
            </main>

            <InputArea
              isRunning={currentView.isRunning}
              onSubmit={submitPrompt}
              onSteer={submitSteer}
              onAbort={abort}
            />

            {currentView.confirmation && (
              <ConfirmDialog
                request={currentView.confirmation}
                onResolve={resolveConfirmation}
              />
            )}

            {currentView.askUser && (
              <AskUserDialog request={currentView.askUser} onResolve={resolveAskUser} />
            )}
          </>
        ) : (
          <main>
            <div data-role="empty-state">
              <h2>✦ Opal Desktop</h2>
              <p>Create a new session to get started.</p>
              <button onClick={() => createSession()}>New Session</button>
            </div>
          </main>
        )}

        {error && <ErrorBanner message={error} onDismiss={() => setError(null)} />}
      </div>
    </div>
  );
}
