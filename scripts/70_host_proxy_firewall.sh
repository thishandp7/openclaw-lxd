#!/usr/bin/env bash
# Phase 70: Host proxy devices (localhost exposure) and optional UFW. Idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

load_env
require_cmd lxc

# Ensure VM has a static IP on lxdbr0 (required for NAT proxy)
BRIDGE_SUBNET="$(lxc network get lxdbr0 ipv4.address)"  # e.g. 10.x.x.1/24
BRIDGE_PREFIX="${BRIDGE_SUBNET%.*}"                       # e.g. 10.x.x
VM_STATIC_IP="${BRIDGE_PREFIX}.10"

if ! lxc config device get "$VM_NAME" eth0 ipv4.address 2>/dev/null | grep -q '.'; then
  log "Assigning static IP $VM_STATIC_IP to $VM_NAME eth0"
  lxc config device override "$VM_NAME" eth0 ipv4.address="$VM_STATIC_IP"
fi

# Ensure the VM's interface actually has the static IP (DHCP renewal needed after override)
VM_NIC="$(lxc exec "$VM_NAME" -- sh -c "ip -4 addr show | grep -oP '(?<=\d: )\S+(?=:)' | head -2 | tail -1")" || VM_NIC="enp5s0"
CURRENT_IP="$(lxc exec "$VM_NAME" -- sh -c "ip -4 -o addr show $VM_NIC" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)" || true
if [[ "$CURRENT_IP" != "$VM_STATIC_IP" ]]; then
  log "VM has IP $CURRENT_IP, expected $VM_STATIC_IP — forcing DHCP renewal on $VM_NIC"
  lxc exec "$VM_NAME" -- networkctl reconfigure "$VM_NIC" 2>/dev/null \
    || lxc exec "$VM_NAME" -- sh -c "dhclient -r $VM_NIC && dhclient $VM_NIC" 2>/dev/null \
    || log "WARN: Could not force DHCP renewal"
  # Wait for the static IP to take effect
  for i in $(seq 1 15); do
    CURRENT_IP="$(lxc exec "$VM_NAME" -- sh -c "ip -4 -o addr show $VM_NIC" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)" || true
    if [[ "$CURRENT_IP" == "$VM_STATIC_IP" ]]; then
      log "VM acquired static IP $VM_STATIC_IP"
      break
    fi
    sleep 2
  done
  if [[ "$CURRENT_IP" != "$VM_STATIC_IP" ]]; then
    log "WARN: VM still has IP $CURRENT_IP instead of $VM_STATIC_IP after DHCP renewal"
  fi
fi

# 70.1 LXD proxy device: host 127.0.0.1:OPENCLAW_PORT -> VM port (NAT mode required for VMs)
ensure_lxc_device "$VM_NAME" openclaw-ui proxy \
  listen="tcp:127.0.0.1:${OPENCLAW_PORT}" \
  connect="tcp:0.0.0.0:${OPENCLAW_PORT}" \
  nat=true

# Optional: bridge port proxy
ensure_lxc_device "$VM_NAME" openclaw-bridge proxy \
  listen="tcp:127.0.0.1:${OPENCLAW_BRIDGE_PORT}" \
  connect="tcp:0.0.0.0:${OPENCLAW_BRIDGE_PORT}" \
  nat=true

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
