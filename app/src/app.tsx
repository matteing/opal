import { useEffect, useCallback } from "react";
import { useAppStore } from "./state/store.js";
import {
  useCurrentView,
  useSessions,
  useActiveSessionId,
  useHeaderData,
  useError,
  useOverlay,
  useSessionActions,
  useConversationActions,
  useDialogActions,
} from "./state/selectors.js";
import { bridge } from "./sdk/bridge.js";
import { AppHeader } from "./components/AppHeader.js";
import { Conversation } from "./components/Conversation.js";
import { ThinkingIndicator } from "./components/ThinkingIndicator.js";
import { InputArea } from "./components/InputArea.js";
import { ConfirmDialog, AskUserDialog } from "./components/Dialogs.js";
import { ErrorBanner } from "./components/ErrorBanner.js";
import { Sidebar } from "./components/sidebar/index.js";
import { ModelPicker, SettingsPanel, RuntimeConfigPanel } from "./components/settings/index.js";

export default function App() {
  const sessions = useSessions();
  const activeSessionId = useActiveSessionId();
  const currentView = useCurrentView();
  const { workingDir, model, tokenUsage } = useHeaderData();
  const error = useError();
  const overlay = useOverlay();

  const { createSession, resumeSession, switchSession, deleteSession, refreshSessionList } =
    useSessionActions();
  const { submitPrompt, submitSteer, abort } = useConversationActions();
  const { resolveConfirmation, resolveAskUser } = useDialogActions();
  const setError = useAppStore((s) => s.setError);
  const setOverlay = useAppStore((s) => s.setOverlay);
  const applyEvent = useAppStore((s) => s.applyEvent);
  const runCommand = useAppStore((s) => s.runCommand);

  // ── IPC event listeners ────────────────────────────────────
  useEffect(() => {
    const unsubEvent = bridge.onEvent((event) => applyEvent(event));

    const unsubConfirm = bridge.onConfirm((params) => {
      const { sessionId } = params;
      const view = useAppStore.getState().sessionViews[sessionId];
      if (!view) return;
      useAppStore.setState((s) => ({
        sessionViews: {
          ...s.sessionViews,
          [sessionId]: {
            ...view,
            confirmation: {
              id: params.requestId,
              tool: params.tool,
              args: params.args ?? {},
              message: params.message,
            },
          },
        },
      }));
    });

    const unsubAsk = bridge.onAskUser((params) => {
      const { sessionId } = params;
      const view = useAppStore.getState().sessionViews[sessionId];
      if (!view) return;
      useAppStore.setState((s) => ({
        sessionViews: {
          ...s.sessionViews,
          [sessionId]: {
            ...view,
            askUser: {
              id: params.requestId,
              question: params.question,
              choices: params.choices,
            },
          },
        },
      }));
    });

    refreshSessionList();

    return () => {
      unsubEvent();
      unsubConfirm();
      unsubAsk();
    };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  // ── Keyboard shortcuts ─────────────────────────────────────
  const handleKeyboard = useCallback(
    (e: KeyboardEvent) => {
      const mod = e.metaKey || e.ctrlKey;
      if (!mod) return;

      switch (e.key) {
        case "n":
          e.preventDefault();
          createSession();
          break;
        case "k":
          e.preventDefault();
          setOverlay(overlay === "models" ? null : "models");
          break;
        case ",":
          e.preventDefault();
          setOverlay(overlay === "settings" ? null : "settings");
          break;
        case ".":
          e.preventDefault();
          abort();
          break;
        case "y":
          e.preventDefault();
          bridge.openPlan().catch(() => {});
          break;
        case "[":
          e.preventDefault();
          switchToPrev();
          break;
        case "]":
          e.preventDefault();
          switchToNext();
          break;
      }

      if (e.key === "Escape") {
        setOverlay(null);
      }
    },
    [overlay], // eslint-disable-line react-hooks/exhaustive-deps
  );

  useEffect(() => {
    window.addEventListener("keydown", handleKeyboard);
    return () => window.removeEventListener("keydown", handleKeyboard);
  }, [handleKeyboard]);

  // ── Session navigation helpers ─────────────────────────────
  const switchToPrev = useCallback(() => {
    const { sessions: s, activeSessionId: id } = useAppStore.getState();
    const activeSessions = s.filter((se) => se.active);
    const idx = activeSessions.findIndex((se) => se.id === id);
    if (idx > 0) switchSession(activeSessions[idx - 1].id);
  }, [switchSession]);

  const switchToNext = useCallback(() => {
    const { sessions: s, activeSessionId: id } = useAppStore.getState();
    const activeSessions = s.filter((se) => se.active);
    const idx = activeSessions.findIndex((se) => se.id === id);
    if (idx < activeSessions.length - 1) switchSession(activeSessions[idx + 1].id);
  }, [switchSession]);

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
        {currentView ? (
          <>
            <AppHeader workingDir={workingDir} model={model} tokenUsage={tokenUsage} />

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
              onCommand={runCommand}
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

      {/* ── Overlay panels ── */}
      {overlay === "models" && (
        <ModelPicker currentModel={model} onClose={() => setOverlay(null)} />
      )}
      {overlay === "settings" && (
        <SettingsPanel onClose={() => setOverlay(null)} />
      )}
      {overlay === "runtime-config" && (
        <RuntimeConfigPanel onClose={() => setOverlay(null)} />
      )}
    </div>
  );
}
