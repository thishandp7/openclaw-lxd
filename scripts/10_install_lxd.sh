#!/usr/bin/env bash
# Phase 10: Install LXD snap and add user to lxd group. Idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

load_env
require_cmd snap sudo

if ! snap list lxd &>/dev/null; then
  log "Installing LXD snap..."
  run sudo snap install lxd
else
  log "LXD already installed"
fi

if groups "$USER" | grep -q '\blxd\b'; then
  log "User $USER already in lxd group"
else
  log "Adding $USER to lxd group..."
  run sudo usermod -aG lxd "$USER"
  echo "Log out and back in once, then rerun." >&2
  exit 1
fi
