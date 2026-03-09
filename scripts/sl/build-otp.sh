#!/bin/sh
# build-otp.sh — Build Erlang/OTP 19.3 for Snow Leopard.
#
# Called by bootstrap.sh. Can also be run standalone.
# Expects: $PREFIX, $ARCH, $CC, $JOBS, $SOURCES, $BUILD_LOG
set -e

SL_SCRIPT_DIR="${SL_SCRIPT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
CACHE_HELPER="${CACHE_HELPER:-$SL_SCRIPT_DIR/cache.sh}"
. "$CACHE_HELPER"

log_macho_info() {
  path="$1"

  [ -e "$path" ] || return 0

  echo "== file $path ==" >> "$BUILD_LOG"
  file "$path" >> "$BUILD_LOG" 2>&1 || true
  echo "== otool -L $path ==" >> "$BUILD_LOG"
  otool -L "$path" >> "$BUILD_LOG" 2>&1 || true
}

rewrite_install_id() {
  target="$1"
  new_id="$2"

  echo "== install_name_tool -id $new_id $target ==" >> "$BUILD_LOG"
  install_name_tool -id "$new_id" "$target" >> "$BUILD_LOG" 2>&1
}

rewrite_install_dep() {
  target="$1"
  old_dep="$2"
  new_dep="$3"

  [ "$old_dep" = "$new_dep" ] && return 0

  echo "== install_name_tool -change $old_dep $new_dep $target ==" >> "$BUILD_LOG"
  install_name_tool -change "$old_dep" "$new_dep" "$target" >> "$BUILD_LOG" 2>&1
}

OTP_FINGERPRINT=$(
  {
    cache_emit_value stage otp
    cache_emit_value arch "$ARCH"
    cache_emit_value cc "$CC"
    cache_emit_value cflags "${CFLAGS:-}"
    cache_emit_value ldflags "${LDFLAGS:-}"
    cache_emit_file "$SL_SCRIPT_DIR/build-otp.sh" "build-script"
    cache_emit_file "$CACHE_HELPER" "cache-helper"
    cache_emit_file "$SOURCES/otp_src_19.3.tar.gz" "otp-source"
    cache_emit_tree "$PATCHES" "patches" .
    cache_emit_stage_dependency openssl "openssl-stage"
  } | cache_digest_stream
)

if stage_forced otp; then
  echo "  OTP rebuild forced."
  cache_reset_stage otp "$PREFIX/otp" "$PREFIX/src/otp_src_19.3" "$PREFIX/src/otp-OTP-19.3.6.13"
elif cache_stage_valid otp "$OTP_FINGERPRINT" "$PREFIX/otp/bin/erl" "$PREFIX/otp/bin/escript"; then
  echo "  OTP cache hit — skipping."
  CRYPTO_LIB_DIR=$(find "$PREFIX/otp" -path '*/crypto-*/priv/lib' -type d 2>/dev/null | head -1)
  export CRYPTO_LIB_DIR
  return 0 2>/dev/null || exit 0
else
  cache_reset_stage otp "$PREFIX/otp" "$PREFIX/src/otp_src_19.3" "$PREFIX/src/otp-OTP-19.3.6.13"
fi

echo "  Extracting OTP source..."
mkdir -p "$PREFIX/src"
mkdir -p "$PREFIX/otp"
cd "$PREFIX/src"

# Try official tarball first (has pre-generated configure)
if [ -f "$SOURCES/otp_src_19.3.tar.gz" ]; then
  gzip -dc "$SOURCES/otp_src_19.3.tar.gz" | tar xf -
  cd otp_src_19.3
elif [ -f "$SOURCES/otp-19.3.6.13.tar.gz" ]; then
  gzip -dc "$SOURCES/otp-19.3.6.13.tar.gz" | tar xf -
  cd otp-OTP-19.3.6.13
  if [ ! -f configure ]; then
    echo "  Running otp_build autoconf..."
    ./otp_build autoconf >> "$BUILD_LOG" 2>&1
  fi
else
  echo "  ✗ No OTP source tarball found"
  exit 1
fi

export ERL_TOP="$(pwd)"

# Apply any patches
if [ -d "$PATCHES" ] && ls "$PATCHES"/otp*.patch >/dev/null 2>&1; then
  echo "  Applying patches..."
  for p in "$PATCHES"/otp*.patch; do
    patch -p1 < "$p" >> "$BUILD_LOG" 2>&1
    echo "    Applied $(basename "$p")"
  done
