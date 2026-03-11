# Phase 2 — Multi-Session

> Session management sidebar, persistence, resume, and multi-conversation support.

## Goal

Evolve from a single-conversation app into a multi-session workspace. Users can create new conversations, resume previous ones, manage session history, and switch between active sessions — similar to the ChatGPT or Codex sidebar experience.

## Prerequisites

- Phase 1 complete (single conversation works end-to-end)

## Scope

### In Scope

- Session sidebar with list of conversations
- Create new session (with optional working directory picker)
- Resume a saved session (load history, reconnect agent)
- Delete sessions
- Switch between active sessions without losing state
- Session titles (auto-generated from first prompt, editable)
- Session metadata display (created date, working directory, model, message count)
- Session list search/filter
- Branching: rewind conversation to a previous message and fork
- Conversation history display on resume (from `session/history`)

### Out of Scope

- Rich tool rendering (Phase 3)
- Settings panel (Phase 4)
- Scheduling (Phase 5)

## Architecture

### Multi-Session State

Each session maps to a separate `Session` instance from the SDK. The main process manages a map of active sessions:

```typescript
// electron/session-manager.ts
class SessionManager {
  private sessions: Map<string, Session> = new Map();
  private activeId: string | null = null;

  async create(opts: CreateSessionOpts): Promise<string> {
    const session = await createSession(opts);
    this.sessions.set(session.id, session);
    this.activeId = session.id;
    return session.id;
  }

  async resume(sessionId: string, opts: CreateSessionOpts): Promise<void> {
    const session = await createSession({
      ...opts,
      sessionId, // tells Opal to load existing session from DETS
    });
    this.sessions.set(sessionId, session);
    this.activeId = sessionId;
  }

  get active(): Session | null {
    return this.activeId ? this.sessions.get(this.activeId) ?? null : null;
  }

  async close(sessionId: string): Promise<void> {
    const session = this.sessions.get(sessionId);
    if (session) {
      session.close();
      this.sessions.delete(sessionId);
    }
  }

  async list(): Promise<SessionInfo[]> {
    // Calls session/list RPC on any active session
    const anySession = this.sessions.values().next().value;
    if (!anySession) return [];
    return anySession.listSessions();
  }
}
```

### State Shape

```typescript
interface AppState {
  // Session management
  sessions: SessionListEntry[];
  activeSessionId: string | null;
  sessionViews: Record<string, SessionView>; // per-session conversation state

  // Active session view (derived from activeSessionId + sessionViews)
  currentView: SessionView | null;

  // ... existing fields from Phase 1
}

interface SessionListEntry {
  id: string;
  title: string;
  createdAt: string;
  updatedAt: string;
  workingDir: string;
  model: string;
  messageCount: number;
}

interface SessionView {
  timeline: TimelineEntry[];
  isRunning: boolean;
  thinkingText: string;
  statusMessage: string;
  tokenUsage: TokenUsage | null;
  currentModel: string | null;
  confirmation: ConfirmRequest | null;
  askUser: AskUserRequest | null;
}
```

### IPC Extensions

```typescript
// New IPC handlers (all namespaced under opal:)
ipcMain.handle("opal:sessions:list", async () => sessionManager.list());
ipcMain.handle("opal:sessions:create", async (_, opts) => sessionManager.create(opts));
ipcMain.handle("opal:sessions:resume", async (_, id, opts) => sessionManager.resume(id, opts));
ipcMain.handle("opal:sessions:delete", async (_, id) => sessionManager.delete(id));
ipcMain.handle("opal:sessions:switch", async (_, id) => sessionManager.switchTo(id));
ipcMain.handle("opal:session:history", async (_, id) => sessionManager.getHistory(id));
ipcMain.handle("opal:session:branch", async (_, id, messageId) =>
  sessionManager.branch(id, messageId)
);
```

## Components

### Layout

```
┌──────────────┬──────────────────────────────────┐
│ <nav>        │ <header>                         │
│  Sidebar     │   session title · dir · model    │
│              ├──────────────────────────────────│
│  [+ New]     │ <main>                           │
│              │   <article> conversation </article>
│  Sessions:   │                                  │
│  ▸ Fix auth  │                                  │
│  ▸ Add tests │                                  │
│  ▸ Refactor  │                                  │
│              │                                  │
│  ──────────  ├──────────────────────────────────│
│  [search]    │ <footer>                         │
│              │   <form> input </form>            │
└──────────────┴──────────────────────────────────┘
```

