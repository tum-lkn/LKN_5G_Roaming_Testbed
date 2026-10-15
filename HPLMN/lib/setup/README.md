# HPLMN Setup Scripts

This folder contains all scripts used during the initial setup of the HPLMN (Home PLMN - PC2) testbed. These scripts are orchestrated by the `setup.sh` script in the parent HPLMN directory.

## Quick Start

To set up the entire HPLMN testbed from scratch:

> **First step — folder name.** The GitLab repo is `roamingtb_main`, so a fresh clone is `~/roamingtb_main`, but the scripts/docs use `~/LKN_5G_Roaming_Testbed`. `setup.sh`'s first step renames the project directory to `LKN_5G_Roaming_Testbed` and re-runs itself from the new path — so on a fresh GitLab clone use `cd ~/roamingtb_main/HPLMN && ./setup.sh` (or rename it yourself first: `mv ~/roamingtb_main ~/LKN_5G_Roaming_Testbed`).

```bash
cd ~/LKN_5G_Roaming_Testbed/HPLMN
./setup.sh
```

The setup script will:
- **Automatically install all prerequisites** (Docker, Docker Compose, Open5GS v2.8.0 built from source)
- **Configure IP addresses** from `.env` file across all configuration files
- **Prepare NF binaries** and distribute TLS certificates
- **Build Docker images** for all 13 network functions
- **Create external Docker networks** for service-to-service communication
- **Configure host networking** for UPF (iptables, IP forwarding, ogstun)
- Log all steps to timestamped files in `setup_logs/`

**Total time: 40-60 minutes** (includes Open5GS compilation from source if needed)

## What Gets Installed Automatically

If running on a fresh/empty VM, the setup script will automatically install:

| Component | Details |
|-----------|---------|
| **Docker** | Container runtime (`docker.io` package) |
| **Docker Compose v2** | Container orchestration tool |
| **Build Dependencies** | All Open5GS compilation requirements |
| **Open5GS v2.8.0** | Built from source at `~/open5gs/install` — skipped if a build already exists there, whatever its version. The repo ships its own v2.8.0 binaries, and `prepare_nfs.sh` ignores an install of another version, so an older build there is harmless |

You will be prompted to confirm before installation starts.

## Scripts