fi

# Configure — must be run from ERL_TOP
# Give install_name_tool enough header space to rewrite Mach-O load commands
# after install. Snow Leopard does not reliably honor rpath for bundled libs.
echo "  Configuring OTP..."
echo "  (watch progress: tail -f build.log)"

SSL_LIB="$PREFIX/ssl/lib"
ORIG_LDFLAGS="${LDFLAGS:-}"
export LDFLAGS="$ORIG_LDFLAGS -L$SSL_LIB -Wl,-headerpad_max_install_names"
export CFLAGS="${CFLAGS:-} -I$PREFIX/ssl/include"

./configure \
  --prefix="$PREFIX/otp" \
  --with-ssl="$PREFIX/ssl" \
  --without-javac \
  --without-wx \
  --without-observer \
  --without-et \
  --without-debugger \
  --without-megaco \
  --without-snmp \
  --without-diameter \
  --without-odbc \
  --disable-hipe \
  --without-termcap \
  >> "$BUILD_LOG" 2>&1

LDFLAGS="$ORIG_LDFLAGS"

if [ $? -ne 0 ]; then
  echo "  ✗ Configure failed. Last 30 lines:"
  tail -30 "$BUILD_LOG"
  exit 1
fi

echo "  ✓ Configure complete"

# Check that config.h was generated
if [ ! -f "$ERL_TOP/erts/$(uname -m)-apple-darwin$(uname -r | cut -d. -f1)/config.h" ]; then
  # Try to find it wherever it ended up
  CONFIG_H=$(find "$ERL_TOP/erts" -name "config.h" -not -name "*.h.in" 2>/dev/null | head -1)
  if [ -z "$CONFIG_H" ]; then
    echo "  ✗ config.h not generated. Configure may have failed silently."
    echo "  Last 30 lines of build.log:"
    tail -30 "$BUILD_LOG"
    exit 1
  else
    echo "  ✓ config.h found at: $CONFIG_H"
  fi
fi

# Build — do NOT use -j for first build (dependency issues on old make)
echo "  Compiling OTP (this takes 20-40 minutes)..."
make >> "$BUILD_LOG" 2>&1

if [ $? -ne 0 ]; then
  echo "  ✗ Make failed. Last 30 lines:"
  tail -30 "$BUILD_LOG"
  exit 1
fi

echo "  Installing OTP..."
make install >> "$BUILD_LOG" 2>&1

# Bundle OpenSSL dylibs next to OTP's crypto libraries and rewrite every Mach-O
# in that directory to use @loader_path. Failing here is far more actionable
# than letting Elixir die later with a generic crypto loader error.
echo "  Bundling OpenSSL dylibs for crypto NIF..."
CRYPTO_LIB_DIR=$(find "$PREFIX/otp" -path '*/crypto-*/priv/lib' -type d 2>/dev/null | head -1)
if [ -z "$CRYPTO_LIB_DIR" ]; then
  echo "  ✗ Could not locate OTP crypto priv/lib directory"
  exit 1
fi

export CRYPTO_LIB_DIR
SSL_LIB_FIX="$PREFIX/ssl/lib"

# Copy only real dylib files (not symlinks) to avoid duplicate processing.
# Then recreate the unversioned symlinks in the target directory.
for src in "$SSL_LIB_FIX"/libcrypto*.dylib "$SSL_LIB_FIX"/libssl*.dylib; do
  [ -e "$src" ] || continue
  [ -L "$src" ] && continue
  cp -f "$src" "$CRYPTO_LIB_DIR"/
done

# Recreate convenience symlinks (e.g. libcrypto.dylib -> libcrypto.1.0.0.dylib)
for src in "$SSL_LIB_FIX"/libcrypto.dylib "$SSL_LIB_FIX"/libssl.dylib; do
  [ -L "$src" ] || continue
  real=$(basename "$(readlink "$src")")
  link=$(basename "$src")
  if [ -f "$CRYPTO_LIB_DIR/$real" ]; then
    ln -sf "$real" "$CRYPTO_LIB_DIR/$link"
  fi
done

# Make all copied dylibs writable — install_name_tool needs write access
# and OpenSSL's make install_sw installs them 0444.
chmod u+w "$CRYPTO_LIB_DIR"/libcrypto*.dylib "$CRYPTO_LIB_DIR"/libssl*.dylib 2>/dev/null || true
chmod u+w "$CRYPTO_LIB_DIR"/crypto*.so 2>/dev/null || true

