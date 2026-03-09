#!/bin/sh
# build-elixir.sh — Build Elixir 1.6.6 for Snow Leopard.
#
# Called by bootstrap.sh. Can also be run standalone.
# Expects: $PREFIX, $JOBS, $SOURCES, $BUILD_LOG
set -e

SL_SCRIPT_DIR="${SL_SCRIPT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
CACHE_HELPER="${CACHE_HELPER:-$SL_SCRIPT_DIR/cache.sh}"
. "$CACHE_HELPER"

ELIXIR_FINGERPRINT=$(
  {
    cache_emit_value stage elixir
    cache_emit_file "$SL_SCRIPT_DIR/build-elixir.sh" "build-script"
    cache_emit_file "$CACHE_HELPER" "cache-helper"
    cache_emit_file "$SOURCES/elixir-1.6.6.tar.gz" "elixir-source"
    cache_emit_stage_dependency otp "otp-stage"
  } | cache_digest_stream
)

if stage_forced elixir; then
  echo "  Elixir rebuild forced."
  cache_reset_stage elixir "$PREFIX/elixir" "$PREFIX/src/elixir-1.6.6"
elif cache_stage_valid elixir "$ELIXIR_FINGERPRINT" "$PREFIX/elixir/bin/elixir" "$PREFIX/elixir/bin/mix"; then
  echo "  Elixir cache hit — skipping."
  return 0 2>/dev/null || exit 0
else
  cache_reset_stage elixir "$PREFIX/elixir" "$PREFIX/src/elixir-1.6.6"
fi

echo "  Extracting Elixir 1.6.6..."
mkdir -p "$PREFIX/src"
mkdir -p "$PREFIX/elixir"
cd "$PREFIX/src"
gzip -dc "$SOURCES/elixir-1.6.6.tar.gz" | tar xf -

cd elixir-1.6.6

# Elixir needs our OTP on PATH and our OpenSSL libs findable
export PATH="$PREFIX/otp/bin:$PATH"
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

# Replace the bundled R16B-era rebar with a shim that uses erlc/yecc directly.
# The old rebar escript can't load OTP 19's crypto NIF, but all it does for
# Elixir's build is compile .yrl and .erl files — no crypto needed.
cat > rebar << 'REBAR_SHIM'
#!/bin/sh
# rebar shim — replaces the R16B rebar escript for OTP 19 compatibility.
# Only supports the "compile" command (all Elixir's Makefile needs).
case "$1" in
  compile)
    mkdir -p ebin
    for yrl in src/*.yrl; do
      [ -f "$yrl" ] || continue
      erlc -o src "$yrl"
    done
    for xrl in src/*.xrl; do
      [ -f "$xrl" ] || continue
      erlc -o src "$xrl"
    done
    erlc -o ebin \
      +debug_info \
      +warn_unused_vars +warn_export_all +warn_shadow_vars \
      +warn_unused_import +warn_unused_function +warn_bif_clash \
      +warn_unused_record +warn_deprecated_function +warn_obsolete_guard \
      +warn_exported_vars \
      src/*.erl
    # Copy .app.src → .app (rebar normally does variable substitution,
    # but Elixir's app.src uses no substitution variables)
    for appsrc in src/*.app.src; do
      [ -f "$appsrc" ] || continue
      cp "$appsrc" "ebin/$(basename "$appsrc" .app.src).app"
    done
    ;;
  clean)
    rm -rf ebin
    ;;
  *)
    echo "rebar shim: unsupported command '$1'" >&2
    exit 1
    ;;
esac
REBAR_SHIM
chmod +x rebar
echo "  Replaced bundled rebar with OTP 19 compatible shim"

echo "  Compiling Elixir (this takes 3-5 minutes)..."
if ! make >> "$BUILD_LOG" 2>&1; then
  echo "  ✗ Elixir build failed. Last 60 lines:"
  tail -60 "$BUILD_LOG"
  exit 1
fi

echo "  Installing Elixir..."
if ! make install PREFIX="$PREFIX/elixir" >> "$BUILD_LOG" 2>&1; then
  echo "  ✗ Elixir install failed. Last 60 lines:"
  tail -60 "$BUILD_LOG"
  exit 1
fi

# Verify
ELIXIR_VER=$("$PREFIX/elixir/bin/elixir" -e 'IO.puts(System.version())' 2>/dev/null) || true
if [ -n "$ELIXIR_VER" ]; then
  echo "  ✓ Elixir $ELIXIR_VER"
  cache_mark_stage elixir "$ELIXIR_FINGERPRINT"
else
  echo "  ✗ Elixir build failed. Check $BUILD_LOG"
  exit 1
fi
