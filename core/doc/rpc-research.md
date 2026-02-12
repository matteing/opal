# RPC Layer Research: Opal Server ↔ TypeScript/Ink CLI

> Date: 2026-02-06
> Context: Opal is an OTP-native coding agent harness. We want to ship it as a
> headless binary (via Burrito/Mix releases) that a TypeScript/Ink CLI spawns or
> connects to. The RPC layer must support streaming tokens, request/response,
> and server-initiated requests (e.g. "ask the user for confirmation").

---

## Requirements Matrix

| Requirement                      | Weight | Notes                                                               |
| -------------------------------- | ------ | ------------------------------------------------------------------- |
| Streaming (LLM token deltas)     | ★★★    | Sub-10ms latency for smooth TUI; potentially hundreds of events/sec |
| Request/Response (prompt, abort) | ★★★    | Standard RPC calls                                                  |
| Server → Client requests (bidir) | ★★★    | Server asks frontend for confirmation, file picks, etc              |
| Cross-platform (mac/linux/win)   | ★★★    | Must work on all three from day one (per ARCHITECTURE.md)           |
| Distribution simplicity          | ★★★    | Single Opal binary + `npx opal` via npm                             |
| Implementation effort            | ★★☆    | Small team, must ship fast                                          |
| Language-agnostic protocol       | ★★☆    | Future SDKs in Python, Go, etc                                      |
| Existing library ecosystem       | ★★☆    | Battle-tested libs on both sides                                    |
| Debuggability                    | ★☆☆    | Being able to inspect the wire format easily                        |

---

## Approach Comparison

### A. JSON-RPC 2.0 over stdio

**How it works:** The TS CLI spawns the Opal binary as a child process. Both
sides read/write newline-delimited JSON-RPC messages on stdin/stdout. This is
exactly how LSP and MCP work.

**Elixir side:**

- Anubis MCP (`~> 0.17`) already implements JSON-RPC 2.0 over stdio, including
  a full transport layer with framing. Opal already depends on it.
- Could reuse Anubis's `STDIO` transport directly or extract its framing logic.
- Alternatively, a bare GenServer reading `:stdio` is ~100 lines of code.

**TypeScript side:**

- `vscode-jsonrpc` (6.4M weekly downloads) — the exact library VS Code uses
  for LSP. Has `StreamMessageReader`/`StreamMessageWriter` for child process
  stdio. Built-in support for requests, responses, notifications, and progress.
- `json-rpc-2.0` (400K weekly downloads) — lighter, transport-agnostic,
  supports `JSONRPCServerAndClient` for bidirectional communication.
- `@anthropic-ai/sdk` and all MCP client SDKs use this pattern.

**Streaming model:** Server sends JSON-RPC _notifications_ for each token
delta (no response expected). Client sends a request to start a prompt, and
the server streams results as notifications until a final response.

```
Client → Server:  {"jsonrpc":"2.0","id":1,"method":"prompt","params":{"text":"Fix the bug"}}
Server → Client:  {"jsonrpc":"2.0","method":"token","params":{"delta":"I"}}
Server → Client:  {"jsonrpc":"2.0","method":"token","params":{"delta":"'ll"}}
Server → Client:  {"jsonrpc":"2.0","method":"token","params":{"delta":" look"}}
...
Server → Client:  {"jsonrpc":"2.0","id":1,"result":{"status":"complete"}}
```

**Bidirectional:** Server sends a _request_ (with `id`) to the client:

```
Server → Client:  {"jsonrpc":"2.0","id":"s1","method":"confirm","params":{"question":"Delete file?"}}
Client → Server:  {"jsonrpc":"2.0","id":"s1","result":{"confirmed":true}}
```

| Dimension             | Assessment                                                                        |
| --------------------- | --------------------------------------------------------------------------------- |
| Streaming latency     | ★★★ Excellent — direct pipe, no HTTP overhead, no TCP handshake                   |
| Bidirectional         | ★★★ Native — both sides can send requests and notifications                       |
| Cross-platform        | ★★★ stdin/stdout works everywhere                                                 |
| Implementation effort | ★★★ Minimal — Anubis already has the transport; `vscode-jsonrpc` is battle-tested |
| Distribution          | ★★★ Best — TS spawns binary, no ports/addresses to manage                         |
| Language-agnostic     | ★★★ JSON-RPC 2.0 is a published spec, any language can implement                  |
| Multiple clients      | ★☆☆ Only one client per process (the parent)                                      |
| Debuggability         | ★★☆ Can log/tee the pipe; but interleaving with stderr needed for debug output    |
| Existing art          | ★★★ LSP, MCP, Copilot, Claude Code all use this exact pattern                     |

