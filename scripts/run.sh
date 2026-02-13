#!/usr/bin/env bash
# OpenClaw LXD VM — main entrypoint. Usage: run.sh up | verify | snapshot | export | destroy | recreate [options]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# Parse flags (before subcommand)
OPENCLAW_SKIP_UFW=false
OPENCLAW_DO_EXPORT=false
OPENCLAW_REF_OVERRIDE=""
OPENCLAW_RECREATE=false
OPENCLAW_EXPORT_FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-ufw)   OPENCLAW_SKIP_UFW=true; shift ;;
    --export)     OPENCLAW_DO_EXPORT=true; shift ;;
    --ref)        OPENCLAW_REF_OVERRIDE="${2:?}"; shift 2 ;;
    --recreate)   OPENCLAW_RECREATE=true; shift ;;
    --force)      OPENCLAW_EXPORT_FORCE=true; shift ;;
    up|verify|snapshot|export|destroy|recreate) break ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

SUBCMD="${1:-}"
shift || true

usage() {
  cat <<EOF
Usage: $0 <command> [options]
Commands:
  up         Create VM and deploy OpenClaw (phases 00–70, then snapshot/export if enabled)
  verify     Run health and exposure checks
  snapshot   Create VM snapshot only (phase 80)
  export     Snapshot and export VM tarball (phase 80 with export)
  destroy    Delete VM and proxy devices (phase 90). Pass --purge to also remove state/exports and state/logs.
  recreate   Destroy then up

Options (before command):
  --skip-ufw   Skip UFW configuration even if UFW_ENABLE=true
  --export     After up, also export VM tarball
  --ref REF    Override OPENCLAW_GIT_REF from settings.env
  --recreate   When used with up: delete VM first then create
  --force      With export: overwrite existing export file

Examples:
  $0 up
  $0 up --ref v1.0.0 --export
  $0 verify
  $0 destroy --purge
EOF
}

# Apply --ref override after load_env
apply_ref_override() {
  if [[ -n "$OPENCLAW_REF_OVERRIDE" ]]; then
    export OPENCLAW_GIT_REF="$OPENCLAW_REF_OVERRIDE"
  fi
}