### Component Inventory

| Component | Element | Purpose |
|-----------|---------|---------|
| `Sidebar` | `<nav>` | Session list, new session button, search |
| `NewSessionButton` | `<button>` | Creates a new session, optionally with directory picker |
| `SessionList` | `<ul>` | List of saved/active sessions |
| `SessionItem` | `<li>` | Single session entry: title, date, working dir, status indicator |
| `SessionSearch` | `<input type="search">` | Filter sessions by title or working directory |
| `SessionHeader` | `<header>` | Active session title (editable), metadata |
| `DirectoryPicker` | `<dialog>` | Working directory selection for new sessions |
| `BranchMenu` | `<menu>` | Right-click/long-press on a message to branch |
| `DeleteConfirm` | `<dialog>` | Confirm session deletion |

### Session List Item States

```
Active (running):   ● Fix auth bug — ~/projects/myapp — claude-sonnet-4
Active (idle):      ○ Fix auth bug — ~/projects/myapp — claude-sonnet-4
Saved (not loaded): ◇ Add unit tests — ~/projects/other — 2 hours ago
```

## Session Lifecycle

### Creating a New Session

1. User clicks "+ New Session"
2. Optional: directory picker dialog appears
3. Main process calls `createSession({ workingDir })` via SDK
4. New `SessionView` is created in the store
5. Sidebar updates with the new entry
6. Focus switches to the new session

### Resuming a Saved Session

1. User clicks a saved session in the sidebar
2. Main process calls `createSession({ sessionId, workingDir })` — the SDK's `session/start` with `sessionId` tells Opal to load the existing session from DETS
3. Main process calls `session/history` to get conversation history
4. History is replayed into the timeline as static entries (no streaming)
5. Session is now live — user can send new prompts

### Switching Between Active Sessions

1. User clicks a different session in the sidebar
2. `activeSessionId` updates in the store
3. The conversation view switches to show that session's timeline
4. Events from inactive sessions still flow (they just update their respective `SessionView`)
5. Switching is instant — no re-loading needed for active sessions

### Deleting a Session

1. User right-clicks or swipes on a session → "Delete"
2. Confirmation dialog appears
3. On confirm: main process calls `session/delete` RPC, removes from store
4. If it was active, switch to the next available session or show empty state

### Branching

1. User right-clicks (or uses a context menu button on) an assistant message
2. "Branch from here" option appears
3. Main process calls `session/branch` with the message ID
4. Timeline truncates to that point; user can type a new prompt to fork
5. The branch is a new path in the session tree — the original branch remains

## History Replay

When resuming a session, the full message history is loaded and rendered as a static timeline. The format from `session/history` maps directly to timeline entries:

```typescript
function historyToTimeline(messages: HistoryMessage[]): TimelineEntry[] {
  return messages.flatMap((msg) => {
    switch (msg.role) {
      case "user":
        return [{ type: "user", text: msg.content }];
      case "assistant":
        const entries: TimelineEntry[] = [];
        if (msg.content) {
          entries.push({ type: "assistant", text: msg.content, isStreaming: false });
        }
        if (msg.toolCalls) {
          for (const tc of msg.toolCalls) {
            entries.push({
              type: "tool",
              name: tc.name,
              args: tc.arguments,
              output: null, // tool results are separate messages
              status: "done",
            });
          }
        }
        return entries;
      case "tool_result":
        // Match to existing tool entry and fill in output
        return [];
      default:
        return [];
    }
  });
}
```

## Auto-Title Generation

Session titles are generated from the first user prompt. The approach is simple substring extraction — no LLM call needed:

1. Take the first line of the first user message
2. Truncate to 50 characters
3. Use as the session title
4. User can edit the title by clicking on it in the sidebar or header

Titles are persisted in session metadata via `settings/save` or a session-specific mechanism.

## Acceptance Criteria

1. Sidebar displays all saved sessions with title, date, and working directory
2. User can create a new session with an optional directory picker
3. User can resume a saved session and see its full history
4. User can switch between active sessions without losing state
5. Events from background sessions are still processed
6. User can delete sessions with confirmation
7. User can search/filter the session list
8. User can branch a conversation from any assistant message
9. Session titles are auto-generated and editable
10. Empty state is shown when no sessions exist
11. Sidebar is collapsible / resizable
