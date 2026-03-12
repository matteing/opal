# Opal UI App Specification - Quick Start

## What You Need to Know

The Opal project is a **multi-layered agent harness** designed to separate concerns cleanly:

```
CLI Frontend (TypeScript/Ink React)
        ↓ JSON-RPC 2.0 over stdin/stdout
Server Backend (Elixir/OTP)
        ↓ OTP Message Passing (internal)
Agent Loop (gen_statem State Machine)
        ↓ Supervised Tasks
Tool Execution & Streaming
```

This separation means you can **replace just the UI layer** while reusing the battle-tested backend.

---

## For UI App Specification - Start Here

### 1. Protocol Definition (Source of Truth)
**File**: `/Users/sergio/Projects/2026/opal/opal/lib/opal/rpc/protocol.ex` (927 lines)

This file declaratively defines:
- **22 Client→Server RPC methods** (session, model, auth, tools, config)
- **3 Server→Client request methods** (confirmations, input)
- **15+ event types** (streaming, tool execution, sub-agents)

**Why it matters**: All types are auto-generated into TypeScript (`cli/src/sdk/protocol.ts`). You can extend it by modifying this file and regenerating.

### 2. Current CLI State Management
**File**: `/Users/sergio/Projects/2026/opal/cli/src/state/store.ts` (80 lines)

Uses **Zustand with 5 slices**:
- `session.ts` — SDK connection lifecycle
- `timeline.ts` — Event reducer + agents map (root + sub-agents)
- `models.ts` — Model listing & selection
- `auth.ts` — Device-code OAuth state machine
- `debug.ts` — RPC message log, stderr capture

**Key Pattern**: Pure event reducer (`applyEvent(state, event) → state`) for testing.

### 3. Communication Protocol
**File**: `/Users/sergio/Projects/2026/opal/docs/rpc.md` (135 lines)

Wire format: **newline-delimited JSON-RPC 2.0** (like LSP)

Example:
```json
→ {"jsonrpc":"2.0","method":"session/start","params":{"working_dir":"."},"id":1}
← {"jsonrpc":"2.0","result":{"session_id":"abc123","session_dir":"~/.opal/sessions/abc123"},"id":1}
← {"jsonrpc":"2.0","method":"agent/event","params":{"session_id":"abc123","type":"message_delta","delta":"Hello"}}
```

### 4. Agent Loop Architecture
**File**: `/Users/sergio/Projects/2026/opal/docs/agent-loop.md` (128 lines)

`:gen_statem` with 4 states:
```
idle → running → streaming → executing_tools → (back to running) → idle
```

**For UI**: You just need to render events. The loop handles all complexity:
- Streaming SSE chunks
- Tool execution (concurrent + supervised)
- Retry/backoff
- Sub-agent spawning
- Context overflow recovery

### 5. Event Stream (What Your UI Renders)
Events flow as notifications on `agent/event`:

| Event | Payload | Rendering |
|-------|---------|-----------|
| `agent_start` | — | Show spinner |
| `message_delta` | text chunk | Stream to message area |
| `thinking_delta` | text chunk | Show thinking block |
| `tool_execution_start` | tool, args | Show tool card + spinner |
| `tool_execution_end` | tool, result | Show result |
| `status_update` | message, level | Show status bar |
| `sub_agent_event` | inner event | Route to sub-agent timeline |
| `usage_update` | tokens, context_window | Show token counter |
| `agent_end` | messages, usage | Show complete state |

### 6. Session & Sub-Agent Model
**Key Concepts**:

**Sessions**: Persistent conversation trees (ETS in-memory + DETS on disk)
- Can be branched at any message
- Can be resumed via session ID
- Context files auto-discovered
- Skills auto-discovered

**Sub-Agents**: OTP processes spawned by `sub_agent` tool
- Each has own timeline
- Each has own model + tools
- Can be viewed in separate tab
- Depth-limited to prevent recursion

**UI Challenge**: Show root agent + all active sub-agents simultaneously

**Solution** (current CLI): Focus stack with tab switching
- Root agent always visible in tabs
- Drill into sub-agents with `/agents <id>` or tab click
- Auto-pop focus when sub-agent completes

You could also render all in splitscreen if desired.

### 7. Integration Points for Your UI

1. **Server Lifecycle**: Spawn `opal-server` or connect to running instance
   - Resolve binary: dev mode (mise exec) → PATH → bundled binary
   - Handle server crashes gracefully

2. **Session Start**: `session/start` RPC
   - Pass `working_dir`, optional `model`, optional `session_id` (to resume)
   - Get back: session_id, session_dir, context_files, available_skills

3. **Prompt Submission**: `agent/prompt` RPC
   - Returns `{queued: bool}` immediately
   - Events arrive as notifications

4. **Event Subscription**: Listen on `agent/event` notifications
   - Events are batched by default (32ms window) in CLI
   - You might coalesce differently for web/desktop

5. **User Interactions**:
   - Model selection: `/model/set` RPC
   - Authentication: `auth/login` + `auth/poll` RPC
   - Abort: `agent/abort` RPC
   - Tool approval: Respond to `client/confirm` request

