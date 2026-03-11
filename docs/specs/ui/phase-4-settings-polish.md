# Phase 4 — Settings & Polish

> Settings panel, model picker, auth flows, keyboard shortcuts, and runtime configuration.

## Goal

Complete feature parity with the Opal CLI by adding all the configuration, authentication, and quality-of-life features that make the app feel production-ready. This phase brings over every CLI feature that wasn't covered in earlier phases.

## Prerequisites

- Phase 3 complete (rich tool experience works)

## Scope

### In Scope

- Settings panel (persistent user preferences)
- Model picker dialog (interactive model + thinking level selection)
- Authentication flows (device-code OAuth, API key entry)
- Runtime configuration (toggle features/tools mid-session)
- Keyboard shortcuts (full set matching CLI)
- Slash commands (via input prefix)
- Conversation compaction (manual trigger + usage bar)
- Plan viewer (open plan.md in an external editor or inline)
- JSON-RPC debug panel (toggleable inspector)
- Working directory display and change
- Version information display
- Auto-confirm mode toggle
- Welcome/onboarding screen for first launch

### Out of Scope

- Scheduling (Phase 5)

## Settings Panel

A dedicated settings view accessible from the sidebar or a gear icon. Settings persist to `~/.opal/settings.json` via the `settings/save` RPC.

### Settings Categories

```
┌─ Settings ────────────────────────────────────┐
│                                                │
│ Model                                          │
│ ┌────────────────────────────────────────────┐ │
│ │ Default model: [claude-sonnet-4       ▾]   │ │
│ │ Thinking level: [medium               ▾]   │ │
│ └────────────────────────────────────────────┘ │
│                                                │
│ Behavior                                       │
│ ┌────────────────────────────────────────────┐ │
│ │ ☐ Auto-confirm tool executions             │ │
│ │ ☑ Show thinking text                       │ │
│ │ ☑ Show tool output by default              │ │
│ └────────────────────────────────────────────┘ │
│                                                │
│ Features                                       │
│ ┌────────────────────────────────────────────┐ │
│ │ ☑ Sub-agents                               │ │
│ │ ☑ Skills                                   │ │
│ │ ☐ Debug introspection                      │ │
│ └────────────────────────────────────────────┘ │
│                                                │
│ Authentication                                 │
│ ┌────────────────────────────────────────────┐ │
│ │ GitHub Copilot: ✓ Authenticated            │ │
│ │ [Re-authenticate] [Logout]                 │ │
│ └────────────────────────────────────────────┘ │
│                                                │
│ About                                          │
│ ┌────────────────────────────────────────────┐ │
│ │ Opal Desktop v0.1.0                        │ │
│ │ Opal Server v0.x.x                         │ │
│ │ Protocol v1                                │ │
│ └────────────────────────────────────────────┘ │
│                                                │
│            [Save]  [Cancel]                    │
└────────────────────────────────────────────────┘
```

### Settings State

```typescript
interface Settings {
  defaultModel: string;
  thinkingLevel: "none" | "low" | "medium" | "high";
  autoConfirm: boolean;
  showThinking: boolean;
  showToolOutput: boolean;
  features: {
    subAgents: boolean;
    skills: boolean;
    debug: boolean;
  };
}
```

Settings are loaded on app start via `settings/get` and saved via `settings/save`. Changes to model/features take effect on the next session start, or immediately via `model/set` and `opal/config/set` for the active session.

## Model Picker

An interactive dialog for selecting the model and thinking level, triggered by a keyboard shortcut, slash command, or clicking the model name in the header.

```
┌─ Select Model ────────────────────────────────┐
│                                                │
│ Search: [                                   ]  │
│                                                │
│ Claude                                         │
│   ● claude-opus-4.6          200k  thinking ✓  │
│   ○ claude-sonnet-4.5        200k  thinking ✓  │
│   ○ claude-sonnet-4          200k  thinking ✓  │
│   ○ claude-haiku-4.5         200k  thinking ✓  │
│                                                │
│ GPT                                            │
│   ○ gpt-5                    200k              │
│   ○ gpt-4.1                  128k              │
│                                                │
│ Gemini                                         │
│   ○ gemini-3-pro             1M                │
│                                                │
│ ─────────────────────────────────────────────  │
│ Thinking level: [○ none ○ low ● medium ○ high] │
│                                                │
│              [Select]  [Cancel]                 │
└────────────────────────────────────────────────┘
```

