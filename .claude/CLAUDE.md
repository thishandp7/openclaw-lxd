# CLAUDE.md — openclaw-lxd

## Project Overview

Reproducible, idempotent Bash script suite that deploys **OpenClaw** inside an **LXD virtual machine** on an Ubuntu host. OpenClaw runs in Docker containers within the VM, exposed only on `127.0.0.1`. Remote access is via Tailscale + SSH tunnel.

**Not a library or application** — this is a deployment/infrastructure automation project written entirely in Bash.

## Repository Structure

```
openclaw-lxd/
├── CLAUDE.md
├── README.md
├── .gitignore
├── config/                          # Committed templates and LXD config
│   ├── settings.env.example         # Non-secret settings template
│   ├── openclaw.secrets.env.example # Secrets template
│   └── lxd-preseed.yaml            # LXD init preseed (bridge + storage)
├── scripts/                         # All executable code lives here
│   ├── run.sh                       # Main entrypoint and orchestrator
│   ├── lib.sh                       # Shared helpers (logging, validation, retry, LXD wrappers)
│   ├── 00_preflight.sh              # Host checks: Ubuntu, snap, env files, ports, sudo, Tailscale
│   ├── 10_install_lxd.sh            # Install LXD snap, add user to lxd group
│   ├── 20_init_lxd.sh              # LXD preseed init (lxdbr0 + default storage pool)
│   ├── 30_create_vm.sh             # Launch LXD VM, cloud-init wait, filesystem resize
│   ├── 40_vm_provision.sh          # Install Docker/Compose in VM, create /opt/openclaw dirs
│   ├── 50_checkout_openclaw.sh     # Clone and pin OpenClaw repo at a git ref
│   ├── 60_deploy_openclaw.sh       # Generate env/override, compose up, health checks, TUI config
│   ├── 70_host_proxy_firewall.sh   # Static IP, LXD proxy devices, UFW
│   ├── 80_snapshot_export.sh       # VM snapshot and optional tarball export
│   └── 90_destroy.sh              # Tear down proxy devices, delete VM, optional purge
└── state/                           # Gitignored — runtime state, logs, secrets, exports
```

## Key Conventions

### Script Architecture
- **Numbered phases** (00–90): Each script is a self-contained, idempotent phase. They skip work already done (VM exists, Docker installed, etc.).
- **`run.sh`** is the sole user-facing entrypoint. It parses flags, then calls phases in order.
- **`lib.sh`** is sourced by every phase script. It provides: `log`, `load_env`, `require_cmd`, `run`, `retry`, `exists_vm`, `lxc_exec`, `ensure_dir`, `ensure_lxc_device`, and input validation functions.
- All scripts use `set -euo pipefail` at the top.

### Bash Style
- **Shellcheck-clean**: Scripts use `# shellcheck source=` directives where needed.
- **Quoting**: All variables are double-quoted. No unquoted expansions.
- **Validation**: `lib.sh` validates all user-supplied inputs (VM names, ports, proxy URLs, git URLs) with strict regex before use. This prevents injection into LXD commands and paths.
- **Idempotency**: Every phase checks current state before acting. Safe to rerun.
- **Logging**: Use `log "message"` from lib.sh — timestamps to both stdout and per-script log file in `state/logs/`.
- **No hardcoded values**: Ports, VM name, image, git ref, etc. all come from `state/settings.env`.

### Security Model
- Ports bound to **127.0.0.1 only** — both inside VM and on host (via LXD proxy devices with `nat=true`).
- Secrets live only in `state/openclaw.secrets.env` (gitignored, `chmod 600`).
- Secrets are pushed into the VM via `lxc file push` with temp files, never passed as CLI arguments.
- Docker containers run with `no-new-privileges` and `cap_drop: ALL`.
- Git ref is passed to the VM via file push (not interpolated into shell commands) to prevent injection.
- `state/settings.env` and `state/openclaw.secrets.env` are sourced as shell — they are a trusted input boundary.

### Environment Files
- **`state/settings.env`**: Non-secret configuration. Created by user from `config/settings.env.example`.
- **`state/openclaw.secrets.env`**: Secrets (gateway token, Claude session keys). Created from `config/openclaw.secrets.env.example`.
- Both are loaded by `load_env` in lib.sh with `set -a` / `set +a`.
- **Never commit `state/`** — it is gitignored.

## Common Commands

```bash
# Full deploy (phases 00-80)
./scripts/run.sh up

# Verify health
./scripts/run.sh verify

# Destroy VM
./scripts/run.sh destroy
./scripts/run.sh destroy --purge   # also wipe state/exports and state/logs

# Recreate from scratch
./scripts/run.sh recreate

# Snapshot / export
./scripts/run.sh snapshot
./scripts/run.sh export --force

# Approve pending device pairing
./scripts/run.sh approve

# Override git ref
./scripts/run.sh up --ref v1.0.0
```

## Working with This Codebase

### When modifying scripts:
- Always source `lib.sh` at the top of any new phase script.
- Use `load_env` to get configuration. Use `log` for output. Use `require_cmd` to check dependencies.
- Use `lxc_exec "$VM_NAME"` instead of raw `lxc exec` — it's the standardized wrapper.
- Use `retry count sleep_sec command...` for operations that may need retries (network, cloud-init).
- Use `ensure_lxc_device` for proxy devices — it's idempotent.
- Validate any new user-supplied inputs in `lib.sh` before using them in commands.
- Keep phases idempotent: check state, skip if done, act if needed.

### When adding a new phase:
- Name it with the next available number prefix (e.g., `45_something.sh`).
- Add the call in `cmd_up()` in `run.sh` in the correct order.
- Follow the same boilerplate: shebang, `set -euo pipefail`, source `lib.sh`, call `load_env`.

### Testing changes:
- This project targets **Ubuntu 24.04 hosts** with LXD (snap). macOS is the development machine, but the scripts run on the Ubuntu host.
- There is no automated test suite. Testing is manual: run `./scripts/run.sh up` on a target host and `./scripts/run.sh verify` to check.
- Use `lxc exec openclaw-vm -- bash` to get a shell inside the VM for debugging.
- Logs are written per-phase to `state/logs/<phase>.log`.

### LXD / VM internals:
- VM image: Ubuntu 24.04 (from `ubuntu:` remote).
- VM paths: `/opt/openclaw/repo` (cloned code), `/opt/openclaw/openclaw.env` (generated env), `/opt/openclaw/state` (mounted into container as `/home/node/.openclaw`).
- Docker container name: `repo-openclaw-gateway-1`.
- The gateway is a WebSocket server — it does not respond to plain HTTP GET. Health checks verify container status + port binding via `ss`, not HTTP responses.
- Static IP is derived from the LXD bridge subnet: `<bridge-prefix>.10`.

## Git Workflow
- Single `main` branch.
- Commit messages are short, imperative ("Adding X", "Fixing Y").
- No CI/CD — manual deployment and verification.
