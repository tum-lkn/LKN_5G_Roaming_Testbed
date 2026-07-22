# Open5GS 5G Roaming Testbed — Web UI

A web dashboard for managing and automating a two-machine Open5GS 5G roaming testbed. Built for the **Chair of Communication Networks (LKN)** at the **Technical University of Munich (TUM)**.

## What It Does

The WebUI controls a **two-PC testbed** where PC1 runs the Visited Network (VPLMN) and PC2 runs the Home Network (HPLMN). Both run Open5GS via Docker Compose. The WebUI runs on PC1 and manages PC2 remotely over SSH.

```
┌──────────────────────────────┐     SSH / N32     ┌──────────────────────────────┐
│  PC1 — VPLMN                 │◄─────────────────►│  PC2 — HPLMN                 │
│                              │                   │                              │
│  WebUI Backend  (:9090)      │                   │  Open5GS Docker Compose      │
│  WebUI Frontend (:9091)      │                   │  (NRF, AMF, SMF, UPF, ...)   │
│  Open5GS Docker Compose      │                   │                              │
│  PacketRusher (5G UE)        │                   │                              │
└──────────────────────────────┘                   └──────────────────────────────┘
```

### Features

- **Dashboard** — Start/stop Docker Compose on both PCs, view container status and logs, start/stop PacketRusher (5G UE simulator), and run ad-hoc tests through the UE's VRF path: live **ping** (with latency visualization), **iPerf3**, **download**, and **Browsertime webpage-load** tests — plus a **quick network-delay** panel to apply/remove `tc` delays on the fly.
- **Automation** — GUI for `testbed_automation.sh` — configure roaming mode (HR/LBO/Non-Roaming), security (TLS/Plain), IPsec, ping/download/iperf tests, N6 and per-container network delay rules, then run with live output streaming.
- **Batch Runner** — GUI for `batch_runner.sh` — select multiple `.conf` files (or "run all" to generate the full matrix from `main.conf`) and run them sequentially with configurable iterations.
- **Results** — Browse, view, and delete JSON test result files.
- **Plots** — Bar-chart comparison across all `batch_runner` results for every metric (registration/PDU timing, ping, download, video, iPerf, webpage timings), grouped by roaming mode (X-axis), visited PLMN (color), and DN location (hatch). Plots are rendered server-side and **cached to disk**, so they load instantly on startup instead of being re-rendered every visit. Click **Regenerate plots** to rebuild the stored set from the latest results (the button shows when the current set was generated). See [Plots caching](#plots-caching) below.
- **IPsec** — One-click **start/stop of the tunnel on both peers**, per-peer status (ESP SAs, NAT-T, active ESP proposal), and an **ESP Cipher Mode** selector that runs `esp_config.sh` on PC1 and PC2 over SSH to switch the cipher (AES-128/256-GCM, AES-CBC+HMAC, or NULL) and restart strongSwan on both sides, with live script output.
- **Post-Quantum** — GUI for the [PQ IKEv2 testbed](../docker/pq-ike-docker/README.md) (`docker/pq-ike-docker/`): benchmarks IKEv2 handshake performance with post-quantum crypto (**ML-KEM-768** key exchange, **ML-DSA-65** authentication) against classical ECP-256/RSA, across four scenarios. Manage the Docker lifecycle (build image, regenerate the PKI, start/stop the two containers), run an evaluation (config 1–5, iterations, optional netem delay) with live streaming output, and browse results with charts (per-iteration wire RTT timeline, distribution histogram, and a four-config comparison). Runs entirely **locally** on an isolated `192.168.40.0/24` bridge — no HPLMN, no 5G core, no router involved.

---

## Installation

### Prerequisites

**PC1 (VPLMN):** Python 3.10+, passwordless SSH access to PC2 from PC1, passwordless sudo command execution.  
**PC2 (HPLMN):** SSH server, passwordless sudo command execution.

### Setup

```bash
# 1. Place the webui/ folder inside your VPLMN testbed directory
cd ~/LKN_5G_Roaming_Testbed/VPLMN/webui

# 2. Run interactive setup (configures IPs, paths, credentials)
chmod +x setup.sh start.sh
./setup.sh

# 3. Start the WebUI
./start.sh start

# 4. Open in browser
#    http://<PC1_IP>:9091
```

`setup.sh` will prompt for PC1/PC2 IP addresses, SSH usernames, testbed paths, PacketRusher Docker image/network, and IPsec peer IPs. It updates `backend/app.py`, `frontend/index.html`, and `start.sh` automatically.


### Commands

```bash
./start.sh start     # Start backend (:9090) + frontend (:9091)
./start.sh stop      # Stop all services
./start.sh restart   # Restart everything
./start.sh status    # Show running status
./start.sh logs      # View recent logs
```

---

## Plots caching

Rendering every metric with matplotlib takes several seconds, so the WebUI does it **only on demand** and stores the result on disk. This keeps the Plots tab fast to open.

**How it works:**

- On page load, the Plots tab reads previously generated PNGs from `backend/plots_cache/` (near-instant, no rendering). If none exist yet, it shows *"No stored plots yet — click Regenerate."*
- Clicking **Regenerate plots** re-renders all metrics from the current `batch_runner` results, overwrites the stored set, and updates the shown generation timestamp.
- Only `batch_runner`-generated result files are included (those matching `*_dn_..._pld<n>.json`); interactive automation runs are ignored.

**When to regenerate:** after a new batch run produces fresh results. The stored plots do **not** update automatically — the button caption shows when the current set was generated so you can tell whether it's stale.

**API endpoints** (served by `backend/app.py`):

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/plots/metrics` | GET | List available metrics (id, label, unit, group). |
| `/api/plots/cached` | GET | Return the stored plots from disk without re-rendering (page-load fast path). |
| `/api/plots/generate-all` | POST | Re-render all metrics, overwrite the disk cache, and return them. |

The cache lives in `backend/plots_cache/` (one `<metric>.png` per metric plus a `manifest.json` recording the metrics, per-metric errors, source files, and generation time). It is git-ignored and safe to delete — it will be rebuilt on the next **Regenerate plots**.

---

## Moving to a New Setup

Run `./setup.sh` again on the new machine. It re-configures all IPs and paths across all files.

If you only need to update IP addresses (not SSH users, paths, or other settings), the faster approach is to edit `.env` and run the configure script from the VPLMN testbed root:

```bash
# Edit .env and set VPLMN_IP / HPLMN_IP to the new values
nano ~/LKN_5G_Roaming_Testbed/VPLMN/.env

# Propagate to all files including the WebUI
cd ~/LKN_5G_Roaming_Testbed/VPLMN
./lib/setup/configure_ip_from_env.sh
```

`configure_ip_from_env.sh` automatically updates `backend/app.py`, `frontend/index.html`, and `start.sh` — no manual edits needed.

If you need to edit the WebUI files manually for other reasons, the relevant locations are:

| File | What to change |
|------|---------------|
| `backend/app.py` | `HPLMN_IP` and `VPLMN_IP` declarations at the top of the file (used by `CONFIG` dict) |
| `frontend/index.html` | `const VPLMN_IP` and `const HPLMN_IP` constants at the top of the `<script type="text/babel">` block; also `SERVER_IP` if your performance-test server changes |
| `start.sh` | `HPLMN_IP` declaration at the top of the file |

---

## Troubleshooting

### Batch runs fail preflight with "Performance server SSH check failed"

Every config in a batch aborts immediately with:

```
Checking SSH to <user>@<perf-ip> (perf-server)...
❌ Performance server SSH check failed (required for N6 delay)
❌ ERROR: Preflight failed - check: server_ssh
```

**Cause:** the WebUI backend was started as **root** (e.g. `sudo ./start.sh`). The backend shells out to `batch_runner.sh` / `testbed_automation.sh`, which SSH into the HPLMN and performance servers. Run as root, those SSH calls use `/root/.ssh` instead of your user's keys/`known_hosts`, so the perf-server login fails — and because the N6 delay needs it, preflight hard-fails on every config.

**The WebUI must run as your normal (non-root) user** — the one whose SSH keys reach both servers and who is in the `docker` group. `start.sh` now enforces this: if launched via `sudo` it re-execs as `$SUDO_USER`, and it refuses a bare root login. It also tests the perf-server SSH at startup so you see the problem before a batch, not 50 configs deep.

**Set up passwordless SSH as your user (not root):**

```bash
ssh-copy-id <hplmn_user>@<hplmn_ip>     # e.g. wassim@10.162.149.148
ssh-copy-id <perf_user>@<perf_ip>       # e.g. roaming@10.162.149.117
```

Startup should then print `✓ SSH connection to performance server successful`.

### "The host key for \<ip\> has CHANGED"

`start.sh` deliberately does **not** auto-accept a host key that has changed, because a
rebuilt PC and a man-in-the-middle attack look identical to the client. Decide which one
it is:

- **You reinstalled/reimaged that PC** — expected. Drop the stale key and re-run:
  ```bash
  ssh-keygen -R <ip>
  ./start.sh restart
  ```
  `start.sh` records the new key on the next run.
- **You did not touch that PC** — do not clear the key. Verify the fingerprint out of
  band first, by running this *on the server itself* (console, not SSH):
  ```bash
  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
  ```
  and compare it with the fingerprint `start.sh` printed. Only clear the key if they match.

### Backend won't start: `logs/backend.log: Permission denied`

If you ran the WebUI as root **before** this fix, root created files (logs, results, browsertime output) that your user can no longer write, so the backend fails to start as your user.

**One-time fix — reclaim ownership of the testbed directory:**

```bash
sudo chown -R "$USER:$USER" ~/LKN_5G_Roaming_Testbed/VPLMN
cd ~/LKN_5G_Roaming_Testbed/VPLMN/webui
./start.sh restart
```

This is only needed once, on a machine that was previously run as root. A fresh clone never hits it, since `start.sh` no longer allows the backend to run as root.

### Batch runs fail with "Failed to apply N6 delay on local UPF" (or `sudo: a password is required`)

Preflight and SSH pass, the networks start, but every config dies at the delay step:

```
🌐 Applying N6 delay to ogstun (local)...
❌ Failed to apply N6 delay on local UPF
```

**Cause:** now that the backend runs as your normal user (not root), the automation applies delays with `sudo tc` / `sudo docker`, but a batch has **no terminal** to type a sudo password. If your user doesn't have **passwordless sudo**, those commands silently fail. This is the PC1 prerequisite *"passwordless sudo command execution."*

**Fix — grant the testbed user passwordless sudo for the commands it uses.** `./setup.sh` offers to do this for you during initial setup; to run it standalone:

```bash
cd ~/LKN_5G_Roaming_Testbed/VPLMN
./lib/setup/setup_sudoers.sh          # or: ./lib/setup/setup_sudoers.sh <user>
```

This installs a scoped `/etc/sudoers.d/roamingtb-<user>` drop-in (for `tc`, `docker`, `fuser`, `ss`, `ip` — paths resolved on your machine, validated with `visudo -c`). Verify with:

```bash
sudo -n tc qdisc show >/dev/null && echo OK
```

Then re-run the batch. (Your user must also be in the `docker` group — `groups | grep docker`; if not: `sudo usermod -aG docker $USER` then re-login.)

### "Start HPLMN" from the WebUI fails / does nothing

**Cause:** the WebUI controls PC2 (HPLMN) over SSH with **non-interactive** `sudo docker compose up -d` (and `sudo ipsec` for the HR tunnel). That needs two things on HPLMN that are easy to miss: (1) passwordless **SSH** from PC1 (see the SSH sections above), and (2) passwordless **sudo** — a non-interactive SSH command has no terminal, so if `sudo` asks for a password it just fails with *"sudo: a terminal is required to read the password"*.

**Fix — configure passwordless sudo on PC2 (HPLMN).** `HPLMN/setup.sh` now does this automatically (Step 9). To run it standalone on PC2:

```bash
cd ~/LKN_5G_Roaming_Testbed/HPLMN
./lib/setup/setup_sudoers.sh          # grants NOPASSWD for docker + ipsec only
```

Quick diagnosis from PC1: `ssh <user>@<HPLMN_IP> "sudo -n docker ps >/dev/null && echo OK || echo NEEDS_PASSWORD"`.

---

## Project Structure

```
VPLMN/
├── webui/                          # ◄ Web UI
│   ├── backend/
│   │   ├── app.py                  # Flask API server
│   │   ├── plotting.py             # Server-side bar-plot rendering (Plots tab)
│   │   ├── plots_cache/            # Generated plot PNGs + manifest.json (git-ignored)
│   │   ├── requirements.txt
│   │   └── venv/                   # Auto-created by start.sh
│   ├── frontend/
│   │   ├── index.html              # React SPA (single-file, no build step)
│   │   ├── vendor/                 # Vendored react/babel/tailwind/socket.io — no CDN/DNS needed
│   │   ├── serve.py                # No-cache HTTP file server
│   │   ├── lkn_logo.png
│   │   └── tum_logo.png
│   ├── logs/
│   ├── start.sh                    # Start/stop/restart/status
│   ├── setup.sh                    # Interactive IP configuration
│   └── README.md
├── testbed_automation.sh           # Called by Automation tab
├── batch_runner.sh                 # Called by Batch Runner tab
├── docker/pq-ike-docker/                  # PQ IKEv2 testbed — driven by the Post-Quantum tab
│   ├── ike_eval_docker.sh          #   evaluation orchestrator (run via /api/pq/run)
│   ├── docker-compose.yml          #   pq-vplmn + pq-hplmn + one-shot cert generator
│   └── results/{json,pcaps,logs}/  #   per-run JSON shown in the tab, plus pcaps
├── configs/                        # .conf files managed by WebUI
├── results/                        # JSON results viewed in Results tab
├── configs/Packetrusher_Configs/           # UE config .yml files
└── docker-compose.yml
```

---