- Model list from `models/list` RPC
- Grouped by provider/family
- Context window size displayed
- Thinking capability indicated
- Thinking level selector (radio buttons)
- Search/filter by name
- Selected model applied via `model/set` + `thinking/set` RPCs

## Authentication

### First-Launch Flow

On first launch (no auth token found), the app shows a setup wizard:

```
┌─ Welcome to Opal Desktop ─────────────────────┐
│                                                │
│  ✦ Opal                                       │
│                                                │
│  To get started, authenticate with             │
│  GitHub Copilot.                               │
│                                                │
│  ┌──────────────────────────────────────────┐  │
│  │                                          │  │
│  │  1. Go to: https://github.com/login/     │  │
│  │     device                               │  │
│  │                                          │  │
│  │  2. Enter code: ABCD-1234     [Copy]     │  │
│  │                                          │  │
│  │  Waiting for authorization...  ◌         │  │
│  │                                          │  │
│  └──────────────────────────────────────────┘  │
│                                                │
│  Or enter an API key:                          │
│  [                                        ]    │
│  [Submit API Key]                              │
│                                                │
└────────────────────────────────────────────────┘
```

### Auth Flow Implementation

1. App calls `auth/status` on startup
2. If not authenticated, show setup wizard
3. Device flow: call `auth/login` → get `userCode` + `verificationUri`
4. Display code, open verification URL in browser
5. Poll with `auth/poll` until authorized
6. On success, dismiss wizard, proceed to main UI

### Re-authentication

Available from the Settings panel. Same flow as first-launch but in a dialog instead of full-screen.

## Runtime Configuration

