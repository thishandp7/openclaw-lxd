#!/usr/bin/env bash
# Phase 80: Snapshot VM; optionally export tarball. Idempotent (snapshot overwrites if exists).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

load_env
require_cmd lxc

do_export="${1:-false}"   # "true" to run export
force_export="${2:-false}" # "true" to overwrite existing export file

# Snapshot: fixed name; rerun overwrites (delete old snapshot with same name if exists, then create)
if lxc list "$VM_NAME" --snapshots --format csv 2>/dev/null | grep -q "$SNAPSHOT_NAME"; then
  log "Snapshot $SNAPSHOT_NAME already exists; deleting to overwrite..."
  lxc delete "$VM_NAME/$SNAPSHOT_NAME" 2>/dev/null || true
fi
log "Creating snapshot $SNAPSHOT_NAME..."
lxc snapshot "$VM_NAME" "$SNAPSHOT_NAME"
log "Snapshot $SNAPSHOT_NAME created."

# Export if requested
if [[ "$do_export" == "true" ]]; then
  ensure_dir "$STATE_DIR/exports" 0755
  export_path="$STATE_DIR/exports/${VM_NAME}-${SNAPSHOT_NAME}-$(date +%Y%m%d).tar.gz"
  if [[ -f "$export_path" ]] && [[ "$force_export" != "true" ]]; then
    log "Export file $export_path already exists; use --force to overwrite"
    exit 1
  fi
  log "Exporting VM to $export_path..."
  lxc export "$VM_NAME" "$export_path"
  log "Export done: $export_path"
fi
