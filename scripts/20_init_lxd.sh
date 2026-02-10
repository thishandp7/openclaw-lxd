#!/usr/bin/env bash
# Phase 20: Initialize LXD with preseed (lxdbr0 + default storage). Idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

load_env
require_cmd lxc sudo

# Check if LXD is already initialized: default storage pool and lxdbr0 exist
storage_ok=false
network_ok=false

if lxc storage list --format csv 2>/dev/null | grep -q '^default,'; then
  storage_ok=true
fi
if lxc network list --format csv 2>/dev/null | grep -q '^lxdbr0,'; then
  network_ok=true
fi

if [[ "$storage_ok" == true ]] && [[ "$network_ok" == true ]]; then
  log "LXD already initialized (default pool and lxdbr0 present)"
  exit 0
fi

log "LXD not fully initialized (storage_ok=$storage_ok network_ok=$network_ok). Applying preseed..."
run sudo lxd init --preseed < "$CONFIG_DIR/lxd-preseed.yaml"
log "LXD init preseed done"

# Verify
if ! lxc storage list --format csv 2>/dev/null | grep -q '^default,'; then
  log "WARN: default storage pool missing after init"
fi
if ! lxc network list --format csv 2>/dev/null | grep -q '^lxdbr0,'; then
  log "WARN: lxdbr0 missing after init"
fi