| Script | Purpose |
|--------|---------|
| `give_permissions.sh` | Sets execute permissions on all `.sh` files in the project (run from the project root, so it covers `setup.sh`, every NF `start_*.sh`, and `lib/features/`) |
| `configure_ip_from_env.sh` | Reads IP addresses from `.env` and updates all configuration files |
| `prepare_nfs.sh` | Copies Open5GS binaries from `~/open5gs/install` to each NF's Docker directory — only if that install is the same version as the repo's committed binaries; otherwise it keeps the repo's files (override: `PREPARE_NFS_ALLOW_VERSION_MISMATCH=1`) |
| `redistribute_certificates.sh` | Distributes TLS certificates from `lib/setup/certificates_backup/` to each NF's `files/` directory |
| `collect_certificates.sh` | The inverse of `redistribute_certificates.sh`: gathers every NF's certs/keys back into `lib/setup/certificates_backup/`. Not run by `setup.sh` — use it manually after regenerating certificates. Run from the HPLMN root. |
| `build_all.sh` | Builds the 13 HPLMN images (12 NFs + MongoDB) at `:${OPEN5GS_TAG:-v2.8.0}` — MongoDB is tagged the same for consistency (its content isn't Open5GS-derived). v2.8.0 uses one unified UPF built from `files/`, so there is no separate `base-open5gs` image any more |
| `open5gs_network_setup.sh` | Configures host networking for UPF (iptables, IP forwarding, ogstun interface, systemd service) and the IP fragment buffer (`/etc/sysctl.d/90-ipfrag.conf`: 64 MB, 5 s; the 4 MB default overflowed with N9 IPsec) |
| `setup_sudoers.sh` | Grants the HPLMN user passwordless sudo for `docker`, `ipsec`, `tc`, `sed` and `bash` (effectively full root, as on VPLMN). Required because the VPLMN WebUI and automation control HPLMN over SSH with non-interactive `sudo docker compose` (start/stop), `sudo docker exec` (N6 delays), `sudo tc` (delay rules), `sudo ipsec` (HR tunnel), `sudo sed` on `/etc/ipsec.conf` (N9 cipher change) and `sudo -n bash n4_ipsec.sh` (N4 IPsec) — without it, "Start HPLMN" in the WebUI fails with "sudo: a terminal is required to read the password". |

## Setup Execution Order

The `../setup.sh` script runs these steps automatically:

0. **Reclaim project ownership** — Before anything else, if any git-tracked project file (or `setup_logs/`) is owned by another user — the tell-tale of a root clone or an earlier `sudo ./setup.sh` — `setup.sh` `chown`s it back to the invoking user (via `sudo`). This prevents the confusing "Permission denied" / "chmod: Operation not permitted" cascade on later steps. Container-generated output (root-owned by design) is left alone.
1. **Prerequisite Check/Install** — Verify and install Docker, Docker Compose, Open5GS v2.8.0 (with user confirmation)
2. **give_permissions.sh** — Prepare all scripts for execution
3. **Install git post-merge hook** (Step 1.5) — Install `post-merge.hook` into `.git/hooks/` so IPs are re-applied and stale Docker images are flagged after every `git pull`
4. **Verify/create `.env`** (Step 2) — If `.env` is missing, prompt for `HPLMN_IP`/`VPLMN_IP` and create it; otherwise print the current values and ask you to confirm them before continuing
5. **Verify connectivity to VPLMN** (Step 2.5) — Ping-check that the VPLMN PC (`VPLMN_IP`) is reachable; on failure you're asked whether to continue anyway
6. **configure_ip_from_env.sh** (Step 3) — Propagate IP addresses from `.env` to all configs
7. **prepare_nfs.sh** (Step 4) — Copy binaries from `~/open5gs/install` to each NF's Docker directory
8. **redistribute_certificates.sh** (Step 5) — Distribute TLS certificates to each NF's `files/` directory
9. **build_all.sh** (Step 6) — Build the 13 images (12 NFs + MongoDB) at `:v2.8.0`, with the single unified UPF (~10-15 minutes)
10. **Docker Network Creation** (Step 7) — Create external network (`my_custom_network` on 192.168.60.0/24)
11. **open5gs_network_setup.sh** (Step 8) — Configure host networking for UPF
12. **setup_sudoers.sh** (Step 9) — Grant passwordless sudo for `docker`/`ipsec`/`tc`/`sed`/`bash` so the VPLMN WebUI and automation can control HPLMN over SSH
13. **(Optional) N4 IPsec tunnel** (Step 10) — Prompted: generate the SMF ⇄ UPF certificates and pre-configure both ends; the tunnel stays off until started (VPLMN WebUI or `docker/n4-ipsec/n4_ipsec.sh start`)

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
  libtalloc-dev meson docker.io docker-compose-plugin
```

## Manual Step-by-Step Setup (Advanced)

If you need to run individual setup steps manually:

> **Run the file-preparation scripts as your normal user — do not prefix them with `sudo`.** `give_permissions.sh`, `configure_ip_from_env.sh`, `prepare_nfs.sh`, and `redistribute_certificates.sh` (and the per-NF `start_*.sh` that `prepare_nfs.sh` calls) resolve paths through `~`/`$HOME`. Under `sudo`, `~` becomes `/root`, so copies into `~/LKN_5G_Roaming_Testbed/.../source_file/` fail with `cp: cannot create regular file '/root/LKN_5G_Roaming_Testbed/...': No such file or directory`. Add your user to the `docker` group once (`sudo usermod -aG docker $USER`, then log out and back in) so Docker build steps can run without prefixing them with `sudo`. Host networking setup still needs root for iptables and system settings.
>
> `prepare_nfs.sh` resolves the HPLMN root from its own location, so it can be launched from the HPLMN root or directly from `lib/setup/`. `redistribute_certificates.sh` should still be run from the HPLMN root.

```bash
cd ~/LKN_5G_Roaming_Testbed/HPLMN

# These scripts are in the lib/setup/ folder and called by setup.sh
# They can be run individually if needed:
bash lib/setup/give_permissions.sh              # Set execute permissions
bash lib/setup/configure_ip_from_env.sh         # Propagate IPs to all configs
bash lib/setup/prepare_nfs.sh                   # Copy binaries
bash lib/setup/redistribute_certificates.sh     # Restore TLS certificates
bash lib/setup/build_all.sh                     # Build Docker images
sudo bash lib/setup/open5gs_network_setup.sh    # Configure networking
bash lib/setup/setup_sudoers.sh                 # Passwordless sudo for WebUI remote control
```

## Configuration Requirements

Before running setup, ensure:

- **`.env` file** in HPLMN directory with:
  - `VPLMN_IP=<VPLMN PC IP>`
  - `HPLMN_IP=<your HPLMN PC IP>`
- **Sudo access** available (needed for iptables configuration; Docker should be usable through the `docker` group)
- **Network connectivity** to download Docker images, Open5GS source, and dependencies
- **Network connectivity to VPLMN (PC1)** for roaming tests (required during runtime, not setup)

## Important Notes

- **Setup is one-time only** — not used during runtime operations
- **Each script is idempotent** — safe to run multiple times
- **All steps are logged** to `setup_logs/` (inside the HPLMN directory) with timestamps
- **open5gs_network_setup.sh** creates a systemd service (`open5gs-network-setup.service`) for persistence across reboots
- **Docker network** (`my_custom_network` on 192.168.60.0/24) is external so it persists across `docker compose down/up` cycles
- **HPLMN does not run PacketRusher** — only the VPLMN (PC1) runs UE simulation

## After Setup Completes

Once setup finishes successfully, you're ready to run the testbed:

```bash
cd ~/LKN_5G_Roaming_Testbed/HPLMN

# 1. Select security mode (TLS or Non-TLS / plain HTTP)
./lib/features/set-open5gs-mode.sh

# 2. Start the testbed (logs will stream to terminal)
docker compose up
```

> **Note:** Start HPLMN before VPLMN for successful roaming configuration.

## Verification

After setup completes, verify everything is installed:

```bash
# Check Open5GS binaries
ls -la ~/open5gs/install/bin/

# Check Docker network was created
docker network ls | grep my_custom_network

# Check Docker images were built
docker images | grep open5gs
```

## Troubleshooting

**Check setup logs for detailed error messages:**
```bash
cat setup_logs/setup_*.log  # View most recent setup log (run from the HPLMN directory)
```

**Common issues:**
- **Setup appears stuck on a "Newer kernel available" / "which services to restart?" screen**: This is Ubuntu's `needrestart` prompt that pops up after a package install — it is *not* a crash. Just keep pressing **Enter** (and `q` if you see a `[More]` pager) until it dismisses, and setup will continue on its own.
- **`cp: cannot create regular file '/root/LKN_5G_Roaming_Testbed/.../source_file/': No such file or directory`**: You ran a file-preparation script (usually `prepare_nfs.sh`) with `sudo`, so `~` resolved to `/root` instead of your home. Re-run it **without** `sudo`, from the testbed root. Each NF `start_*.sh` now verifies its binary and `source_file/main.c` actually landed and exits non-zero (printing `ERROR: <NF> preparation incomplete`) if a copy failed, so `prepare_nfs.sh` reports the real per-NF status — a failed copy is no longer counted as "success."
- **`Error: docker-compose.yml not found!`**: Make sure `~/LKN_5G_Roaming_Testbed/HPLMN/docker-compose.yml` exists and the script is still inside the repository. `prepare_nfs.sh` resolves the HPLMN root automatically; `redistribute_certificates.sh` should be run from the HPLMN root.
- **Docker permission denied**: Add your user to the docker group (preferred): `sudo usermod -aG docker $USER`, then log out and back in. Do **not** work around this by running the file-preparation scripts with `sudo` — that breaks their `~`-based paths (see the `cp: cannot create regular file` issue above).
- **Open5GS build fails**: Check `setup_*.log` for missing dependencies; some may need manual installation
- **Network setup fails**: Run again later or see [HPLMN README](../../README.md) for manual configuration

For more help, see:
- [HPLMN README](../../README.md) — Full setup and troubleshooting guide
- Setup logs: `setup_logs/setup_*.log` (inside the HPLMN directory)
