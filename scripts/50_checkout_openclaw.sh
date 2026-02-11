#!/usr/bin/env bash
# Phase 50: Checkout OpenClaw at pinned ref. Always re-pin on every run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

load_env
require_cmd lxc git

# Clone if missing
if ! lxc_exec "$VM_NAME" test -d /opt/openclaw/repo/.git; then
  log "Cloning OpenClaw repo into VM..."
  retry 3 5 lxc_exec "$VM_NAME" git clone "$OPENCLAW_GIT_URL" /opt/openclaw/repo
else
  log "Repo already present; re-pinning to $OPENCLAW_GIT_REF"
fi

# Fetch, checkout pinned ref, write .pinned_commit (ref passed via file to avoid injection)
ref_file="$(mktemp)"
trap 'rm -f "$ref_file"' EXIT
printf '%s' "$OPENCLAW_GIT_REF" > "$ref_file"
lxc file push "$ref_file" "$VM_NAME/tmp/openclaw_git_ref" --mode=0600
rm -f "$ref_file"
trap - EXIT

lxc_exec "$VM_NAME" bash -c '
  set -euo pipefail
  ref="$(cat /tmp/openclaw_git_ref)"
  rm -f /tmp/openclaw_git_ref
  cd /opt/openclaw/repo
  git fetch --all --tags
  git checkout --force "$ref"
  git rev-parse HEAD > .pinned_commit
'
log "OpenClaw pinned to $OPENCLAW_GIT_REF ($(lxc_exec "$VM_NAME" cat /opt/openclaw/repo/.pinned_commit 2>/dev/null || echo 'unknown'))."
