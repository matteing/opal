#!/bin/sh
# bootstrap.sh — Build the entire Opal toolchain in-place.
#
# Everything stays inside this directory. Nothing is installed to the
# system, no global commands, no writes to $HOME.
#
#   unzip opal-sl-bundle.zip
#   cd opal-sl-bundle
#   ./bootstrap.sh
#   ./opal
#
# Usage: ./bootstrap.sh [--jobs N] [--force stage[,stage...]]
set -e

# ── Parse arguments ──────────────────────────────────────────────

JOBS=""
FORCE_STAGES=""

append_force_stage() {
  stage="$1"

  case ",$FORCE_STAGES," in
    *,"$stage",*) ;;
    *)
      FORCE_STAGES="${FORCE_STAGES:+$FORCE_STAGES,}$stage"
      ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --jobs)
      [ $# -ge 2 ] || { echo "Missing value for --jobs"; exit 1; }
      JOBS="$2"
      shift 2
      ;;
    --force)
      [ $# -ge 2 ] || { echo "Missing value for --force"; exit 1; }
      FORCE_STAGES="${FORCE_STAGES:+$FORCE_STAGES,}$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [--jobs N] [--force stage[,stage...]]"
      echo "Builds OpenSSL, Erlang/OTP, Elixir, and Opal inside this directory."
      echo "Re-runs reuse cached stage outputs unless you force a rebuild."
      echo "Valid stages: openssl, otp, elixir, opal, all"
      echo "Nothing is installed globally."
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

RAW_FORCE_STAGES="$FORCE_STAGES"
FORCE_STAGES=""

for stage in $(printf '%s' "$RAW_FORCE_STAGES" | tr ',' ' '); do
  [ -n "$stage" ] || continue

  case "$stage" in
    openssl|otp|elixir|opal|all)
      append_force_stage "$stage"
      ;;
    *)
      echo "Unknown stage for --force: $stage"
      exit 1
      ;;
  esac
done

case ",$FORCE_STAGES," in
  *,all,*)
    FORCE_STAGES="all,openssl,otp,elixir,opal"
    ;;
esac

case ",$FORCE_STAGES," in
  *,openssl,*)
    append_force_stage otp
    append_force_stage elixir
    append_force_stage opal
    ;;
esac

case ",$FORCE_STAGES," in
  *,otp,*)
    append_force_stage elixir
    append_force_stage opal
    ;;
esac

case ",$FORCE_STAGES," in
  *,elixir,*)
    append_force_stage opal
    ;;
esac

# ── Resolve paths (everything relative to this script) ───────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SL_SCRIPT_DIR="$SCRIPT_DIR/scripts"
PREFIX="$SCRIPT_DIR/toolchain"
SOURCES="$SCRIPT_DIR/sources"
CERTS="$SCRIPT_DIR/certs"
PATCHES="$SCRIPT_DIR/patches"
OPAL_SRC="$SCRIPT_DIR/opal"
BUILD_LOG="$SCRIPT_DIR/build.log"
VAR_DIR="$SCRIPT_DIR/var"
CACHE_ROOT="$PREFIX/cache"
CACHE_HELPER="$SL_SCRIPT_DIR/cache.sh"

# Keep Hex/Mix state local — never touch ~/.mix or ~/.hex
export MIX_HOME="$PREFIX/mix"
export HEX_HOME="$PREFIX/hex"
export OPAL_DATA_DIR="$VAR_DIR"

export PREFIX SOURCES CERTS PATCHES OPAL_SRC BUILD_LOG VAR_DIR
export FORCE_STAGES SL_SCRIPT_DIR CACHE_ROOT CACHE_HELPER

# ── Banner ───────────────────────────────────────────────────────

echo ""
echo "  ┌───────────────────────────────────────────┐"
echo "  │  ✦ Opal — Snow Leopard Bootstrap          │"
echo "  │                                           │"
echo "  │  Building: OpenSSL → OTP → Elixir → Opal │"
echo "  │  All files stay in this directory.         │"
echo "  └───────────────────────────────────────────┘"
echo ""

# ── Preflight checks ─────────────────────────────────────────────

echo "[1/8] Preflight checks..."

OS_VER=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
echo "  macOS: $OS_VER"