**Pros:**

- Zero network configuration — no ports, no addresses, no TLS
- Process lifecycle is automatic — kill parent, child dies (with proper signal handling)
- Opal already has Anubis MCP with stdio transport, so the framing layer is proven
- The MCP ecosystem (which Opal participates in) speaks this protocol
- `vscode-jsonrpc` is the most battle-tested JSON-RPC-over-stdio lib in existence
- Single binary distribution is trivially simple

**Cons:**

- Single client only — can't attach a second frontend or a web UI to the same server
- stdout must be reserved for protocol messages (all logging → stderr)
- Can't easily connect to an already-running Opal process (would need a separate mechanism)
- Process management on Windows requires care (no SIGTERM, need to handle differently)

---

### B. gRPC with Protobuf

**How it works:** Opal starts a gRPC server on a TCP port. The TS CLI connects
as a gRPC client. Messages use Protocol Buffers for serialization.

**Elixir side:**

- `elixir-grpc/grpc` package (~0.11.5) — active, supports server and client
  streaming, bidirectional streaming. 10 dependencies including `cowboy`, `gun`,
  `protobuf`. Well-maintained with regular releases.
- Requires a `.proto` file and code generation step.

**TypeScript side:**

- `@grpc/grpc-js` (25M weekly downloads) — pure JS, no native deps.
- `@grpc/proto-loader` for dynamic loading or `grpc-tools` for codegen.
- Full streaming support (server streaming, client streaming, bidirectional).

**Streaming model:** Server streaming RPC — client calls `Prompt()`, server
streams back `TokenDelta` messages.

```protobuf
service OpalAgent {
  rpc Prompt(PromptRequest) returns (stream AgentEvent);
  rpc Abort(AbortRequest) returns (AbortResponse);
  rpc GetState(StateRequest) returns (StateResponse);
  // Bidir for confirmations
  rpc Session(stream ClientMessage) returns (stream ServerMessage);
}
```

| Dimension             | Assessment                                                         |
| --------------------- | ------------------------------------------------------------------ |
| Streaming latency     | ★★★ Excellent — HTTP/2 streams, binary framing                     |
| Bidirectional         | ★★★ Native bidirectional streaming                                 |
| Cross-platform        | ★★★ HTTP/2 over TCP works everywhere                               |
| Implementation effort | ★★☆ More setup — proto files, codegen, dependency weight           |
| Distribution          | ★★☆ Need port allocation, connection management, process lifecycle |
| Language-agnostic     | ★★★ Best — proto files ARE the contract, codegen for any language  |
| Multiple clients      | ★★★ Any number of clients can connect                              |
| Debuggability         | ★☆☆ Binary protocol; need special tools (grpcurl, Bloom)           |
| Existing art          | ★★☆ Common in microservices, rare in CLI-to-backend IPC            |

**Pros:**

- Strongest typing story — proto files generate types for both Elixir and TS
- True bidirectional streaming is a first-class concept
- Multiple clients can connect simultaneously
- Best option for future multi-language SDK support
- Binary protocol means smaller messages and lower parsing overhead

**Cons:**

- Significant complexity tax: proto files, codegen pipelines, build tooling
- Heavy dependency tree on Elixir side (cowboy, gun, protobuf, flow, etc.)
- Port allocation and management (need to find free port, communicate it)
- Process lifecycle management is now your problem (need a way to start/stop server)
- Overkill for a 1:1 CLI-to-backend relationship
- gRPC on Elixir is less battle-tested than in Go/Java ecosystems
- Burrito binary + gRPC server adds complexity to distribution
- HTTP/2 requirement can cause issues with some proxies/environments

---

### C. WebSocket

**How it works:** Opal starts an HTTP server with a WebSocket endpoint. The
TS CLI connects via WS. Messages are JSON (or could be msgpack).

**Elixir side:**

- `Phoenix.Socket` / `Phoenix.Channel` — but pulling in Phoenix for IPC is heavy
- `WebSockex` (client) or `Cowboy`/`Bandit` directly for server
- `Bandit` (~> 1.0) is lightweight and would be reasonable
- Could use `Plug` + `WebSock` adapter pattern

