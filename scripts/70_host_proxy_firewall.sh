#!/usr/bin/env bash
# Phase 70: Host proxy devices (localhost exposure) and optional UFW. Idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

load_env
require_cmd lxc

# 70.1 LXD proxy device: host 127.0.0.1:OPENCLAW_PORT -> VM 127.0.0.1:OPENCLAW_PORT
ensure_lxc_device "$VM_NAME" openclaw-ui proxy \
  listen="tcp:127.0.0.1:${OPENCLAW_PORT}" \
  connect="tcp:127.0.0.1:${OPENCLAW_PORT}"

# Optional: bridge port proxy
ensure_lxc_device "$VM_NAME" openclaw-bridge proxy \
  listen="tcp:127.0.0.1:${OPENCLAW_BRIDGE_PORT}" \
  connect="tcp:127.0.0.1:${OPENCLAW_BRIDGE_PORT}"

# 70.2 Verify host exposure (host-side ports)
log "Verifying host binds to 127.0.0.1 only..."
if ss -lntp 2>/dev/null | grep -qE "127\.0\.0\.1:(${OPENCLAW_PORT}|${OPENCLAW_BRIDGE_PORT})\s"; then
  log "Host proxy listening on 127.0.0.1:$OPENCLAW_PORT and 127.0.0.1:$OPENCLAW_BRIDGE_PORT"
else
  log "WARN: Host proxy may not be listening yet; retry in a few seconds"
fi
if curl -fsS --max-time 5 "http://127.0.0.1:${OPENCLAW_PORT}/" >/dev/null 2>&1; then
  log "Host HTTP check OK"
else
  log "WARN: Host HTTP check failed (proxy may need a moment)"
fi

# 70.3 UFW (if enabled)
if [[ "${UFW_ENABLE:-false}" == "true" ]] && [[ "${OPENCLAW_SKIP_UFW:-false}" != "true" ]]; then
  require_cmd ufw sudo
  # Add rules only if not already present (idempotent)
  if ! sudo ufw status 2>/dev/null | grep -q "Status: active"; then
    log "Configuring UFW..."
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw allow in on tailscale0
    sudo ufw --force enable
    log "UFW enabled"
  else
    log "UFW already active"
  fi
else
  log "UFW not enabled (UFW_ENABLE=$UFW_ENABLE OPENCLAW_SKIP_UFW=${OPENCLAW_SKIP_UFW:-false})"
fi

log "Host proxy and firewall phase complete."