# Compiler
if command -v gcc-4.2 >/dev/null 2>&1; then
  export CC=gcc-4.2
  export CXX=g++-4.2
elif command -v gcc >/dev/null 2>&1; then
  export CC=gcc
  export CXX=g++
elif command -v cc >/dev/null 2>&1; then
  export CC=cc
  export CXX=c++
else
  echo "  ✗ No C compiler found."
  exit 1
fi
echo "  Compiler: $CC"

command -v make >/dev/null 2>&1 || { echo "  ✗ make not found."; exit 1; }
command -v perl >/dev/null 2>&1 || { echo "  ✗ perl not found."; exit 1; }
command -v cksum >/dev/null 2>&1 || { echo "  ✗ cksum not found."; exit 1; }
command -v otool >/dev/null 2>&1 || { echo "  ✗ otool not found."; exit 1; }
command -v install_name_tool >/dev/null 2>&1 || { echo "  ✗ install_name_tool not found."; exit 1; }

# Architecture — detect actual CPU capability, not just what the kernel reports.
# Snow Leopard often boots a 32-bit kernel on 64-bit CPUs (Core 2 Duo).
# OTP's configure auto-detects 64-bit and builds x86_64 in that case, so we
# must ensure OpenSSL and everything else matches.
ARCH=$(uname -m)
case "$ARCH" in
  i486|i586|i686)
    ARCH=i386
    ;;
esac

if [ "$ARCH" = "i386" ] && sysctl -n hw.cpu64bit_capable 2>/dev/null | grep -q 1; then
  ARCH=x86_64
  echo "  CPU is 64-bit capable — building as x86_64"
fi

export ARCH
echo "  Arch: $ARCH"

# Force consistent architecture across all builds
export CFLAGS="-arch $ARCH -O2 -fno-strict-aliasing"
export LDFLAGS="-arch $ARCH"

if [ -z "$JOBS" ]; then
  JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 2)
fi
export JOBS
echo "  Jobs: $JOBS"
if [ -n "$FORCE_STAGES" ]; then
  echo "  Forced rebuilds: $FORCE_STAGES"
fi

for f in "$SOURCES/elixir-1.6.6.tar.gz"; do
  if [ ! -f "$f" ]; then
    echo "  ✗ Missing: $f"
    exit 1
  fi
done

# OpenSSL: OTP 19 on Snow Leopard must use 1.0.2u
if [ ! -f "$SOURCES/openssl-1.0.2u.tar.gz" ]; then
  echo "  ✗ Missing OpenSSL 1.0.2u source tarball"
  exit 1
fi

# OTP: use the official tarball only
if [ ! -f "$SOURCES/otp_src_19.3.tar.gz" ]; then
  echo "  ✗ Missing OTP source tarball"
  exit 1
fi

echo "  ✓ All checks passed"

# ── Create directories ───────────────────────────────────────────

echo ""
echo "[2/8] Setting up..."
mkdir -p "$PREFIX/ssl" "$PREFIX/otp" "$PREFIX/elixir" "$PREFIX/bin" "$PREFIX/src" "$PREFIX/mix" "$PREFIX/hex" "$CACHE_ROOT" "$VAR_DIR"
touch "$BUILD_LOG"
{
  echo ""
  echo "==== bootstrap run ===="
  echo "jobs=$JOBS"
  echo "force=${FORCE_STAGES:-none}"
} >> "$BUILD_LOG"
. "$CACHE_HELPER"

# ── Build OpenSSL ────────────────────────────────────────────────

echo ""
echo "[3/8] Building OpenSSL..."
. "$SL_SCRIPT_DIR/build-openssl.sh"

# Make OpenSSL libs findable for OTP/Elixir builds and runtime
export DYLD_LIBRARY_PATH="$PREFIX/ssl/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
export DYLD_FALLBACK_LIBRARY_PATH="$PREFIX/ssl/lib${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"
export LD_LIBRARY_PATH="$PREFIX/ssl/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# ── Build OTP ────────────────────────────────────────────────────

echo ""
echo "[4/8] Building Erlang/OTP 19.3..."
. "$SL_SCRIPT_DIR/build-otp.sh"

# ── Build Elixir ─────────────────────────────────────────────────

