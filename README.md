# OpenClaw LXD VM Setup

A reproducible, idempotent script suite that runs **OpenClaw** inside an **LXD VM** using the repo + Docker Compose approach. OpenClaw is exposed only on localhost; remote access is via **Tailscale** and an **SSH tunnel** from your Mac (or another machine).

## What this does

- Creates an LXD VM (Ubuntu 24.04) with fixed CPU, memory, and disk.
- Provisions the VM with Docker and Docker Compose.
- Clones the OpenClaw repo at a **pinned git ref** (tag or commit).
- Deploys OpenClaw with Docker Compose using generated config:
  - Ports are bound to **127.0.0.1 only** (no LAN exposure).
  - Optional hardening (e.g. `no-new-privileges`, `cap_drop`).
- Exposes the VM’s OpenClaw ports on the **host** via LXD proxy devices (also 127.0.0.1 only).
- Optionally creates a VM snapshot and/or exports a tarball.
- Optionally configures UFW (deny incoming, allow Tailscale).

All state lives under `/opt/openclaw/` in the VM and under `state/` on the host, so you can wipe and rerun cleanly.

## Prerequisites

- **Host:** Ubuntu 24.04 (other versions may work; 24.04 is recommended).
- **Snap** (for LXD).
- **Sudo** access.
- **Tailscale** installed and logged in (optional but recommended for remote access).
- OpenClaw **secrets** (gateway token, Claude session/cookie) from your existing OpenClaw / Docker Compose setup.

## Directory layout

```
openclaw-lxd/
  config/
    settings.env.example      # Template for non-secret settings
    openclaw.secrets.env.example  # Template for secrets
    lxd-preseed.yaml          # LXD init (bridge + storage)
  scripts/
    run.sh                    # Main entrypoint
    lib.sh                    # Shared helpers
    00_preflight.sh ... 90_destroy.sh   # Phase scripts
  state/                     # Not committed (gitignored)
    settings.env              # Your settings (create from example)
    openclaw.secrets.env      # Your secrets (create from example)
    logs/                     # Per-phase logs
    exports/                  # VM export tarballs (optional)
```

## Configuration

### 1. Create `state/settings.env`

Copy the example and edit:

```bash
cp config/settings.env.example state/settings.env
```

Edit `state/settings.env` and set at least:

| Variable | Description | Example |
|----------|-------------|---------|
| `VM_NAME` | LXD VM name | `openclaw-vm` |
| `VM_IMAGE` | LXD image | `ubuntu:24.04` (Ubuntu 24.04 LTS, from ubuntu remote) |
| `VM_CPU` | CPU limit | `6` |
| `VM_MEM` | Memory limit | `12GiB` |
| `VM_DISK` | Root disk size | `60GiB` |
| `OPENCLAW_PORT` | Host/VM port for gateway UI | `18789` |
| `OPENCLAW_BRIDGE_PORT` | Host/VM port for bridge | `18790` |
| `OPENCLAW_GIT_URL` | OpenClaw repo URL | Your repo URL |
| `OPENCLAW_GIT_REF` | Tag or commit to pin | `v1.0.0` or `abc1234` |
| `SNAPSHOT_NAME` | Name of VM snapshot | `clean` |
| `EXPORT_AFTER_SETUP` | Export tarball after `up` | `false` or `true` |
| `UFW_ENABLE` | Enable UFW rules | `false` or `true` |
| `OPENCLAW_SSH_USER` | (Optional) SSH user in printed Mac command | Your host username |
| `OPENCLAW_TAILSCALE_HOST` | (Optional) Tailscale hostname in printed Mac command | Host’s Tailscale name |
| `VM_HTTP_PROXY` | (Optional) HTTP proxy URL for the VM (apt/curl) | `http://proxy:3128` |
| `VM_HTTPS_PROXY` | (Optional) HTTPS proxy URL for the VM (apt/curl) | `http://proxy:3128` |

### 2. Create `state/openclaw.secrets.env`

Copy the example and fill in real values:

```bash
cp config/openclaw.secrets.env.example state/openclaw.secrets.env
```

Edit `state/openclaw.secrets.env` and set:

- `OPENCLAW_GATEWAY_TOKEN`
- `CLAUDE_AI_SESSION_KEY`
- `CLAUDE_WEB_SESSION_KEY`
- `CLAUDE_WEB_COOKIE`

(These should match what your OpenClaw Docker Compose setup expects.)

### 3. Restrict permissions (recommended)

```bash
chmod 700 state
chmod 600 state/*.env
```

The `run.sh up` command will also set these if the directories exist.

## How to run

### First-time setup

