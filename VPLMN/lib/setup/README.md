# VPLMN Setup Scripts

This folder contains all scripts used during the initial setup of the VPLMN (Visited PLMN - PC1) testbed. These scripts are orchestrated by the `setup.sh` script in the parent VPLMN directory.

## Quick Start

To set up the entire VPLMN testbed from scratch:

> **First step — folder name.** The GitLab repo is `roamingtb_main`, so a fresh clone is `~/roamingtb_main`, but the scripts/docs use `~/LKN_5G_Roaming_Testbed`. `setup.sh`'s first step renames the project directory to `LKN_5G_Roaming_Testbed` and re-runs itself from the new path — so on a fresh GitLab clone use `cd ~/roamingtb_main/VPLMN && ./setup.sh` (or rename it yourself first: `mv ~/roamingtb_main ~/LKN_5G_Roaming_Testbed`).

```bash
cd ~/LKN_5G_Roaming_Testbed/VPLMN
./setup.sh
```

`.env` doesn't need to exist first — `setup.sh` prompts for `VPLMN_IP`, `HPLMN_IP`, SSH usernames, and the optional performance-server settings and creates it for you if it's missing. To fill it in ahead of time instead:

```bash
cp lib/setup/.env.template .env   # Create .env from template
nano .env                      # Fill in your IPs and credentials
./setup.sh
```

The setup script will:
- **Automatically install all prerequisites** (Docker, Docker Compose, Open5GS v2.8.0 built from source)
- **Configure IP addresses** from `.env` file across all configuration files
- **Prepare NF binaries** and distribute TLS certificates
- **Build Docker images** for all 13 network functions
- **Create external Docker networks** for service-to-service communication
- **Configure host networking** for UPF (iptables, IP forwarding, ogstun)
- **Optionally install PacketRusher** with gtp5g kernel module for UE simulation
- Log all steps to timestamped files in `setup_logs/`

**Total time: 40-60 minutes** (includes Open5GS compilation from source if needed)

## What Gets Installed Automatically

If running on a fresh/empty VM, the setup script will automatically install:

| Component | Details |
|-----------|---------|
| **Docker** | Container runtime (`docker.io` package) |
| **Docker Compose v2** | Container orchestration tool |
| **Build Dependencies** | All Open5GS compilation requirements, plus the automation tools `jq`, `bc`, strongSwan, and `sshpass` / `tshark` for the dongle scripts |
| **Open5GS v2.8.0** | Built from source at `~/open5gs/install` — skipped if a build already exists there, whatever its version. The repo ships its own v2.8.0 binaries, and `prepare_nfs.sh` ignores an install of another version, so an older build there is harmless |

You will be prompted to confirm before installation starts.

## Scripts