# Log what we're about to rewrite
{
  echo ""
  echo "==== Pre-rewrite dylib state ===="
  echo "CRYPTO_LIB_DIR=$CRYPTO_LIB_DIR"
  ls -la "$CRYPTO_LIB_DIR"/ 2>&1 || true
} >> "$BUILD_LOG"

for dylib in "$CRYPTO_LIB_DIR"/libcrypto*.dylib "$CRYPTO_LIB_DIR"/libssl*.dylib; do
  [ -f "$dylib" ] || continue
  [ -L "$dylib" ] && continue
  rewrite_install_id "$dylib" "@loader_path/$(basename "$dylib")"
done

for target in "$CRYPTO_LIB_DIR"/crypto*.so "$CRYPTO_LIB_DIR"/libcrypto*.dylib "$CRYPTO_LIB_DIR"/libssl*.dylib; do
  [ -f "$target" ] || continue
  [ -L "$target" ] && continue

  LINKED_LIBS=$(otool -L "$target" 2>/dev/null | awk '/^[[:space:]]/ && /lib(crypto|ssl).*dylib/ {print $1}')
  if [ -n "$LINKED_LIBS" ]; then
    for linked in $LINKED_LIBS; do
      rewrite_install_dep "$target" "$linked" "@loader_path/$(basename "$linked")"
    done
  fi
done

for target in "$PREFIX/otp/bin/beam.smp" "$CRYPTO_LIB_DIR"/crypto*.so "$CRYPTO_LIB_DIR"/libcrypto*.dylib "$CRYPTO_LIB_DIR"/libssl*.dylib; do
  [ -f "$target" ] || continue
  log_macho_info "$target"
done

CRYPTO_DYLD_PATH="$CRYPTO_LIB_DIR:$SSL_LIB_FIX"
export DYLD_LIBRARY_PATH="$CRYPTO_DYLD_PATH${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
export DYLD_FALLBACK_LIBRARY_PATH="$CRYPTO_DYLD_PATH${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"
export LD_LIBRARY_PATH="$CRYPTO_DYLD_PATH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Snow Leopard's system libcrypto.0.9.8 conflicts with our libcrypto.1.0.0
# at the OpenSSL init level. Pre-loading ours via DYLD_INSERT_LIBRARIES
# ensures our symbols take priority over the system copy.
export DYLD_INSERT_LIBRARIES="$CRYPTO_LIB_DIR/libcrypto.1.0.0.dylib${DYLD_INSERT_LIBRARIES:+:$DYLD_INSERT_LIBRARIES}"

echo "  ✓ crypto NIF dylibs bundled in $CRYPTO_LIB_DIR"
echo "  Verifying OTP runtime and crypto..."
if "$PREFIX/otp/bin/erl" -noshell -eval 'application:start(crypto), try crypto:hash(sha256, <<"test">>) of _ -> io:format("OTP ~s crypto ok~n", [erlang:system_info(otp_release)]), halt(0) catch _:_ -> io:format("crypto hash failed~n"), halt(1) end.' >> "$BUILD_LOG" 2>&1; then
  echo "  ✓ Erlang/OTP installed (crypto OK)"
  cache_mark_stage otp "$OTP_FINGERPRINT"
else
  {
    echo ""
    echo "==== OTP crypto diagnostics ===="
    echo "CRYPTO_LIB_DIR=$CRYPTO_LIB_DIR"
    echo "DYLD_LIBRARY_PATH=${DYLD_LIBRARY_PATH:-}"
    echo "DYLD_FALLBACK_LIBRARY_PATH=${DYLD_FALLBACK_LIBRARY_PATH:-}"
    echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}"
  } >> "$BUILD_LOG"

  for target in "$PREFIX/otp/bin/beam.smp" "$CRYPTO_LIB_DIR"/crypto*.so "$CRYPTO_LIB_DIR"/libcrypto*.dylib "$CRYPTO_LIB_DIR"/libssl*.dylib; do
    [ -f "$target" ] || continue
    log_macho_info "$target"
  done

  echo "  ✗ OTP crypto self-test failed. Last 60 lines:"
  tail -60 "$BUILD_LOG"
  exit 1
fi
