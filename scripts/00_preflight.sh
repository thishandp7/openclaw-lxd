#!/usr/bin/env bash
# Phase 00: Host preflight — check Ubuntu, snap, env files, ports, sudo, optional Tailscale.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

ensure_dir "$LOG_DIR" 0755

load_env

# Summary lines for log
summary() {
  echo "$*" >> "$LOG_DIR/00_preflight.log"
}

summary "=== Preflight $(date -Iseconds) ==="

# Ubuntu 24.04 (warn only)
if [[ -f /etc/os-release ]]; then
  # shellcheck source=/dev/null
  source /etc/os-release
  if [[ "${VERSION_ID:-}" != "24.04" ]]; then
    log "WARN: Ubuntu 24.04 recommended; found VERSION_ID=${VERSION_ID:-unknown}"
    summary "WARN: Ubuntu version ${VERSION_ID:-unknown}"
  else
    summary "OK: Ubuntu 24.04"
  fi
else
  log "WARN: Cannot read /etc/os-release"
  summary "WARN: No os-release"
fi

# snap present
require_cmd snap
summary "OK: snap present"

# state env files
if [[ ! -f "$STATE_DIR/settings.env" ]] || [[ ! -r "$STATE_DIR/settings.env" ]]; then
  log "Missing or unreadable $STATE_DIR/settings.env"
  summary "FAIL: settings.env missing/unreadable"
  exit 1
fi
if [[ ! -f "$STATE_DIR/openclaw.secrets.env" ]] || [[ ! -r "$STATE_DIR/openclaw.secrets.env" ]]; then
  log "Missing or unreadable $STATE_DIR/openclaw.secrets.env"
  summary "FAIL: openclaw.secrets.env missing/unreadable"
  exit 1
fi
summary "OK: settings.env and openclaw.secrets.env present and readable"

# Ports not in use on host
for port in "$OPENCLAW_PORT" "$OPENCLAW_BRIDGE_PORT"; do
  if ss -lntp 2>/dev/null | grep -qE ":$port\s" || netstat -lntp 2>/dev/null | grep -qE ":$port\s"; then
    log "Port $port is already in use on host"
    summary "FAIL: port $port in use"
    exit 1
  fi
done
summary "OK: ports $OPENCLAW_PORT and $OPENCLAW_BRIDGE_PORT free"

# Sudo access
if ! sudo -n true 2>/dev/null; then
  log "Sudo access required (run with sudo or ensure NOPASSWD)"
  summary "FAIL: no sudo access"
  exit 1
fi
summary "OK: sudo access"

# Optional: Tailscale
if command -v tailscale &>/dev/null; then
  if tailscale status &>/dev/null; then
    summary "OK: tailscale status ok"
  else
    log "WARN: tailscale status failed (optional)"
    summary "WARN: tailscale not running"
  fi
else
  summary "WARN: tailscale not installed (optional)"
fi

summary "=== Preflight passed ==="
log "Preflight passed."
