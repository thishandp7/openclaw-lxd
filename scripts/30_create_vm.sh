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

log "Launching VM $VM_NAME from $VM_IMAGE with disk size $VM_DISK..."
lxc launch "$VM_IMAGE" "$VM_NAME" --vm \
  -c limits.cpu="$VM_CPU" \
  -c limits.memory="$VM_MEM" \
  -d root,size="$VM_DISK"

log "Waiting for cloud-init in VM..."
retry 30 2 lxc exec "$VM_NAME" -- cloud-init status --wait

# Grow the guest filesystem to use the full disk
log "Resizing guest filesystem..."
lxc exec "$VM_NAME" -- bash -c '
  # Find the root partition (usually /dev/sda1 or /dev/vda1)
  ROOT_DEV=$(findmnt -n -o SOURCE /)
  DISK_DEV=$(echo "$ROOT_DEV" | sed "s/[0-9]*$//" | sed "s/p$//" )
  PART_NUM=$(echo "$ROOT_DEV" | grep -o "[0-9]*$")

  # Grow partition to use all available space
  growpart "$DISK_DEV" "$PART_NUM" 2>/dev/null || true

  # Resize the filesystem
  resize2fs "$ROOT_DEV" 2>/dev/null || true
'

log "VM $VM_NAME is ready."
