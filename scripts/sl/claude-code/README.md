# Claude Code on Snow Leopard

Running Claude Code natively on Mac OS X 10.6.8 Snow Leopard (2009).

## What this does

Cross-compiles Node.js 12 on a modern Mac targeting macOS 10.6, bundles it
with a lightweight CLI that talks directly to Anthropic's Messages API, and
packages everything into a self-contained archive you can drop onto a Snow
Leopard machine.

## Quick start

```bash
# 1. Build Node.js 12 for Snow Leopard (~10 min on Apple Silicon)
./build-node12-sl.sh

# 2. Package the bundle
./pack-claude-sl.sh

# 3. Deploy
scp ../../claude-sl-bundle.tar.gz snowleopard:~/
ssh snowleopard 'tar xzf claude-sl-bundle.tar.gz'
ssh snowleopard 'echo "sk-ant-your-key" > ~/.anthropic_key'
ssh snowleopard '~/claude-code/claude -p "hello from Snow Leopard"'
```

## How it works

### The Node.js problem

Snow Leopard's constraints:
- No Node.js installed (max supported: 0.12.x pre-built, 4.x with target 10.5)
- GCC 4.2 / clang 3.0 (no C++14 for building modern Node)
- No `__thread` / `thread_local` (requires macOS 10.7+)
- No `libc++.dylib` (introduced in 10.7)
- System OpenSSL 0.9.8 (TLS 1.0 only)

### The solution: Cross-compile Node 12 with 6 patches

Build Node.js 12.22.12 on a modern Mac with `-mmacosx-version-min=10.6`,
applying these patches:

| # | Patch | Why |
|---|-------|-----|
| 1 | `MACOSX_DEPLOYMENT_TARGET` 10.10 → 10.6 | gyp hardcodes 10.10; we need 10.6 |
| 2 | Suppress `-Wdeprecated-non-prototype`, `-Wenum-constexpr-conversion` | Modern clang errors on old C/C++ patterns in zlib and V8 |
| 3 | Remove zlib `#define fdopen(fd,mode) NULL` | Macro conflicts with SDK's `_stdio.h` fdopen declaration |
| 4 | V8 `THREAD_LOCAL __thread` → empty for 10.6 | `__thread` TLS not supported before macOS 10.7 |
| 5 | V8/Node `thread_local` → `static` | Same TLS issue in wasm-code-manager, torque, node_binding |
| 6 | Static link libc++ from LLVM 15 | Snow Leopard has no `libc++.dylib`; eliminate runtime dependency |

The result: a 43MB x86_64 binary with only two dynamic dependencies
(`libSystem.B.dylib` and `CoreFoundation.framework`), both present on 10.6.

### The CLI problem

Claude Code's bundled `cli.js` (12MB) uses Node 18+ features:
- ESM modules, optional chaining, nullish coalescing, private class fields
- `fetch` via bundled undici (crashes on Node 12 due to Web Streams API gaps)
- `worker_threads`, `diagnostics_channel`, `stream/promises` (Node 14+)
- `Intl.Segmenter`, `structuredClone`, `AbortController` (Node 16-18+)

SWC can transpile the syntax (ESM→CJS in 3 seconds), and polyfill shims
cover most missing APIs. But undici's fetch implementation segfaults on
Node 12's V8 when interacting with the ReadableStream polyfill.

### The solution: Native CLI

Instead of polyfilling the entire Node 18 API surface, `cli-sl.cjs` is a
170-line CLI that talks directly to Anthropic's Messages API using Node's
built-in `https` module. It implements:

- **Agent loop** with tool use (read → execute → respond → repeat)
- **6 tools**: `read_file`, `write_file`, `edit_file`, `bash`, `list_files`, `grep`
- **Interactive REPL** with readline, colors, and `/commands`
- **Print mode** (`-p`) for scripting

No polyfills, no transpilation, no external dependencies.

## Key discoveries

1. **Pre-built Node 4.9.1 runs on 10.6** — its binary targets macOS 10.5.
   Node 6+ targets 10.7+. Useful as a fallback.

2. **TLS to api.anthropic.com works** — Node 12's bundled OpenSSL handles
   the TLS 1.2 handshake. Verified: HTTP 200 from `/v1/messages`.

3. **`-mmacosx-version-min=10.6` still works** on macOS 26 (Tahoe) SDK.
   The compiler accepts it and produces valid 10.6 Mach-O binaries.

4. **Static libc++ from LLVM 15 links cleanly** into a 10.6-targeted
   binary despite being built for 12.6 (linker warns but works).

5. **V8's thread_local removal is safe** for single-threaded CLI use.
   The affected variables (WASM trap handler, torque context, dlerror)
   don't need thread isolation when only one thread runs JS.

## Files

```
scripts/sl/claude-code/
├── build-node12-sl.sh    # Cross-compile Node 12 (run on modern Mac)
├── pack-claude-sl.sh     # Package the bundle
├── cli-sl.cjs            # The Snow Leopard CLI (170 lines)
└── README.md             # This file
```