cmd_up() {
  load_env
  apply_ref_override
  # Permissions
  if [[ -d "$STATE_DIR" ]]; then
    chmod 700 "$STATE_DIR" 2>/dev/null || true
    for f in "$STATE_DIR"/*.env; do
      [[ -f "$f" ]] && chmod 600 "$f" 2>/dev/null || true
    done
  fi
  ensure_dir "$LOG_DIR" 0755

  "$SCRIPT_DIR/00_preflight.sh"
  "$SCRIPT_DIR/10_install_lxd.sh"
  "$SCRIPT_DIR/20_init_lxd.sh"
  "$SCRIPT_DIR/30_create_vm.sh"
  "$SCRIPT_DIR/40_vm_provision.sh"
  "$SCRIPT_DIR/50_checkout_openclaw.sh"
  "$SCRIPT_DIR/60_deploy_openclaw.sh"
  export OPENCLAW_SKIP_UFW
  "$SCRIPT_DIR/70_host_proxy_firewall.sh"

  local do_export_flag="$OPENCLAW_DO_EXPORT"
  [[ "${EXPORT_AFTER_SETUP:-false}" == "true" ]] && do_export_flag=true

  "$SCRIPT_DIR/80_snapshot_export.sh" "$do_export_flag" "$OPENCLAW_EXPORT_FORCE"

  # Final output: checkmarks and Mac SSH command
  print_success_block
}

# Print the five checkmarks and Mac SSH command
print_success_block() {
  load_env
  local ts="$(date -Iseconds)"
  echo ""
  echo "=== OpenClaw LXD setup complete [$ts] ==="
  echo ""

  # Run checks and print results
  local vm_ok=false containers_ok=false vm_bind_ok=false host_bind_ok=false snapshot_ok=false
  exists_vm "$VM_NAME" && vm_ok=true
  echo "VM running: ${vm_ok:+✅ true}${vm_ok:-❌ false}"

  if lxc_exec "$VM_NAME" bash -c 'cd /opt/openclaw/repo && docker compose --env-file /opt/openclaw/openclaw.env ps 2>/dev/null' 2>/dev/null | grep -qE 'running|Up'; then
    containers_ok=true
  fi
  echo "OpenClaw containers running: ${containers_ok:+✅ true}${containers_ok:-❌ false}"

  local ss_vm
  ss_vm="$(lxc_exec "$VM_NAME" ss -lntp 2>/dev/null)" || true
  if echo "$ss_vm" | grep -qE ':(18789|18790)\s'; then
    vm_bind_ok=true
  fi
  echo "VM ports 18789/18790 listening: ${vm_bind_ok:+✅ true}${vm_bind_ok:-❌ false}"

  local ss_host
  ss_host="$(ss -lntp 2>/dev/null)" || true
  if echo "$ss_host" | grep -qE '127\.0\.0\.1:('"${OPENCLAW_PORT}"'|'"${OPENCLAW_BRIDGE_PORT}"')\s'; then
    host_bind_ok=true
  fi
  echo "Host binds only to 127.0.0.1:${OPENCLAW_PORT}/${OPENCLAW_BRIDGE_PORT}: ${host_bind_ok:+✅ true}${host_bind_ok:-❌ false}"

  if lxc list "$VM_NAME" --snapshots --format csv 2>/dev/null | grep -q "$SNAPSHOT_NAME"; then
    snapshot_ok=true
  fi
  echo "Snapshot created: ${snapshot_ok:+✅ true}${snapshot_ok:-❌ false}"

  echo ""
  local ssh_user="${OPENCLAW_SSH_USER:-$(whoami)}"
  local tailscale_host=""
  if command -v tailscale &>/dev/null && tailscale status &>/dev/null; then
    tailscale_host="$(tailscale status --self --json 2>/dev/null | sed -n 's/.*"HostName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)"
  fi
  if [[ -z "$tailscale_host" ]]; then
    tailscale_host="${OPENCLAW_TAILSCALE_HOST:-<tailscale-hostname>}"
  fi
  # Get the VM's static IP on the bridge for the tunnel command
  local vm_ip=""
  vm_ip="$(lxc config device get "$VM_NAME" eth0 ipv4.address 2>/dev/null)" || true
  if [[ -z "$vm_ip" ]]; then
    vm_ip="127.0.0.1"
  fi
  echo "From your Mac, tunnel with:"
  echo "  ssh -L ${OPENCLAW_PORT}:${vm_ip}:${OPENCLAW_PORT} ${ssh_user}@${tailscale_host}"
  echo ""
}

cmd_verify() {
  load_env
  require_cmd lxc
  ensure_dir "$LOG_DIR" 0755

  local vm_ok=false containers_ok=false vm_bind_ok=false host_bind_ok=false
  echo "Verifying..."

  if exists_vm "$VM_NAME"; then
    vm_ok=true
    echo "  VM running: ✅"
  else
    echo "  VM running: ❌"
  fi

  if [[ "$vm_ok" == true ]] && lxc_exec "$VM_NAME" bash -c 'cd /opt/openclaw/repo && docker compose --env-file /opt/openclaw/openclaw.env ps 2>/dev/null' 2>/dev/null | grep -qE 'running|Up'; then
    containers_ok=true
    echo "  OpenClaw containers running: ✅"
  else
    echo "  OpenClaw containers running: ❌"
  fi

  if [[ "$vm_ok" == true ]]; then
    local ss_vm
    ss_vm="$(lxc_exec "$VM_NAME" ss -lntp 2>/dev/null)" || true
    if echo "$ss_vm" | grep -qE ':(18789|18790)\s'; then
      vm_bind_ok=true
      echo "  VM ports 18789/18790 listening: ✅"
    else
      echo "  VM ports 18789/18790 listening: ❌"
    fi
  fi

  local ss_host
  ss_host="$(ss -lntp 2>/dev/null)" || true
  if echo "$ss_host" | grep -qE '127\.0\.0\.1:('"${OPENCLAW_PORT}"'|'"${OPENCLAW_BRIDGE_PORT}"')\s'; then
    host_bind_ok=true
    echo "  Host binds only to 127.0.0.1:${OPENCLAW_PORT}/${OPENCLAW_BRIDGE_PORT}: ✅"
  else
    echo "  Host binds only to 127.0.0.1:${OPENCLAW_PORT}/${OPENCLAW_BRIDGE_PORT}: ❌"
  fi

  if [[ "$vm_ok" == true ]] && lxc list "$VM_NAME" --snapshots --format csv 2>/dev/null | grep -q "$SNAPSHOT_NAME"; then
    echo "  Snapshot $SNAPSHOT_NAME: ✅"
  else
    echo "  Snapshot $SNAPSHOT_NAME: ❌"
  fi

  echo ""
  if [[ "$vm_ok" == true ]] && [[ "$containers_ok" == true ]] && [[ "$vm_bind_ok" == true ]] && [[ "$host_bind_ok" == true ]]; then
    echo "All checks passed."
    print_success_block
    exit 0
  else
    echo "Some checks failed."
    exit 1
  fi
}

cmd_snapshot() {
  load_env
  "$SCRIPT_DIR/80_snapshot_export.sh" false false
}

cmd_export() {
  load_env
  "$SCRIPT_DIR/80_snapshot_export.sh" true "$OPENCLAW_EXPORT_FORCE"
}

cmd_destroy() {
  load_env
  [[ "${1:-}" == "--purge" ]] && export OPENCLAW_PURGE_STATE=true
  "$SCRIPT_DIR/90_destroy.sh" "$@"
}

cmd_recreate() {
  OPENCLAW_RECREATE=true
  export OPENCLAW_RECREATE
  load_env
  apply_ref_override
  "$SCRIPT_DIR/90_destroy.sh" 2>/dev/null || true
  OPENCLAW_RECREATE=true
  export OPENCLAW_RECREATE
  cmd_up
}

case "$SUBCMD" in
  up)       cmd_up ;;
  verify)   cmd_verify ;;
  snapshot) cmd_snapshot ;;
  export)   cmd_export ;;
  destroy)  cmd_destroy "$@" ;;
  recreate) cmd_recreate ;;
  "")
    echo "Missing command." >&2
    usage
    exit 1
    ;;
  *)
    echo "Unknown command: $SUBCMD" >&2
    usage
    exit 1
    ;;
esac