**TypeScript side:**

- `ws` package (100M+ weekly downloads) — the standard WebSocket library
- Native `WebSocket` in Node.js 21+ (built-in, no deps)
- Can layer JSON-RPC 2.0 on top of WebSocket transport

| Dimension             | Assessment                                                  |
| --------------------- | ----------------------------------------------------------- |
| Streaming latency     | ★★★ Excellent — persistent connection, frame-level messages |
| Bidirectional         | ★★★ Native — WebSocket is inherently bidirectional          |
| Cross-platform        | ★★★ TCP-based, works everywhere                             |
| Implementation effort | ★★☆ Need HTTP server setup, WS upgrade, message framing     |
| Distribution          | ★★☆ Same port-management issues as gRPC                     |
| Language-agnostic     | ★★★ WebSocket is universal; can use JSON-RPC on top         |
| Multiple clients      | ★★★ Multiple connections supported                          |
| Debuggability         | ★★☆ JSON messages are readable; browser devtools work       |
| Existing art          | ★★☆ Common pattern but not standard for CLI IPC             |

**Pros:**

- Inherently bidirectional with low overhead
- Can layer JSON-RPC 2.0 on top (same message format as option A, different transport)
- Could potentially serve a web frontend too (future Opal web UI)
- Well-understood technology

**Cons:**

- Requires an HTTP server in Opal (Cowboy/Bandit + Plug dependency)
- Port allocation problem (find free port, communicate it to CLI)
- Connection lifecycle management (reconnection logic, health checks)
- More moving parts than stdio for a 1:1 relationship
- Starting an HTTP server inside a Burrito binary adds complexity
- Not a natural fit for "spawn a child process" distribution model

---

### D. HTTP + Server-Sent Events (SSE)

**How it works:** Opal starts an HTTP server. TS CLI sends commands via POST
requests and receives streaming events via an SSE connection.

**Elixir side:**

- `Plug` + `Bandit`/`Cowboy` for HTTP
- SSE is just `text/event-stream` — chunked transfer encoding
- Anubis MCP already supports SSE transport (though deprecated in favor of
  Streamable HTTP in MCP spec 2025-03-26)

**TypeScript side:**

- `eventsource` or `EventSource` (built-in in Node.js 22+)
- `fetch` for POST requests
- Well-established pattern from web development

| Dimension             | Assessment                                                          |
| --------------------- | ------------------------------------------------------------------- |
| Streaming latency     | ★★☆ Good — but HTTP overhead per request; SSE is one-way            |
| Bidirectional         | ★☆☆ SSE is server→client only; need separate POST for client→server |
| Cross-platform        | ★★★ HTTP works everywhere                                           |
| Implementation effort | ★★☆ Need HTTP server, SSE endpoint, request routing                 |
| Distribution          | ★★☆ Port management required                                        |
| Language-agnostic     | ★★★ HTTP + SSE are universal                                        |
| Multiple clients      | ★★★ Any number of clients                                           |
| Debuggability         | ★★★ Best — curl, browser, any HTTP tool                             |
| Existing art          | ★★☆ MCP used this (now deprecated); OpenAI streaming API uses it    |

**Pros:**

- Very debuggable — can test with curl
- Well-understood HTTP semantics
- SSE reconnection is built into the spec
- Anubis already has SSE transport code

**Cons:**

- **Not truly bidirectional** — SSE is server→client only. For server-initiated
  requests (confirmations), you'd need polling or a second channel
- Two separate mechanisms (HTTP POST + SSE) instead of one unified channel
- Port management required
- Higher latency than stdio (HTTP overhead, TCP setup)
- MCP spec itself deprecated SSE in favor of Streamable HTTP
- Awkward for the "server asks client a question" pattern — would need to
  embed questions in the SSE stream and have the client POST answers back

---

### E. Custom Binary Protocol over Unix Domain Sockets / Named Pipes

**How it works:** Opal listens on a Unix domain socket (or named pipe on
Windows). Custom binary framing for messages.

**Elixir side:**

- `:gen_tcp` with `{:local, path}` for Unix sockets
- Custom framing (length-prefixed messages, msgpack or custom binary format)
- No existing high-level library — all custom code

**TypeScript side:**

- `net.connect` with `path` option for Unix sockets
- Custom framing to match

