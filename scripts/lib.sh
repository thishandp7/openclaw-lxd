# Common library for OpenClaw LXD scripts.
# Source this first; use set -euo pipefail in callers or here.
set -euo pipefail

# Repo root (openclaw-lxd/). Resolve from script location so any script in scripts/ finds state/ and config/.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
OPENCLAW_LXD_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="$OPENCLAW_LXD_ROOT/state"
CONFIG_DIR="$OPENCLAW_LXD_ROOT/config"
LOG_DIR="$STATE_DIR/logs"

log() {
  local msg="$*"
  local ts
  ts="$(date -Iseconds)"
  echo "[$ts] $msg" >> "$LOG_DIR/$(basename "${BASH_SOURCE[1]:-$0}" .sh).log"
  echo "[$ts] $msg"
}

# Load state/settings.env and state/openclaw.secrets.env. Abort if missing.
load_env() {
  if [[ ! -f "$STATE_DIR/settings.env" ]]; then
    echo "Missing $STATE_DIR/settings.env. Copy config/settings.env.example to state/settings.env and fill in." >&2
    exit 1
  fi
  if [[ ! -f "$STATE_DIR/openclaw.secrets.env" ]]; then
    echo "Missing $STATE_DIR/openclaw.secrets.env. Create it with OpenClaw secrets (see plan)." >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  set -a
  source "$STATE_DIR/settings.env"
  source "$STATE_DIR/openclaw.secrets.env"
  set +a
  validate_vm_names
  validate_ports
  validate_proxy_urls
  validate_git_url
}

# When VM_HTTP_PROXY or VM_HTTPS_PROXY is set, validate format: http(s):// only, no quotes/backticks/space.
# Never log proxy URLs.
validate_proxy_urls() {
  local proxy_regex='^https?://[^'"'"'\"\`[:space:]]+$'
  if [[ -n "${VM_HTTP_PROXY:-}" ]]; then
    if [[ ! "$VM_HTTP_PROXY" =~ $proxy_regex ]]; then
      echo "Invalid VM_HTTP_PROXY (must be http:// or https:// URL with no quotes or spaces)." >&2
      exit 1
    fi
  fi
  if [[ -n "${VM_HTTPS_PROXY:-}" ]]; then
    if [[ ! "$VM_HTTPS_PROXY" =~ $proxy_regex ]]; then
      echo "Invalid VM_HTTPS_PROXY (must be http:// or https:// URL with no quotes or spaces)." >&2
      exit 1
    fi
  fi
}

