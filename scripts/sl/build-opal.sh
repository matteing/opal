#!/bin/sh
# build-opal.sh — Compile Opal and build the escript.
#
# Called by bootstrap.sh. Can also be run standalone.
# Expects: $PREFIX, $OPAL_SRC, $SOURCES, $BUILD_LOG
set -e

SL_SCRIPT_DIR="${SL_SCRIPT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
CACHE_HELPER="${CACHE_HELPER:-$SL_SCRIPT_DIR/cache.sh}"
. "$CACHE_HELPER"

OPAL_FINGERPRINT=$(
  {
    cache_emit_value stage opal
    cache_emit_file "$SL_SCRIPT_DIR/build-opal.sh" "build-script"
    cache_emit_file "$CACHE_HELPER" "cache-helper"
    cache_emit_stage_dependency elixir "elixir-stage"
    cache_emit_tree "$OPAL_SRC" "opal-source" mix.exs mix.lock config lib priv deps/jason
  } | cache_digest_stream
)

if stage_forced opal; then
  echo "  Opal rebuild forced."
  cache_reset_stage opal "$OPAL_SRC/_build" "$OPAL_SRC/opal" "$PREFIX/bin/opal.escript"
elif cache_stage_valid opal "$OPAL_FINGERPRINT" "$PREFIX/bin/opal.escript"; then
  echo "  Opal cache hit — skipping."
  return 0 2>/dev/null || exit 0
fi

export PATH="$PREFIX/otp/bin:$PREFIX/elixir/bin:$PATH"
if [ -z "${CRYPTO_LIB_DIR:-}" ]; then
  CRYPTO_LIB_DIR=$(find "$PREFIX/otp" -path '*/crypto-*/priv/lib' -type d 2>/dev/null | head -1)
fi

DYLD_PATHS="$PREFIX/ssl/lib"
if [ -n "${CRYPTO_LIB_DIR:-}" ]; then
  DYLD_PATHS="$CRYPTO_LIB_DIR:$DYLD_PATHS"
fi

export DYLD_LIBRARY_PATH="$DYLD_PATHS${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
export DYLD_FALLBACK_LIBRARY_PATH="$DYLD_PATHS${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"
export LD_LIBRARY_PATH="$DYLD_PATHS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Prevent Snow Leopard's system libcrypto.0.9.8 from conflicting with ours
if [ -n "${CRYPTO_LIB_DIR:-}" ] && [ -f "$CRYPTO_LIB_DIR/libcrypto.1.0.0.dylib" ]; then
  export DYLD_INSERT_LIBRARIES="$CRYPTO_LIB_DIR/libcrypto.1.0.0.dylib${DYLD_INSERT_LIBRARIES:+:$DYLD_INSERT_LIBRARIES}"
fi

export MIX_ENV=prod
export MIX_HOME="${MIX_HOME:-$PREFIX/mix}"

cd "$OPAL_SRC"

# ── Install Hex offline ──────────────────────────────────────────
# Mix needs Hex to resolve dep metadata. We bundle Hex 0.21.3 (the last
# version supporting Elixir 1.6) as an .ez archive in sources/.
echo "  Installing Hex (offline)..."
HEX_EZ=$(find "$SOURCES" -name "hex-*.ez" -type f 2>/dev/null | head -1)
if [ -n "$HEX_EZ" ]; then
  if ! "$PREFIX/elixir/bin/mix" archive.install "$HEX_EZ" --force >> "$BUILD_LOG" 2>&1; then
    echo "  ✗ Hex install failed. Last 30 lines:"
    tail -30 "$BUILD_LOG"
    exit 1
  fi
  echo "  ✓ Hex installed from $(basename "$HEX_EZ")"
else
  echo "  ✗ No Hex .ez archive found in sources/. Add hex-0.21.3.ez."
  exit 1
fi

# ── Compile dependencies ─────────────────────────────────────────

echo "  Compiling dependencies..."

if [ -f "deps/jason/mix.exs" ]; then
  if ! "$PREFIX/elixir/bin/mix" deps.compile >> "$BUILD_LOG" 2>&1; then
    echo "  ✗ Dependency compile failed. Last 60 lines:"
    tail -60 "$BUILD_LOG"
    exit 1
  fi
else
  echo "  ✗ Missing vendored dependency deps/jason."
  exit 1
fi

echo "  ✓ Dependencies compiled"

# ── Compile Opal ─────────────────────────────────────────────────

echo "  Compiling Opal..."
if ! "$PREFIX/elixir/bin/mix" compile >> "$BUILD_LOG" 2>&1; then
  echo "  ✗ Opal compile failed. Last 60 lines:"
  tail -60 "$BUILD_LOG"
  exit 1
fi
echo "  ✓ Opal compiled"

# ── Build escript ────────────────────────────────────────────────

echo "  Building escript..."
if ! "$PREFIX/elixir/bin/mix" escript.build >> "$BUILD_LOG" 2>&1; then
  echo "  ✗ Escript build failed. Last 60 lines:"
  tail -60 "$BUILD_LOG"
  exit 1
fi

if [ -f "opal" ]; then
  mkdir -p "$PREFIX/bin"
  cp opal "$PREFIX/bin/opal.escript"
  echo "  ✓ Escript → toolchain/bin/opal.escript"
  cache_mark_stage opal "$OPAL_FINGERPRINT"
else
  echo "  ✗ Escript not produced. Last 60 lines:"
  tail -60 "$BUILD_LOG"
  exit 1
fi