| Dimension             | Assessment                                                            |
| --------------------- | --------------------------------------------------------------------- |
| Streaming latency     | ★★★ Best possible — no HTTP overhead, kernel-level IPC                |
| Bidirectional         | ★★★ Full duplex socket                                                |
| Cross-platform        | ★★☆ Unix sockets on mac/linux; named pipes on Windows (different API) |
| Implementation effort | ★☆☆ All custom — framing, error handling, reconnection                |
| Distribution          | ★★☆ Need socket file path management                                  |
| Language-agnostic     | ★☆☆ Custom protocol = every SDK reimplements from scratch             |
| Multiple clients      | ★★☆ Possible but need connection management                           |
| Debuggability         | ★☆☆ Custom binary format = custom debug tools needed                  |
| Existing art          | ★☆☆ Docker does this, but few CLI tools do                            |

**Pros:**

- Absolute lowest latency possible for IPC
- No port allocation (filesystem paths instead)
- File-system permissions for access control

**Cons:**

- **Massive implementation effort** for dubious latency gains (the bottleneck
  is the LLM API, not local IPC)
- Cross-platform nightmare — Unix domain sockets and Windows named pipes have
  different APIs, semantics, and path formats
- Every future SDK must reimplement the binary protocol from scratch
- No standard tooling for debugging
- Fragile socket file cleanup (crashes leave stale files)
- Premature optimization — JSON-RPC over stdio is already faster than the
  LLM network latency by orders of magnitude

---

### F. JSON-RPC 2.0 over stdio with Notifications (LSP/MCP Pattern)

**How it works:** Same as (A), but explicitly designed around the notification
pattern that LSP and MCP use. This is the fully-realized version of (A).

**This is option A made concrete**, with an explicit protocol design:

```
── Lifecycle ──
Client → Server:  initialize        (request)
Server → Client:  initialized       (notification)
Client → Server:  shutdown           (request)

── Agent Operations ──
Client → Server:  agent/prompt       (request → streams notifications → final response)
Client → Server:  agent/abort        (request)
Client → Server:  agent/getState     (request)
Client → Server:  agent/steer        (notification)

── Streaming (server → client notifications) ──
Server → Client:  agent/event        (notification: token_delta, tool_start, tool_end, etc.)

── Bidirectional (server asks client) ──
Server → Client:  client/confirm     (request — server sends, client responds)
Server → Client:  client/selectFile  (request)
Server → Client:  client/input       (request)

── Session Management ──
Client → Server:  session/list       (request)
Client → Server:  session/resume     (request)
Client → Server:  session/branch     (request)
```

**This maps 1:1 to Opal's existing event system:**

- `Opal.Events.broadcast(session_id, {:token, delta})` → `agent/event` notification
- `Opal.Agent.prompt(pid, text)` → `agent/prompt` request
- `Opal.Agent.abort(pid)` → `agent/abort` request
- `Opal.Agent.steer(pid, text)` → `agent/steer` notification

**Elixir implementation sketch:**

```elixir
defmodule Opal.RPC.Stdio do
  @moduledoc "JSON-RPC 2.0 over stdio transport for headless Opal server"
  use GenServer

  # Reads newline-delimited JSON from stdin, dispatches to handler
  # Writes JSON-RPC responses/notifications to stdout
  # All logging goes to stderr

  # Can reuse Anubis.Transport.STDIO framing or implement the
  # ~100 lines of Content-Length header parsing (LSP-style)
end
```

**TypeScript implementation sketch:**

```typescript
import {
  createMessageConnection,
  StreamMessageReader,
  StreamMessageWriter,
} from "vscode-jsonrpc/node";

const opal = spawn("./opal-server", [], { stdio: ["pipe", "pipe", "inherit"] });
const conn = createMessageConnection(
  new StreamMessageReader(opal.stdout),
  new StreamMessageWriter(opal.stdin),
);

// Handle server → client requests
conn.onRequest("client/confirm", async (params) => {
  const answer = await renderConfirmDialog(params.question);
  return { confirmed: answer };
});

// Handle streaming notifications
conn.onNotification("agent/event", (event) => {
  renderEvent(event); // Update Ink UI
});

// Send a prompt
const result = await conn.sendRequest("agent/prompt", { text: "Fix the bug" });
```

