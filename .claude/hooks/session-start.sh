#!/bin/bash
set -euo pipefail

# Only run in remote (Claude Code on the web) environments
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "$CLAUDE_PROJECT_DIR"

# --- Elixir / Erlang via asdf (read versions from .tool-versions) ---
if ! command -v mix &>/dev/null; then
  # Install asdf if missing
  if ! command -v asdf &>/dev/null; then
    git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.16.7 2>/dev/null || true
    # shellcheck source=/dev/null
    . "$HOME/.asdf/asdf.sh"
  fi

  asdf plugin add erlang 2>/dev/null || true
  asdf plugin add elixir 2>/dev/null || true
  asdf install erlang
  asdf install elixir
fi

# Ensure asdf shims are on PATH for subsequent commands
if [ -f "$HOME/.asdf/asdf.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOME/.asdf/asdf.sh"
fi

# --- Node.js dependencies (pnpm monorepo: root + cli workspace) ---
pnpm install

# --- Elixir dependencies ---
cd packages/core
mix local.hex --force --if-missing
mix deps.get
mix compile
cd ../..