6. **Configuration**: `opal/config/get` and `opal/config/set` RPC
   - Toggle sub-agents, skills, debug mode
   - Enable/disable specific tools

---

## File Reference for Specification

### Must-Read
- `OPAL_UI_EXPLORATION.md` (1,855 lines) — This comprehensive report
- `docs/rpc.md` — Protocol specification (135 lines)
- `docs/cli.md` — Current CLI architecture (237 lines)
- `docs/sdk.md` — TypeScript SDK docs (276 lines)

### Implementation Reference
- `opal/lib/opal/rpc/protocol.ex` (927 lines) — Protocol source of truth
- `cli/src/state/store.ts` (80 lines) — State management pattern
- `cli/src/state/timeline.ts` — Event reducer (pure)
- `cli/src/sdk/client.ts` — JSON-RPC client implementation
- `cli/src/app.tsx` (42 lines) — Main layout component

### Backend Architecture
- `opal/lib/opal.ex` (275 lines) — Main API
- `opal/lib/opal/agent/agent.ex` (631 lines) — State machine
- `opal/lib/opal/session/server.ex` (150+ lines) — Per-session supervision tree
- `opal/lib/opal/tool/` (10 tool implementations)
- `opal/lib/opal/provider/copilot.ex` (400+ lines) — LLM provider

---

## Design Patterns You Should Adopt

### 1. Pure Event Reducer
```ts
function applyEvent(state: State, event: AgentEvent): State {
  // Functional update, no side effects
  // Testable in isolation
  // Can be replayed/debugged
  return newState;
}
```

### 2. Normalized Agent Map
```ts
interface Store {
  agents: Record<string, AgentView>;    // "root", "sub-123", "sub-456"
  focusStack: string[];                 // ["root", "sub-123"]
  
  focusAgent(id: string): void;         // push
  focusBack(): void;                    // pop
}

// Components always read from focused agent
const { entries, isRunning } = useActiveAgent();
```

### 3. RPC Client Wrapper
```ts
class OpalClient {
  request<M>(method: M, params: MethodParams<M>): Promise<MethodResult<M>> {
    // Type-safe, inferred from protocol
    // Handles request ID correlation
    // Manages timeouts
  }
  
  onEvent(handler: (event: AgentEvent) => void): void {
    // Subscription for streaming events
  }
  
  addServerMethod(method: string, handler: (params) => Promise<result>): void {
    // Handle server→client requests (confirmations, input)
  }
}
```

### 4. Event Batching
```ts
// Coalesce streaming deltas in a time window (32ms)
// Flush immediately on terminal events
const terminal = [
  "agentEnd", "agentAbort", "error",
  "toolExecutionEnd", "usageUpdate"
];
```

---

## Quick Checklist for UI App Spec

- [ ] Define supported platforms (web/desktop/mobile)
- [ ] Choose state management library (Zustand, Redux, Jotai, Context, etc.)
- [ ] Decide server handling (spawn subprocess, remote connection, both)
- [ ] Design screen layouts (conversation, model picker, auth, settings)
- [ ] Plan component hierarchy (timeline, input, model selector, etc.)
- [ ] Handle sub-agent visualization (tabs, splitscreen, nested?)
- [ ] Plan tool approval UI (modal, inline, popup?)
- [ ] Handle streaming text rendering (character-by-character, chunked?)
- [ ] Plan keyboard shortcuts (abort, clear, send, etc.)
- [ ] Design theme/styling approach
- [ ] Plan error handling & recovery
- [ ] Plan offline/recovery (handle server crashes)

---

## What's Already Built (Reusable)

✅ **Agent Loop** — Don't rebuild this. Use as-is via RPC.
✅ **Tool System** — Already sandboxed and tested. Add custom tools in Elixir.
✅ **Provider System** — Copilot works great. Easy to add new providers.
✅ **Session Persistence** — DETS handles tree + branching.
✅ **Authentication** — Device-code OAuth fully implemented.
✅ **Event System** — Registry-based pub/sub, all metrics included.

✍️ **What You Build** — Just the UI layer on top of JSON-RPC.

---

## Next Steps

1. **Read** `OPAL_UI_EXPLORATION.md` (comprehensive reference)
2. **Study** `opal/lib/opal/rpc/protocol.ex` (understand the API surface)
3. **Review** current CLI state management (`cli/src/state/`)
4. **Sketch** your UI component hierarchy
5. **Plan** state management approach
6. **Implement** JSON-RPC client (or wrap existing)
7. **Build** components incrementally
8. **Test** against running Opal server

---

## Support & Questions

- **Elixir Docs**: Mix tasks, config, Opal.start_session() API
- **TypeScript Docs**: SDK classes, protocol types, event matching
- **Protocol Spec**: `docs/rpc.md` + auto-generated types in `cli/src/sdk/protocol.ts`
- **Source Code**: Clean, well-documented Elixir + TypeScript
- **Examples**: Current CLI (`cli/src/`) is a complete working example

Good luck! 🚀