| Dimension             | Assessment                                            |
| --------------------- | ----------------------------------------------------- |
| Streaming latency     | ★★★ Excellent — direct pipe, zero overhead            |
| Bidirectional         | ★★★ Both sides can send requests AND notifications    |
| Cross-platform        | ★★★ stdin/stdout is universal                         |
| Implementation effort | ★★★ Minimal — proven pattern, proven libraries        |
| Distribution          | ★★★ Best — TS spawns binary, done                     |
| Language-agnostic     | ★★★ JSON-RPC 2.0 spec + a protocol doc = any language |
| Multiple clients      | ★☆☆ One client per process                            |
| Debuggability         | ★★☆ JSON is readable; can tee stdio for debugging     |
| Existing art          | ★★★ LSP, MCP, DAP all work this way                   |

**(Same pros/cons as A, but the protocol design is explicit and documented.)**

---

## Comparison Table

| Criterion                  | A/F: JSON-RPC stdio | B: gRPC | C: WebSocket | D: HTTP+SSE | E: Custom UDS |
| -------------------------- | ------------------- | ------- | ------------ | ----------- | ------------- |
| **Streaming latency**      | ★★★                 | ★★★     | ★★★          | ★★☆         | ★★★           |
| **Bidirectional**          | ★★★                 | ★★★     | ★★★          | ★☆☆         | ★★★           |
| **Cross-platform**         | ★★★                 | ★★★     | ★★★          | ★★★         | ★★☆           |
| **Impl effort**            | ★★★                 | ★★☆     | ★★☆          | ★★☆         | ★☆☆           |
| **Distribution**           | ★★★                 | ★★☆     | ★★☆          | ★★☆         | ★★☆           |
| **Multi-language**         | ★★★                 | ★★★     | ★★★          | ★★★         | ★☆☆           |
| **Multiple clients**       | ★☆☆                 | ★★★     | ★★★          | ★★★         | ★★☆           |
| **Debuggability**          | ★★☆                 | ★☆☆     | ★★☆          | ★★★         | ★☆☆           |
| **Lib ecosystem**          | ★★★                 | ★★☆     | ★★★          | ★★☆         | ★☆☆           |
| **Existing Opal affinity** | ★★★                 | ★☆☆     | ★☆☆          | ★★☆         | ★☆☆           |
| **Total**                  | **28**              | **22**  | **23**       | **21**      | **16**        |

---

## Recommendation: **F — JSON-RPC 2.0 over stdio (LSP/MCP Pattern)**

### Why This Wins

1. **You already use this pattern.** Anubis MCP is a JSON-RPC 2.0 library with
   stdio transport that's already in your dependency tree. The framing,
   serialization, and error handling are solved problems.

2. **Distribution is trivial.** The TS CLI does `spawn('./opal-server')` and
   talks over pipes. No ports, no addresses, no firewall rules, no TLS
   certificates. The binary is fully self-contained. This is the same model
   as `typescript-language-server`, `elixir-ls`, `rust-analyzer`, and every
   MCP server.

3. **Bidirectional is native.** JSON-RPC 2.0 explicitly supports requests in
   both directions plus fire-and-forget notifications. The
   `client/confirm` pattern (server asks client a question) is exactly how
   LSP's `window/showMessageRequest` works — proven at massive scale.

4. **Streaming maps naturally.** LLM token deltas become notifications
   (`agent/event`). This is the exact pattern Claude Code, Copilot Chat, and
   every LSP implementation uses for progress reporting. No SSE, no
   WebSocket, no special streaming mechanism — just notifications on the pipe.

5. **Cross-platform is automatic.** stdin/stdout works identically on macOS,
   Linux, and Windows. No Unix socket vs named pipe divergence. No port
   conflicts. Opal's ARCHITECTURE.md mandates cross-platform from day one.

6. **Future SDKs are easy.** The protocol is a JSON-RPC 2.0 spec document.
   Anyone can implement a client in Python, Go, Rust, whatever. The same
   `.md` file that describes your protocol is your SDK documentation.

7. **Implementation is minimal.** Elixir side: a GenServer that reads
   stdin, dispatches JSON-RPC methods to `Opal.Agent` calls, subscribes to
   `Opal.Events`, and writes notifications to stdout. ~200-400 lines. TS side:
   `vscode-jsonrpc` does all the hard work.

### The "Multiple Clients" Objection

The only real weakness is single-client-per-process. But consider:

- **This is the right constraint for a CLI.** One terminal = one agent. If the
  user wants two agents, they spawn two processes. OTP already isolates them.
