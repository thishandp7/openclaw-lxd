#!/usr/bin/env bash
# Phase 40: Provision VM — apt, Docker + Compose, /opt/openclaw dirs. Idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

load_env
require_cmd lxc

# Skip Docker install if already present
if lxc_exec "$VM_NAME" docker --version &>/dev/null && lxc_exec "$VM_NAME" docker compose version &>/dev/null; then
  log "Docker and compose already present in VM; skipping install"
else
  # Fail fast if VM has no outbound connectivity (before apt). Skip when proxy is set (VM will use proxy for apt).
  if [[ -z "${VM_HTTP_PROXY:-}" ]] && [[ -z "${VM_HTTPS_PROXY:-}" ]]; then
    log "Checking VM outbound connectivity..."
    if ! lxc_exec "$VM_NAME" curl -fsS --max-time 15 -o /dev/null http://archive.ubuntu.com/ubuntu/ 2>/dev/null; then
      log "VM outbound connectivity check failed"
      echo "" >&2
      echo "ERROR: The VM cannot reach the internet (e.g. archive.ubuntu.com)." >&2
      echo "  - Check LXD bridge and NAT: lxdbr0, ip_forward, iptables/nftables masquerade." >&2
      echo "  - Check host firewall is not blocking forwarded traffic from the bridge." >&2
      echo "  - If the host is behind a corporate HTTP proxy, set VM_HTTP_PROXY and/or VM_HTTPS_PROXY in state/settings.env and re-run." >&2
      echo "" >&2
      exit 1
    fi
  else
    log "VM proxy configured; skipping direct connectivity check"
  fi

  # When proxy is set: push apt proxy config to VM (validated URLs only; never logged)
  vm_http="${VM_HTTP_PROXY:-$VM_HTTPS_PROXY}"
  vm_https="${VM_HTTPS_PROXY:-$VM_HTTP_PROXY}"
  if [[ -n "$vm_http" ]] || [[ -n "$vm_https" ]]; then
    log "Using VM proxy for apt/curl"
    apt_proxy_tmp="$(mktemp)"
    trap 'rm -f "$apt_proxy_tmp"' EXIT
    printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "${vm_http:-}" "${vm_https:-}" > "$apt_proxy_tmp"
    lxc file push "$apt_proxy_tmp" "$VM_NAME/etc/apt/apt.conf.d/99proxy" --mode=0644
    rm -f "$apt_proxy_tmp"
    trap - EXIT
  fi

  log "Installing Docker and dependencies in VM..."
  if ! retry 3 30 lxc_exec "$VM_NAME" bash -c '
    export HTTP_PROXY="${1:-}"
    export HTTPS_PROXY="${2:-}"
    export http_proxy="${1:-}"
    export https_proxy="${2:-}"
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    # Force apt to use IPv4 only (avoids timeouts when IPv6 is unreachable in LXD VM)
    echo "Acquire::ForceIPv4 \"true\";" > /etc/apt/apt.conf.d/99force-ipv4
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl git

    # Docker official repo + docker-ce + docker-compose-plugin
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${VERSION_CODENAME:-jammy}") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
  ' _ "${vm_http:-}" "${vm_https:-}"; then
    log "apt install failed after 3 attempts"
    echo "ERROR: Docker/apt install failed after 3 attempts. Check VM network or proxy settings." >&2
    exit 1
  fi
  log "Docker install done"
fi

# Create OpenClaw dirs
lxc_exec "$VM_NAME" bash -c 'mkdir -p /opt/openclaw/config /opt/openclaw/workspace'
log "Created /opt/openclaw/config and /opt/openclaw/workspace"

# Verify
lxc_exec "$VM_NAME" docker --version
lxc_exec "$VM_NAME" docker compose version
log "VM provision complete."
