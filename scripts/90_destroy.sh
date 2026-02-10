#!/usr/bin/env bash
# Phase 90: Remove proxy devices and delete VM. Optionally purge state/exports and state/logs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

load_env
require_cmd lxc

# Optional: purge state exports/logs (set OPENCLAW_PURGE_STATE=true or pass --purge)
purge_state="${OPENCLAW_PURGE_STATE:-false}"

# Parse --purge if passed
for arg in "$@"; do
  if [[ "$arg" == "--purge" ]]; then
    purge_state=true
    break
  fi
done

if ! exists_vm "$VM_NAME"; then
  log "VM $VM_NAME does not exist; nothing to destroy"
  exit 0
fi

# Remove proxy devices (best-effort)
for dev in openclaw-ui openclaw-bridge; do
  if lxc config device show "$VM_NAME" 2>/dev/null | grep -q "^$dev:"; then
    log "Removing device $dev from $VM_NAME..."
    lxc config device remove "$VM_NAME" "$dev" 2>/dev/null || true
  fi
done

log "Deleting VM $VM_NAME..."
lxc delete -f "$VM_NAME"
log "VM $VM_NAME destroyed."

if [[ "$purge_state" == "true" ]]; then
  log "Purging state/exports and state/logs..."
  rm -rf "$STATE_DIR/exports"
  mkdir -p "$STATE_DIR/exports"
  rm -rf "$STATE_DIR/logs"
  mkdir -p "$STATE_DIR/logs"
  log "State exports and logs purged."
fi