- **A future web UI can use a different transport.** Nothing stops you from
  adding a WebSocket transport _later_ that exposes the same JSON-RPC protocol
  over WS instead of stdio. The protocol layer is the same; only the transport
  changes. Anubis MCP already demonstrates this (stdio + streamable_http +
  SSE transports for the same protocol).
- **You can add a "connect to running instance" mode later** by having the Opal
  process also listen on a Unix socket or TCP port as a secondary transport.
  But ship stdio first.

### Suggested Architecture

```
┌─────────────────────────────────────────────────────────┐
│  TypeScript/Ink CLI (npm package)                       │
│                                                         │
│  ┌──────────────────────────────────────────────┐       │
│  │  vscode-jsonrpc                              │       │
│  │  StreamMessageReader ← child.stdout          │       │
│  │  StreamMessageWriter → child.stdin           │       │
│  └──────────────────────────────────────────────┘       │
│                                                         │
│  • Renders TUI with Ink                                 │
│  • Handles server requests (confirm, input, etc.)       │
│  • Spawns opal binary as child process                  │
└──────────────────────┬──────────────────────────────────┘
                       │ stdio (stdin/stdout)
                       │ JSON-RPC 2.0
                       │ Content-Length headers (LSP framing)
┌──────────────────────┴──────────────────────────────────┐
│  Opal Server Binary (Mix release / Burrito)             │
│                                                         │
│  ┌──────────────────────────────────────────────┐       │
│  │  Opal.RPC.Stdio (GenServer)                  │       │
│  │  • Reads JSON-RPC from stdin                 │       │
│  │  • Dispatches to Opal.Agent / Opal.Session   │       │
│  │  • Subscribes to Opal.Events                 │       │
│  │  • Writes notifications/responses to stdout  │       │
│  └──────────────────────────────────────────────┘       │
│                                                         │
│  ┌──────────────────────────────────────────────┐       │
│  │  Opal core (unchanged)                       │       │
│  │  Agent, Session, Events, Tools, MCP, etc.    │       │
│  └──────────────────────────────────────────────┘       │
│                                                         │
│  stderr → logging (piped to CLI for debug mode)         │
└─────────────────────────────────────────────────────────┘
```

### Key Implementation Notes

1. **Use LSP-style Content-Length framing**, not newline-delimited JSON.
   This is what `vscode-jsonrpc` expects and what LSP/DAP use. It handles
   messages containing newlines correctly.

   ```
   Content-Length: 52\r\n
   \r\n
   {"jsonrpc":"2.0","method":"agent/event","params":{}}
   ```

2. **Logger goes to stderr.** Configure Elixir's Logger backend to write to
   stderr so it doesn't corrupt the JSON-RPC stream. The TS CLI can pipe
   stderr to a log file or display it in debug mode.

3. **Reuse Anubis framing if possible.** Anubis's STDIO transport already
   handles Content-Length parsing and serialization. Evaluate whether it can
   be used directly or if its framing module can be extracted.

4. **Define the protocol in a spec document.** Write an `OPAL-RPC.md` that
   lists every method, its params schema, and its result schema. This becomes
   the contract for any future SDK.

5. **Future transport upgrade path:** If you later need multi-client support
   (web UI, IDE plugin), add a WebSocket or Streamable HTTP transport that
   speaks the same JSON-RPC protocol. The `Opal.RPC.Handler` module dispatches
   methods to the Opal core; it doesn't care about the transport.

### Libraries to Use

| Side   | Library          | Purpose                                |
| ------ | ---------------- | -------------------------------------- |
| Elixir | `anubis_mcp`     | JSON-RPC 2.0 framing (already a dep)   |
| Elixir | `jason`          | JSON encoding/decoding (already a dep) |
| TS     | `vscode-jsonrpc` | JSON-RPC over stdio (6.4M DL/week)     |
| TS     | `ink`            | Terminal UI framework                  |
| TS     | (none extra)     | child_process.spawn is built-in        |

### What NOT to Build

- ❌ Don't build a custom binary protocol. JSON parsing is not your bottleneck.
- ❌ Don't add gRPC. The proto/codegen overhead isn't justified for 1:1 IPC.
- ❌ Don't start with WebSocket. You can always add it later as a second transport.
- ❌ Don't use HTTP+SSE. It can't do server→client requests cleanly.
- ❌ Don't use newline-delimited JSON. Use Content-Length framing for robustness.