| Script | Purpose |
|--------|---------|
| `give_permissions.sh` | Sets execute permissions on all `.sh` files in the project (run from the project root, so it covers `setup.sh`, every NF `start_*.sh`, and `lib/features/`) |
| `configure_ip_from_env.sh` | Reads IP addresses from `.env` and updates all configuration files |
| `prepare_nfs.sh` | Copies Open5GS binaries from `~/open5gs/install` to each NF's Docker directory — only if that install is the same version as the repo's committed binaries; otherwise it keeps the repo's files (override: `PREPARE_NFS_ALLOW_VERSION_MISMATCH=1`) |
| `redistribute_certificates.sh` | Distributes TLS certificates from `lib/setup/certificates_backup/` to each NF's `files/` directory |
| `collect_certificates.sh` | The inverse of `redistribute_certificates.sh`: gathers every NF's certs/keys back into `lib/setup/certificates_backup/`. Not run by `setup.sh` — use it manually after regenerating certificates. Run from the VPLMN root. |
| `build_all.sh` | Builds the 13 VPLMN images (12 NFs + MongoDB) at `:${OPEN5GS_TAG:-v2.8.0}` — MongoDB is tagged the same for consistency (its content isn't Open5GS-derived). v2.8.0 uses one unified UPF, so there is no separate `base-open5gs` image or LBO UPF variant |
| `open5gs_network_setup.sh` | Configures host networking for UPF (iptables, IP forwarding, ogstun interface, systemd service) and the IP fragment buffer (`/etc/sysctl.d/90-ipfrag.conf`: 64 MB, 5 s; the 4 MB default overflowed with N9 IPsec) |
| `setup_sudoers.sh` | Grants the automation user passwordless sudo (`tc`, `docker`, `nsenter`, `ipsec`, `modprobe`, `rmmod`, `fuser`, `ss`, `ip`, plus `bash`/`pkill`/`true` for the WebUI's Post-Quantum tab) so batch/WebUI runs work non-interactively. Note: NOPASSWD `bash` is effectively full root for that user |
| `deploy_ipsec.sh` | End-to-end N9 IPsec setup across both PCs (run on PC1): checks/installs strongSwan, generates the CA, distributes and installs certs, then optionally starts the tunnel (PC2 first, then PC1). Answering **no** to the start prompt (or `--no-start`) still regenerates `/etc/ipsec.conf` on both PCs so the peer IPs match `.env` — see [docs/IPSEC.md](../../../docs/IPSEC.md) |

## Setup Execution Order

The `../setup.sh` script runs these steps automatically:

0. **Reclaim project ownership** — Before anything else, if any git-tracked project file (or `setup_logs/`) is owned by another user — the tell-tale of a root clone or an earlier `sudo ./setup.sh` — `setup.sh` `chown`s it back to the invoking user (via `sudo`), preventing a "Permission denied" cascade on later steps. Container-generated output (root-owned by design) is left alone.
1. **Prerequisite Check/Install** — Verify and install Docker, Docker Compose, Open5GS v2.8.0 (with user confirmation)
2. **give_permissions.sh** (Step 1) — Prepare all scripts for execution
3. **Install git post-merge hook** (Step 1.5) — so IPs are re-applied and stale Docker images are flagged after every `git pull`
4. **Verify/create `.env`** (Step 2) — If `.env` is missing, prompt for IPs, SSH usernames, and the optional performance-server settings and create it; otherwise print the current values and ask you to confirm
5. **Verify connectivity to HPLMN** (Step 2.5) — Ping-check that the HPLMN PC is reachable; on failure you're asked whether to continue
6. **Set up passwordless SSH to HPLMN** (Step 2.6) — Generate an SSH key if needed and `ssh-copy-id` to HPLMN (prompts once for the HPLMN password); needed by the IPsec and automation steps that drive PC2 over SSH
7. **Set up passwordless SSH to the performance server** (Step 2.7) — Same as 2.6, for the optional performance server used by the download/iperf/N6 tests
8. **configure_ip_from_env.sh** (Step 3) — Propagate IP addresses from `.env` to all configs
9. **prepare_nfs.sh** (Step 4) — Copy binaries from `~/open5gs/install` to each NF's Docker directory
10. **redistribute_certificates.sh** (Step 5) — Distribute TLS certificates to each NF's `files/` directory
11. **build_all.sh** (Step 6) — Build the 13 images (12 NFs + MongoDB) at `:v2.8.0`, with the single unified UPF (~10-15 minutes)
12. **Docker Network Creation** (Step 7) — Create external networks (`my_custom_network`, `my_second_network`, `my_isolated_network`)
13. **open5gs_network_setup.sh** (Step 8) — Configure host networking for UPF
14. **Verify PacketRusher directory** (Step 9) — Check that the `PacketRusher/` directory is present (warn if not)
15. **webui/setup.sh** (Step 10) — Configure the WebUI (IPs, credentials, docker group, passwordless sudo)
16. **setup_sudoers.sh** (Step 11) — Grant the automation user passwordless sudo for the delay/namespace commands the batch runner uses
17. **Prepare Browsertime** (Step 12) — Pull the Browsertime image used by the web-performance tests
18. **Generate test configs** (Step 13) — Create the batch/automation config files
19. **Generate PacketRusher UE configs** (Step 14) — Create the per-UE PacketRusher configs
20. **(Optional) PacketRusher gtp5g install** (Step 15) — Prompted: build the PacketRusher image (`packetrusher:20250225`) and install the gtp5g kernel module for UE simulation
21. **(Optional) N9 IPsec tunnel** (Step 16) — Prompted: run `deploy_ipsec.sh` to set up the HR-roaming N9 tunnel across both PCs (requires HPLMN already set up — see the setup-order note in the top-level README)
22. **(Optional) N4 IPsec tunnel** (Step 17) — Prompted: generate the SMF ⇄ UPF certificates and pre-configure both ends; the tunnel stays off until started (WebUI or `docker/n4-ipsec/n4_ipsec.sh start`)
23. **(Optional) Commercial RAN** (Step 18) — Prompted: enable the real gNB + dongle UE support (`lib/features/set-dongle-mode.sh`): asks for the control host, gNB host and RU settings, and installs the SSH key on the control host and gNB host — see [docs/COMMERCIAL_RAN.md](../../../docs/COMMERCIAL_RAN.md)

## Prerequisites (Automatic in setup.sh)

The `setup.sh` script will automatically check and install these prerequisites on a fresh Ubuntu VM:

- **Docker** and **Docker Compose v2** (with user confirmation before installation)
- **Open5GS v2.8.0** built from source at `~/open5gs/install` (with user confirmation before compilation)
- **Build dependencies** for Open5GS compilation

If you prefer to install these manually first, run:
```bash
# Install dependencies
sudo apt install python3-pip python3-setuptools python3-wheel ninja-build \
  build-essential flex bison git cmake libsctp-dev libgnutls28-dev \
  libgcrypt-dev libssl-dev libmongoc-dev libbson-dev libyaml-dev \
  libnghttp2-dev libmicrohttpd-dev libcurl4-gnutls-dev libtins-dev \
  libtalloc-dev meson docker.io docker-compose-plugin \
  jq bc strongswan strongswan-pki strongswan-starter sshpass tshark
```

## Manual Step-by-Step Setup (Advanced)

If you need to run individual setup steps manually:

```bash
cd ~/LKN_5G_Roaming_Testbed/VPLMN

# These scripts are in the lib/setup/ folder and called by setup.sh
# They can be run individually if needed:
bash lib/setup/give_permissions.sh              # Set execute permissions
bash lib/setup/configure_ip_from_env.sh         # Propagate IPs to all configs
bash lib/setup/prepare_nfs.sh                   # Copy binaries
bash lib/setup/redistribute_certificates.sh     # Restore TLS certificates
bash lib/setup/build_all.sh                     # Build Docker images
sudo bash lib/setup/open5gs_network_setup.sh    # Configure networking
bash lib/setup/setup_sudoers.sh                 # Passwordless sudo for batch/WebUI runs
```

> **Note:** run `setup_sudoers.sh` as your normal user (not with `sudo`) — it targets whoever invokes it and calls `sudo` itself only to install the drop-in. It's required for batch/WebUI runs: the automation applies network delays and enters the UE container's namespace with `sudo tc` / `sudo docker` / `sudo nsenter`, which fail non-interactively without passwordless sudo.

## Configuration Requirements

Before running setup, ensure:

- **`.env` file** in the VPLMN directory — optional to create ahead of time; `setup.sh` prompts for these values and creates it for you if it's missing. To fill it in yourself instead:
  ```bash
  cp lib/setup/.env.template .env
  ```
  Fill in these variables:
  - `VPLMN_IP=<your VPLMN PC IP>`
  - `HPLMN_IP=<HPLMN PC IP>`
  - `VPLMN_USER=<your SSH username on this PC>`
  - `HPLMN_USER=<your SSH username on PC2>`
  - `PERF_SERVER_IP=<performance server IP, if used>`
  - `PERF_SERVER_USER=<performance server SSH username, if used>`
- **Sudo access** available (needed for iptables and kernel module installation; Docker should be usable through the `docker` group)
- **Network connectivity** to download Docker images, Open5GS source, and PacketRusher
- **(If installing PacketRusher)** Secure Boot must be disabled in BIOS

## Important Notes

- **Setup is one-time only** — not used during runtime operations
- **Each script is idempotent** — safe to run multiple times
- **All steps are logged** to `setup_logs/` inside the VPLMN directory with timestamps
- **open5gs_network_setup.sh** creates a systemd service (`open5gs-network-setup.service`) for persistence across reboots
- **Docker networks** are created as external bridges so they persist across `docker compose down/up` cycles
- **PacketRusher installation** requires Secure Boot disabled; script checks this before attempting gtp5g kernel module installation; the Docker image is built from source by `docker/packetrusher-docker/build_packetrusher.sh` (→ `packetrusher:20250225`, upstream HewlettPackard/PacketRusher with the PR #135 uplink-QFI fix), replacing the old `ghcr.io/borjis131/packetrusher:main` fork

## After Setup Completes

Once setup finishes successfully, you're ready to run the testbed:

```bash
cd ~/LKN_5G_Roaming_Testbed/VPLMN

# 1. Select roaming mode (HR, LBO, or Non-Roaming)
./lib/features/set-open5gs-mode.sh

# 2. Start the testbed (logs will stream to terminal)
docker compose up

# In another terminal:
# 3. (Optional) Start UE simulation with PacketRusher
./lib/features/start_packetrusher.sh
```

## Verification

After setup completes, verify everything is installed:

```bash
# Check Open5GS binaries
ls -la ~/open5gs/install/bin/

# Check Docker networks were created
docker network ls | grep -E 'my_custom_network|my_second_network|my_isolated_network'

# Check Docker images were built
docker images | grep open5gs

# Check PacketRusher (if installed)
ls -la ~/LKN_5G_Roaming_Testbed/VPLMN/PacketRusher/
lsmod | grep gtp5g
```

## Troubleshooting

**Check setup logs for detailed error messages:**
```bash
cat setup_logs/setup_*.log  # View most recent setup log from the VPLMN directory
```

**Common issues:**
- **Setup appears stuck on a "Newer kernel available" / "which services to restart?" screen**: This is Ubuntu's `needrestart` prompt that pops up after a package install — it is *not* a crash. Just keep pressing **Enter** (and `q` if you see a `[More]` pager) until it dismisses, and setup will continue on its own.
- **Docker permission denied**: Add your user to the docker group: `sudo usermod -aG docker $USER`, then log out and back in.
- **Open5GS build fails**: Check `setup_*.log` for missing dependencies; some may need manual installation
- **PacketRusher module compilation fails**: Verify Secure Boot is disabled in BIOS
- **Network setup fails**: Run again later or see [VPLMN README](../../README.md) for manual configuration

For more help, see:
- [VPLMN README](../../README.md) — Full setup and troubleshooting guide
- Setup logs: `setup_logs/setup_*.log` inside the VPLMN directory
- Test results: `setup_logs/test_*.log` inside the VPLMN directory
