#!/usr/bin/env bash
# Phase 30: Create LXD VM (or skip if exists; delete and recreate if OPENCLAW_RECREATE=true).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

load_env
require_cmd lxc

if exists_vm "$VM_NAME"; then
  if [[ "${OPENCLAW_RECREATE:-false}" == "true" ]]; then
    log "Recreating VM: deleting $VM_NAME..."
    lxc delete -f "$VM_NAME"
  else
    log "VM $VM_NAME already exists; skipping creation"
    exit 0
  fi
fi

log "Launching VM $VM_NAME from $VM_IMAGE..."
lxc launch "$VM_IMAGE" "$VM_NAME" --vm \
  -c limits.cpu="$VM_CPU" \
  -c limits.memory="$VM_MEM"

# Resize root disk to VM_DISK (profile device must be overridden on instance first)
# Use "override" to copy profile's root device to instance and set size in one go
current_size="$(lxc config device get "$VM_NAME" root size 2>/dev/null)" || current_size=""
if [[ "$current_size" != "$VM_DISK" ]]; then
  log "Overriding root device with size $VM_DISK..."
  lxc config device override "$VM_NAME" root size="$VM_DISK"
fi

log "Waiting for cloud-init in VM..."
retry 30 2 lxc exec "$VM_NAME" -- cloud-init status --wait

log "VM $VM_NAME is ready."