1. **Install LXD and init (phases 00–20)**  
   The first `up` will:
   - Run preflight (ports, env files, sudo, optional Tailscale).
   - Install the LXD snap and add your user to the `lxd` group.  
     **If you are added to `lxd` for the first time**, you must **log out and log back in** (or start a new login session), then run `up` again.
   - Initialize LXD with the preseed (bridge + default storage) if not already done.

2. **Bring up the VM and OpenClaw (full `up`)**

   From the `openclaw-lxd` directory:

   ```bash
   ./scripts/run.sh up
   ```

   This will:

   - Create the VM (or skip if it already exists).
   - Provision it with Docker and Docker Compose.
   - Clone OpenClaw at `OPENCLAW_GIT_REF` and write `.pinned_commit`.
   - Generate `/opt/openclaw/openclaw.env` and `docker-compose.override.yml` in the VM and run `docker compose up -d`.
   - Add LXD proxy devices so the host listens on `127.0.0.1:OPENCLAW_PORT` and `OPENCLAW_BRIDGE_PORT`.
   - Optionally create a snapshot and/or export (if `EXPORT_AFTER_SETUP=true` or `--export`).

3. **Check that everything is correct**

   ```bash
   ./scripts/run.sh verify
   ```

   You should see all checks pass and the suggested SSH command for your Mac.

### Access from your Mac (Tailscale + SSH tunnel)

On the **host** (after `up`), the script prints something like:

```text
From your Mac, tunnel with:
  ssh -L 18789:<vm-bridge-ip>:18789 <user>@<tailscale-hostname>
```

On your **Mac**:

1. Ensure Tailscale is running and you can reach the host at `<tailscale-hostname>`.
2. Run the printed command (replace `<user>` and `<tailscale-hostname>` if needed).
3. In the browser on your Mac, open: `http://127.0.0.1:18789/`
   Traffic goes: Mac → SSH tunnel (Tailscale) → host → LXD bridge → VM → OpenClaw.

### Commands reference

Run from the repo root (or ensure `state/` and `config/` are relative to where the scripts live):

| Command | Description |
|---------|-------------|
| `./scripts/run.sh up` | Run all phases 00–70, then snapshot (and optional export). Idempotent: safe to rerun. |
| `./scripts/run.sh verify` | Run health and exposure checks; print checkmarks and the Mac SSH command. |
| `./scripts/run.sh snapshot` | Create VM snapshot only (phase 80). Overwrites snapshot with the same name. |
| `./scripts/run.sh export` | Create snapshot and export VM tarball to `state/exports/`. Use `--force` to overwrite. |
| `./scripts/run.sh destroy` | Remove LXD proxy devices and delete the VM. |
| `./scripts/run.sh destroy --purge` | Same as `destroy` and also remove `state/exports/` and `state/logs/`. |
| `./scripts/run.sh recreate` | Destroy the VM (if present) then run `up` again. |

### Options (before the command)

| Option | Description |
|--------|-------------|
| `--skip-ufw` | Do not configure UFW even if `UFW_ENABLE=true`. |
| `--export` | After `up`, also export the VM tarball. |
| `--ref REF` | Override `OPENCLAW_GIT_REF` from `state/settings.env` (e.g. `--ref v1.0.0`). |
| `--recreate` | With `up`: delete the VM first, then create and deploy (same as recreate flow). |
| `--force` | With `export`: overwrite an existing export file. |

Examples:

```bash
./scripts/run.sh up
./scripts/run.sh up --ref v1.0.0 --export
./scripts/run.sh verify
./scripts/run.sh destroy --purge
```

## Idempotency and safety

- **Rerunning `up`** is safe: phases skip work when already done (e.g. VM exists, LXD initialized, Docker installed). Checkout always re-pins to `OPENCLAW_GIT_REF`; deploy overwrites generated env and override and runs `compose up -d` again.
- **Ports** are bound to **127.0.0.1** only in the VM and on the host; OpenClaw is not exposed on the LAN.
- **Secrets** live only in `state/openclaw.secrets.env` (gitignored); they are pushed into the VM at deploy time and are not logged.
- **Snapshot:** Creating a snapshot with the same name again **replaces** the previous snapshot of that name.

## Network architecture

