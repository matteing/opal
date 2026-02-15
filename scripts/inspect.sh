#!/usr/bin/env bash
# Connects an IEx inspector to a running Opal node.
# Reads the node name and cookie from ~/.opal/node (written by start_distribution/0).
set -euo pipefail

NODE_FILE="${HOME}/.opal/node"

if [ ! -f "$NODE_FILE" ]; then
  echo "No running Opal node found (~/.opal/node missing)."
  echo "Start Opal first, then run this again."
  exit 1
fi

NODE_NAME=$(sed -n '1p' "$NODE_FILE")
COOKIE=$(sed -n '2p' "$NODE_FILE")

if [ -z "$NODE_NAME" ] || [ -z "$COOKIE" ]; then
  echo "Invalid node file format. Expected node name on line 1, cookie on line 2."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

exec iex --sname "inspector_$$" --cookie "$COOKIE" --remsh "$NODE_NAME" --dot-iex "$SCRIPT_DIR/inspect.exs"