echo ""
echo "[5/8] Building Elixir 1.6.6..."
. "$SL_SCRIPT_DIR/build-elixir.sh"

# ── Build Opal ───────────────────────────────────────────────────

echo ""
echo "[6/8] Compiling Opal..."
. "$SL_SCRIPT_DIR/build-opal.sh"

# ── Create launcher script ──────────────────────────────────────

echo ""
echo "[7/8] Creating launcher..."

cat > "$SCRIPT_DIR/run" << 'EOF'
#!/bin/sh
# Opal — Snow Leopard Edition
# Self-contained. Everything is local to this directory.
BUNDLE="$(cd "$(dirname "$0")" && pwd)"
TC="$BUNDLE/toolchain"
CRYPTO_LIB_DIR=$(find "$TC/otp" -path '*/crypto-*/priv/lib' -type d 2>/dev/null | head -1)
DYLD_PATHS="$TC/ssl/lib"
if [ -n "$CRYPTO_LIB_DIR" ]; then
  DYLD_PATHS="$CRYPTO_LIB_DIR:$DYLD_PATHS"
fi
export PATH="$TC/otp/bin:$TC/elixir/bin:$PATH"
export SSL_CERT_FILE="$BUNDLE/certs/cacert.pem"
export DYLD_LIBRARY_PATH="$DYLD_PATHS${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
export DYLD_FALLBACK_LIBRARY_PATH="$DYLD_PATHS${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"
export LD_LIBRARY_PATH="$DYLD_PATHS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Snow Leopard's system libcrypto.0.9.8 gets loaded before our libcrypto.1.0.0,
# causing OpenSSL symbol conflicts in the crypto NIF init. Pre-loading our
# libcrypto via DYLD_INSERT_LIBRARIES ensures our symbols take priority.
if [ -n "$CRYPTO_LIB_DIR" ] && [ -f "$CRYPTO_LIB_DIR/libcrypto.1.0.0.dylib" ]; then
  export DYLD_INSERT_LIBRARIES="$CRYPTO_LIB_DIR/libcrypto.1.0.0.dylib${DYLD_INSERT_LIBRARIES:+:$DYLD_INSERT_LIBRARIES}"
fi

export MIX_HOME="$TC/mix"
export HEX_HOME="$TC/hex"
export ERL_LIBS="$TC/otp/lib/erlang/lib"
export OPAL_DATA_DIR="$BUNDLE/var"
mkdir -p "$OPAL_DATA_DIR"

if [ ! -f "$TC/bin/opal.escript" ]; then
  echo "Opal escript is missing. Re-run ./bootstrap.sh and inspect build.log." >&2
  exit 1
fi

OPAL_EBIN="$BUNDLE/opal/_build/prod/lib/opal/ebin"
JASON_EBIN="$BUNDLE/opal/_build/prod/lib/jason/ebin"
CONSOLIDATED="$BUNDLE/opal/_build/prod/lib/opal/consolidated"
EX_LIB="$TC/elixir/lib/elixir/lib"

exec "$TC/otp/bin/erl" \
  -pa "$OPAL_EBIN" "$JASON_EBIN" "$CONSOLIDATED" \
  -pa "$EX_LIB/eex/ebin" "$EX_LIB/elixir/ebin" "$EX_LIB/ex_unit/ebin" \
  -pa "$EX_LIB/iex/ebin" "$EX_LIB/logger/ebin" "$EX_LIB/mix/ebin" \
  -noshell -s elixir start_cli \
  -extra -e "Opal.CLI.main(System.argv())" -- "$@"
EOF
chmod +x "$SCRIPT_DIR/run"
echo "  ✓ ./run"

# ── Done ─────────────────────────────────────────────────────────

echo ""
echo "[8/8] Done!"
echo ""
echo "  ┌───────────────────────────────────────────┐"
echo "  │  ✦ Opal built successfully!               │"
echo "  │                                           │"
echo "  │  Run:   ./run                             │"
echo "  │  Help:  ./run --help                      │"
echo "  │                                           │"
echo "  │  Everything is in this folder.             │"
echo "  │  No system files were modified.            │"
echo "  │  Build log: build.log                     │"
echo "  └───────────────────────────────────────────┘"
echo ""