```
+-----------------------------------------------------------------------------+
|  YOUR MACBOOK                                                               |
|                                                                             |
|  Browser --> localhost:18789                                                |
|                    |                                                        |
|                    | SSH Tunnel (-L 18789:<vm-ip>:18789)                    |
|                    v                                                        |
|              +-----------+                                                  |
|              | Tailscale |  <-- WireGuard encrypted tunnel                  |
|              +-----+-----+                                                  |
+--------------------|---------------------------------------------------------+
                     |
          === INTERNET (encrypted) ===
                     |
+--------------------|---------------------------------------------------------+
|  UBUNTU HOST       |                                                        |
|              +-----+-----+                                                  |
|              | Tailscale |  <-- Only Tailscale peers can connect            |
|              +-----+-----+                                                  |
|                    |                                                        |
|              +-----+-----+                                                  |
|              | SSH Server |  <-- Forwards to <vm-ip>:18789                  |
|              +-----+-----+                                                  |
|                    |                                                        |
|              +-----+------------------------------+                         |
|              | lxdbr0 (LXD Bridge)                 |  <-- Private network   |
|              | 10.x.x.1/24                         |      NOT routable from |
|              | NAT outbound only                   |      internet or LAN   |
|              +-----+------------------------------+                         |
|                    |                                                        |
|  +-----------------+---------------------------------------------+          |
|  |  LXD VM (openclaw-vm)                                         |          |
|  |  enp5s0: 10.x.x.10 (static)                                   |          |
|  |                 |                                             |          |
|  |                 v                                             |          |
|  |  +--------------------------------------+                     |          |
|  |  | Docker (network_mode: host)          |                     |          |
|  |  |                                      |                     |          |
|  |  |  openclaw-gateway                    |                     |          |
|  |  |  listening ws://0.0.0.0:18789        |  <-- Dashboard      |          |
|  |  |                                      |                     |          |
|  |  +--------------------------------------+                     |          |
|  +---------------------------------------------------------------+          |
|                                                                             |
|  X No ports exposed on public interface                                     |
|  X No ports exposed on LAN                                                  |
+-----------------------------------------------------------------------------+

SECURITY LAYERS:
  1. Tailscale --- WireGuard encryption + device auth (only your devices)
  2. SSH -------- Encrypted tunnel + key-based auth
  3. LXD Bridge - Private 10.x.x.0/24 (host-only, no external routing)
  4. VM --------- Full kernel-level VM isolation
```

## Security and trust

- **Run as normal user:** Run `./scripts/run.sh up` (and other commands) as your normal user, **not** with `sudo`. The scripts use `sudo` only for specific operations (LXD snap install, `lxd init`, UFW). If you run the whole script with `sudo`, `state/` and logs may be created as root and cause permission issues later.
- **Env files are trusted:** `state/settings.env` and `state/openclaw.secrets.env` are **sourced as shell** by the scripts. Only create or edit these files with trusted content. Do not generate them from untrusted input; arbitrary shell in those files would run on the host.
- **UFW and Tailscale:** When `UFW_ENABLE=true`, the scripts allow **all inbound traffic on the Tailscale interface** (`ufw allow in on tailscale0`). Tailscale is treated as a trusted network; access is still expected via SSH tunnel from your Mac. Do not enable UFW this way if Tailscale is not trusted for your environment.

## Troubleshooting

- **VM has no internet / apt-get or Docker download fails**  
  The VM gets outbound internet via the LXD bridge (lxdbr0) and host NAT. If the VM cannot reach the internet (e.g. archive.ubuntu.com), the script fails with a connectivity error before apt runs. To diagnose: from the host run  
  `lxc exec <VM_NAME> -- curl -sI --max-time 5 http://archive.ubuntu.com/ubuntu/`  
  — if it times out, the VM has no outbound path. Check that the host has IP forwarding and NAT for the LXD bridge (e.g. `lxdbr0`, iptables/nftables masquerade); see LXD networking docs. If the host uses an HTTP/HTTPS proxy to reach the internet, set `VM_HTTP_PROXY` and/or `VM_HTTPS_PROXY` in `state/settings.env` (e.g. `http://proxy.corp:3128`) and re-run.

- **“Missing state/settings.env” or “Missing state/openclaw.secrets.env”**  
  Copy the corresponding file from `config/*.example` into `state/` and fill it in.

- **“Log out and back in, then rerun”**  
  Your user was just added to the `lxd` group; the new group is active only after a new login session.

- **Containers not binding to 127.0.0.1**  
  The deploy script tries `OPENCLAW_GATEWAY_BIND=localhost` then `loopback`. If it still fails, check logs in the VM:  
  `lxc exec openclaw-vm -- docker compose -f /opt/openclaw/repo/docker-compose.yml -f /opt/openclaw/repo/docker-compose.override.yml logs`

- **Host HTTP check fails**  
  Wait a few seconds after `up` for the proxy and containers to be ready, then run `./scripts/run.sh verify` again.

- **Tailscale hostname / SSH user**  
  The printed SSH command uses your current user and the host’s Tailscale hostname. You can override them in `state/settings.env` with `OPENCLAW_SSH_USER` and `OPENCLAW_TAILSCALE_HOST` so the printed command is correct without editing it by hand.
