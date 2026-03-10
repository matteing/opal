#!/bin/bash
set -euo pipefail

# build-node12-sl.sh — Cross-compile Node.js 12.22.12 for macOS 10.6 Snow Leopard
#
# Run on a modern Mac (Apple Silicon or Intel). Produces a statically-linked
# x86_64 Node binary targeting macOS 10.6 with no libc++ runtime dependency.
#
# Key patches applied:
#   1. MACOSX_DEPLOYMENT_TARGET 10.10 → 10.6
#   2. zlib fdopen macro removal (conflicts with modern SDK headers)
#   3. V8 THREAD_LOCAL → empty (macOS 10.6 has no __thread support)
#   4. V8/Node thread_local → static (safe for single-threaded CLI use)
#   5. Warning suppression for modern clang compatibility
#   6. Static libc++ linking via LLVM 15 pre-built archive

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${BUILD_DIR:-/tmp/claude-sl-node-build}"
NODE_VERSION="12.22.12"
LLVM_VERSION="15.0.7"
JOBS="${JOBS:-8}"

echo "=== Building Node.js ${NODE_VERSION} for macOS 10.6 Snow Leopard ==="
mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR"

# ── Step 1: Download sources ───────────────────────────────────────────────
echo "[1/6] Downloading sources..."
if [ ! -f "node-v${NODE_VERSION}.tar.gz" ]; then
  curl -#Lo "node-v${NODE_VERSION}.tar.gz" \
    "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}.tar.gz"
fi
if [ ! -d "lib" ] || [ ! -f "lib/libc++.a" ]; then
  echo "  Downloading LLVM ${LLVM_VERSION} for static libc++..."
  curl -#Lo "llvm.tar.xz" \
    "https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/clang+llvm-${LLVM_VERSION}-x86_64-apple-darwin21.0.tar.xz"
  mkdir -p lib
  tar xf llvm.tar.xz --include '*/lib/libc++.a' --include '*/lib/libc++abi.a' --strip-components=1
  rm -f llvm.tar.xz
  echo "  Extracted libc++.a ($(du -h lib/libc++.a | cut -f1)) and libc++abi.a"
fi

# ── Step 2: Extract and patch Node.js ──────────────────────────────────────
echo "[2/6] Extracting and patching Node.js..."
rm -rf "node-v${NODE_VERSION}"
tar xzf "node-v${NODE_VERSION}.tar.gz"
cd "node-v${NODE_VERSION}"

# Patch 1: Target macOS 10.6 instead of 10.10
sed -i '' "s/'MACOSX_DEPLOYMENT_TARGET': '10.10'/'MACOSX_DEPLOYMENT_TARGET': '10.6'/" common.gypi

# Patch 2: Suppress warnings that modern clang promotes to errors
#   - deprecated-non-prototype: zlib uses K&R function definitions
#   - enum-constexpr-conversion: V8 intentional out-of-range enum cast
sed -i '' "s|'-Wall', '-Wextra', '-Wno-unused-parameter',|'-Wall', '-Wextra', '-Wno-unused-parameter', '-Wno-deprecated-non-prototype',|g" common.gypi
sed -i '' "s|'-fno-rtti', '-fno-exceptions', '-std=gnu++1y'|'-fno-rtti', '-fno-exceptions', '-std=gnu++1y', '-Wno-enum-constexpr-conversion'|g" common.gypi
sed -i '' "s|'WARNING_CFLAGS': \[|'WARNING_CFLAGS': [ '-Wno-enum-constexpr-conversion', '-Wno-deprecated-non-prototype',|" common.gypi

# Patch 3: zlib fdopen macro — conflicts with modern SDK's _stdio.h
#   zutil.h defines `#define fdopen(fd,mode) NULL` for TARGET_OS_MAC,
#   which expands inside _stdio.h's fdopen prototype, causing a syntax error.
sed -i '' '/^#        define fdopen(fd,mode) NULL/d' deps/zlib/zutil.h

# Patch 4: V8 THREAD_LOCAL — macOS 10.6 doesn't support __thread keyword
#   Replace with empty (falls back to regular storage; safe for single-threaded use)
sed -i '' 's/^#define THREAD_LOCAL __thread/#if defined(__APPLE__) \&\& __ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__ < 1070\
#define THREAD_LOCAL\
#else\
#define THREAD_LOCAL __thread\
#endif/' deps/v8/src/trap-handler/trap-handler.h

# Patch 5: V8 and Node thread_local → static
#   wasm-code-manager, torque contextual, and node_binding all use thread_local
#   which requires 10.7+. Replace with static (single-threaded CLI is safe).
sed -i '' 's/thread_local WasmCodeRefScope\*/static WasmCodeRefScope*/' deps/v8/src/wasm/wasm-code-manager.cc
sed -i '' 's/static thread_local/static/' deps/v8/src/torque/contextual.h
sed -i '' 's/static thread_local std::string dlerror_storage;/static std::string dlerror_storage;/' src/node_binding.cc
sed -i '' 's/static thread_local node_module\* thread_local_modpending;/static node_module* thread_local_modpending;/' src/node_binding.cc

# Patch 6: Fix configure shim for Python 3
sed -i '' 's|exec python |exec python3 |g' configure

echo "  Applied 6 patches"

# ── Step 3: Configure ──────────────────────────────────────────────────────
echo "[3/6] Configuring..."
export CC="clang -arch x86_64"
export CXX="clang++ -arch x86_64"
export CC_host="clang"
export CXX_host="clang++"
export LDFLAGS="-mmacosx-version-min=10.6 -arch x86_64 -nostdlib++ ${BUILD_DIR}/lib/libc++.a ${BUILD_DIR}/lib/libc++abi.a"

python3 configure.py \
  --dest-cpu=x64 \
  --dest-os=mac \
  --with-intl=small-icu \
  --without-inspector \
  --without-dtrace \
  --without-etw \
  --without-npm \
  --openssl-no-asm \
  2>&1 | tail -3

# ── Step 4: Build ─────────────────────────────────────────────────────────
echo "[4/6] Building (this takes ~10 minutes on Apple Silicon)..."
make -j"$JOBS" 2>&1 | tail -3

# ── Step 5: Verify ────────────────────────────────────────────────────────
echo "[5/6] Verifying..."
BINARY="out/Release/node"
if [ ! -f "$BINARY" ]; then
  echo "ERROR: Build failed — no binary produced" >&2
  exit 1
fi

# Check deployment target
TARGET=$(otool -l "$BINARY" | grep -A2 'LC_VERSION_MIN' | grep 'version' | head -1 | awk '{print $2}')
if [ "$TARGET" != "10.6" ]; then
  echo "WARNING: Binary targets macOS $TARGET, expected 10.6" >&2
fi

# Check no libc++ dynamic dependency
if otool -L "$BINARY" | grep -q 'libc++'; then
  echo "WARNING: Binary has dynamic libc++ dependency" >&2
fi

echo "  Binary: $(ls -lh "$BINARY" | awk '{print $5}')"
echo "  Target: macOS $TARGET"
echo "  Arch:   $(file "$BINARY" | grep -o 'x86_64')"
echo "  Dylibs: $(otool -L "$BINARY" | tail -n +2 | wc -l | tr -d ' ')"
./"$BINARY" -e "console.log('  Node:', process.version)"

# ── Step 6: Output ────────────────────────────────────────────────────────
OUTPUT="${SCRIPT_DIR}/node12-snowleopard"
cp "$BINARY" "$OUTPUT"
chmod +x "$OUTPUT"
echo "[6/6] Binary ready at: $OUTPUT"