The Opal menu (matching CLI's `/opal` command) allows toggling features and tools mid-session:

```
┌─ Runtime Configuration ───────────────────────┐
│                                                │
│ Features                                       │
│   ☑ Sub-agents                                 │
│   ☑ Skills                                     │
│   ☐ Debug introspection                        │
│                                                │
│ Tools                                          │
│   ☑ read_file                                  │
│   ☑ edit_file                                  │
│   ☑ write_file                                 │
│   ☑ grep                                       │
│   ☑ shell                                      │
│   ☑ sub_agent                                  │
│   ☑ tasks                                      │
│   ☑ use_skill                                  │
│   ☑ ask_user                                   │
│   ☐ debug_state                                │
│                                                │
│                              [Apply] [Cancel]  │
└────────────────────────────────────────────────┘
```

Changes are applied via `opal/config/set` RPC and take effect on the next agent turn.

## Keyboard Shortcuts

| Shortcut | Context | Action |
|----------|---------|--------|
| `Cmd/Ctrl+N` | Any | New session |
| `Cmd/Ctrl+W` | Any | Close current session |
| `Cmd/Ctrl+,` | Any | Open settings |
| `Cmd/Ctrl+K` | Any | Model picker |
| `Cmd/Ctrl+L` | Idle | Clear conversation display |
| `Cmd/Ctrl+.` | Running | Abort agent |
| `Cmd/Ctrl+Shift+C` | Any | Copy last response |
| `Cmd/Ctrl+Y` | Any | Open plan in editor |
| `Cmd/Ctrl+D` | Any | Toggle debug panel |
| `Cmd/Ctrl+[` / `]` | Any | Previous / next session |
| `Enter` | Input focused | Send prompt |
| `Shift+Enter` | Input focused | New line |
| `Escape` | Dialog open | Dismiss dialog |
| `Up` | Input empty | Recall last prompt |

### Slash Commands

Typed into the input area, processed before sending as a prompt:

| Command | Action |
|---------|--------|
| `/help` | Show command list |
| `/model` | Show or change model |
| `/models` | Open model picker |
| `/compact` | Trigger conversation compaction |
| `/agents` | List or switch sub-agent views |
| `/opal` | Open runtime config |
| `/debug` | Toggle debug panel |
| `/clear` | Clear conversation display |
| `/new` | New session |

## Compaction UI

The token usage bar in the header doubles as a compaction indicator:

```
Header: ... claude-sonnet-4 · [████████░░] 82% (164k/200k)
```

- Under 60%: no indicator (or subtle)
- 60–80%: yellow/warning color
- 80%+: red, auto-compaction may trigger
- Manual compaction via `/compact` or a button in the header
- During compaction, show a brief status: "Compacting conversation..."

## Debug Panel

A toggleable panel (bottom drawer or side panel) showing JSON-RPC traffic:

```
┌─ Debug Panel ─────────────────────────────────┐
│ → session/start {workingDir: "/project"}       │
│ ← session/start {sessionId: "abc", ...}        │
│ → agent/prompt {text: "fix the test"}          │
│ ← agent/event {type: "agentStart"}             │
│ ← agent/event {type: "messageDelta", ...}      │
│ ← agent/event {type: "toolExecutionStart",...}  │
│ ...                                            │
│ [Clear]  [Filter: ______]  [Auto-scroll: ☑]   │
└────────────────────────────────────────────────┘
```

- Shows all JSON-RPC messages (requests, responses, notifications)
- Filterable by method or event type
- Expandable rows to see full JSON payload
- Auto-scroll toggle
- Timestamp on each entry

## Plan Viewer

`Ctrl+Y` / `Cmd+Y` opens the session's `plan.md`:

1. Check if `<session_dir>/plan.md` exists
2. If yes: open in the user's default editor (same logic as CLI — `$VISUAL` → `$EDITOR` → platform default)
3. If no: show a brief notification "No plan created yet"

Future enhancement: inline plan viewer within the app, but external editor is the Phase 4 approach for simplicity.

## Component Inventory (New)

| Component | Purpose |
|-----------|---------|
| `SettingsPanel` | Full settings view with form controls |
| `ModelPicker` | Interactive model/thinking selection dialog |
| `AuthWizard` | First-launch and re-auth device code flow |
| `RuntimeConfig` | Feature/tool toggles for the active session |
| `DebugPanel` | JSON-RPC traffic inspector |
| `TokenBar` | Usage bar with compaction warning colors |
| `ShortcutOverlay` | Keyboard shortcut reference sheet |
| `CommandPalette` | Slash command processing in input area |

## IPC Extensions

```typescript
// New IPC handlers for Phase 4 (all namespaced under opal:)
ipcMain.handle("opal:models:list", () => session.models());
ipcMain.handle("opal:model:set", (_, id, thinkingLevel?) => session.setModel(id, thinkingLevel));
ipcMain.handle("opal:thinking:set", (_, level) => session.setThinking(level));
ipcMain.handle("opal:auth:status", () => session.auth_.status());
ipcMain.handle("opal:auth:login", () => session.auth_.login());
ipcMain.handle("opal:auth:poll", (_, deviceCode, interval) => session.auth_.poll(deviceCode, interval));
ipcMain.handle("opal:settings:get", () => session.config.getSettings());
ipcMain.handle("opal:settings:save", (_, settings) => session.config.saveSettings(settings));
ipcMain.handle("opal:config:get", () => session.config.getRuntime());
ipcMain.handle("opal:config:set", (_, config) => session.config.setRuntime(config));
ipcMain.handle("opal:session:compact", () => session.compact());
ipcMain.handle("opal:version", () => session.version());
```

## Acceptance Criteria

1. Settings panel allows configuring all user preferences
2. Settings persist across app restarts
3. Model picker shows all available models with metadata
4. Model and thinking level can be changed mid-session
5. Auth wizard appears on first launch if not authenticated
6. Device-code flow completes successfully
7. API key entry works as an alternative auth method
8. Runtime features/tools can be toggled mid-session
9. All keyboard shortcuts work as specified
10. Slash commands are processed correctly
11. Token usage bar shows context utilization with color coding
12. Manual compaction can be triggered
13. Debug panel shows JSON-RPC traffic
14. Plan viewer opens plan.md in external editor
15. Version information is displayed in settings
