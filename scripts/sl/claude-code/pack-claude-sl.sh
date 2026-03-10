#!/bin/bash
set -euo pipefail

# pack-claude-sl.sh — Package Claude Code Snow Leopard Edition
#
# Assembles a self-contained bundle that can be scp'd to a Snow Leopard machine.
# Requires: build-node12-sl.sh to have been run first (or provide a node binary).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
OUTPUT="${1:-${REPO_ROOT}/claude-sl-bundle.tar.gz}"
NODE_BIN="${SCRIPT_DIR}/node12-snowleopard"

if [ ! -f "$NODE_BIN" ]; then
  echo "Node binary not found at $NODE_BIN"
  echo "Run build-node12-sl.sh first, or set NODE_BIN env var."
  exit 1
fi

STAGE=$(mktemp -d)
BUNDLE="$STAGE/claude-code"
mkdir -p "$BUNDLE"

echo "=== Packing Claude Code Snow Leopard Edition ==="

# Node binary
cp "$NODE_BIN" "$BUNDLE/node"
chmod +x "$BUNDLE/node"
echo "  Node binary: $(du -h "$BUNDLE/node" | cut -f1)"

# CLI
cp "$REPO_ROOT/cli-sl.cjs" "$BUNDLE/cli.cjs" 2>/dev/null || \
  cp "$SCRIPT_DIR/cli-sl.cjs" "$BUNDLE/cli.cjs"
echo "  CLI: $(wc -l < "$BUNDLE/cli.cjs") lines"

# CA certificates
if [ -f "$REPO_ROOT/certs/cacert.pem" ]; then
  cp "$REPO_ROOT/certs/cacert.pem" "$BUNDLE/cacert.pem"
elif [ -f "/etc/ssl/cert.pem" ]; then
  cp "/etc/ssl/cert.pem" "$BUNDLE/cacert.pem"
else
  curl -sLo "$BUNDLE/cacert.pem" "https://curl.se/ca/cacert.pem"
fi

# Launcher script
cat > "$BUNDLE/claude" << 'LAUNCHER'
#!/bin/sh
DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$DIR:$PATH"
export SSL_CERT_FILE="$DIR/cacert.pem"
if [ -z "$ANTHROPIC_API_KEY" ]; then
  [ -f "$HOME/.anthropic_key" ] && export ANTHROPIC_API_KEY="$(cat "$HOME/.anthropic_key")"
fi
exec "$DIR/node" --single-threaded "$DIR/cli.cjs" "$@"
LAUNCHER
chmod +x "$BUNDLE/claude"

# Package
cd "$STAGE"
tar czf "$OUTPUT" claude-code/
rm -rf "$STAGE"

echo "=== Bundle ready: $OUTPUT ($(du -h "$OUTPUT" | cut -f1)) ==="
echo ""
echo "Deploy to Snow Leopard:"
echo "  scp $OUTPUT snowleopard:~/"
echo "  ssh snowleopard 'tar xzf claude-sl-bundle.tar.gz'"
echo "  ssh snowleopard 'echo \"sk-ant-...\" > ~/.anthropic_key'"
echo "  ssh snowleopard '~/claude-code/claude -p \"hello\"'"