# Validate OPENCLAW_GIT_URL: must be https://, git://, or ssh:// URL
# Rejects file://, local paths, and suspicious patterns
validate_git_url() {
  local url="${OPENCLAW_GIT_URL:-}"
  if [[ -z "$url" ]]; then
    echo "OPENCLAW_GIT_URL is required." >&2
    exit 1
  fi
  # Allow https://, git://, ssh://, or git@host:path format
  local valid_regex='^(https://|git://|ssh://|git@[a-zA-Z0-9._-]+:)[^[:space:]]+$'
  if [[ ! "$url" =~ $valid_regex ]]; then
    echo "Invalid OPENCLAW_GIT_URL: must be https://, git://, ssh://, or git@host:path format." >&2
    exit 1
  fi
  # Reject file:// and suspicious patterns
  if [[ "$url" =~ ^file:// ]] || [[ "$url" =~ \.\. ]]; then
    echo "Invalid OPENCLAW_GIT_URL: file:// and path traversal not allowed." >&2
    exit 1
  fi
}

# Set default ports if unset, then reject if not decimal 1-65535.
# Prevents regex/LXD injection and ensures safe use in grep and device config.
validate_ports() {
  : "${OPENCLAW_PORT:=18789}"
  : "${OPENCLAW_BRIDGE_PORT:=18790}"
  export OPENCLAW_PORT OPENCLAW_BRIDGE_PORT
  local port_regex='^[0-9]+$'
  local p
  for p in "$OPENCLAW_PORT" "$OPENCLAW_BRIDGE_PORT"; do
    if [[ ! "$p" =~ $port_regex ]]; then
      echo "Invalid port (must be 1-65535): $p" >&2
      exit 1
    fi
    if (( p < 1 || p > 65535 )); then
      echo "Invalid port (must be 1-65535): $p" >&2
      exit 1
    fi
  done
}

# Reject VM_NAME and SNAPSHOT_NAME that contain path traversal or unsafe chars.
# Allow only [a-zA-Z0-9_.-]+ so they are safe in paths and LXD resource names.
validate_vm_names() {
  local safe_regex='^[a-zA-Z0-9_.-]+$'
  if [[ -z "${VM_NAME:-}" ]] || [[ ! "$VM_NAME" =~ $safe_regex ]]; then
    echo "Invalid VM_NAME (must match [a-zA-Z0-9_.-]+): ${VM_NAME:-<empty>}" >&2
    exit 1
  fi
  if [[ -z "${SNAPSHOT_NAME:-}" ]] || [[ ! "$SNAPSHOT_NAME" =~ $safe_regex ]]; then
    echo "Invalid SNAPSHOT_NAME (must match [a-zA-Z0-9_.-]+): ${SNAPSHOT_NAME:-<empty>}" >&2
    exit 1
  fi
}

# Require commands; log and exit 1 if any missing.
require_cmd() {
  local c
  for c in "$@"; do
    if ! command -v "$c" &>/dev/null; then
      log "Missing required command: $c"
      exit 1
    fi
  done
}

# Run command, log invocation and exit code.
run() {
  log "Running: $*"
  if "$@"; then
    log "Exit: 0"
  else
    local r=$?
    log "Exit: $r"
    return $r
  fi
}

# Return 0 if VM name exists, 1 otherwise.
exists_vm() {
  local name="${1:?}"
  lxc list -cn --format csv 2>/dev/null | grep -qxF "$name"
}

# Execute command inside VM. Usage: lxc_exec vm_name cmd [args...]
lxc_exec() {
  local vm="${1:?}"
  shift
  lxc exec "$vm" -- "$@"
}

# Retry command up to max_count times, sleeping sleep_sec between failures.
retry() {
  local max_count="${1:?}"
  local sleep_sec="${2:?}"
  shift 2
  local i=1
  while true; do
    if "$@"; then
      return 0
    fi
    if [[ $i -ge "$max_count" ]]; then
      return 1
    fi
    log "Retry $i/$max_count in ${sleep_sec}s..."
    sleep "$sleep_sec"
    i=$((i + 1))
  done
}

# Ensure directory exists with given mode (e.g. 0700).
ensure_dir() {
  local path="${1:?}"
  local mode="${2:-0755}"
  if [[ ! -d "$path" ]]; then
    mkdir -p "$path"
    chmod "$mode" "$path"
  fi
}

# Ensure LXD proxy (or other) device exists on VM. Idempotent.
# Usage: ensure_lxc_device vm_name device_name device_type key=val [key=val ...]
# Example: ensure_lxc_device openclaw-vm openclaw-ui proxy listen=tcp:127.0.0.1:18789 connect=tcp:127.0.0.1:18789
ensure_lxc_device() {
  local vm="${1:?}"
  local dev_name="${2:?}"
  local dev_type="${3:?}"
  shift 3
  local args=()
  for arg in "$@"; do
    args+=( "$arg" )
  done
  if lxc config device show "$vm" 2>/dev/null | grep -q "^$dev_name:"; then
    log "Device $dev_name already exists on $vm; updating config"
    lxc config device set "$vm" "$dev_name" "${args[@]}"
  else
    log "Adding device $dev_name to $vm"
    lxc config device add "$vm" "$dev_name" "$dev_type" "${args[@]}"
  fi
}
