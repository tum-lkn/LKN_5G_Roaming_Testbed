# HPLMN (Home Network) — Setup Guide

This guide covers the installation and configuration of the **Home PLMN (PC2)** side of the testbed.

For a general overview of the testbed architecture and supported modes, see the [main README](../README.md). For detailed explanations of each installation step, script behavior, TLS certificate management, and troubleshooting, see the [VPLMN Setup Guide](../VPLMN/README.md) — the procedures are the same unless noted below.

---

## Differences from VPLMN

| Aspect | VPLMN (PC1) | HPLMN (PC2) |
|--------|-------------|-------------|
| PLMN Identity | MCC: 999, MNC: 071 | MCC: 001, MNC: 001 |
| Core network subnet | `192.168.50.0/24` | `192.168.60.0/24` |
| PacketRusher | Yes | **No** — UE simulation runs on VPLMN only |
| Secondary UPF (`upf2-docker/`) | Yes (for LBO) | **No** |
| Automation scripts | `testbed_automation.sh`, `batch_runner.sh` | **No** — automation is run from VPLMN |
| Default IP in configs (rewritten from `.env` by `configure_ip_from_env.sh`) | `10.0.0.10` (VPLMN) | `10.0.0.21` (HPLMN) |
| SEPP extra_hosts maps | `sepp2.localdomain` → HPLMN IP | `sepp1.localdomain` → VPLMN IP |
| Certificate FQDNs | `*.mnc071.mcc999.3gppnetwork.org` | `*.mnc001.mcc001.3gppnetwork.org` |

---

## Installation

### Quick Start (Fully Automated)

The `setup.sh` script automates the entire HPLMN setup process, including prerequisite installation. Simply run:

> **First step — project folder name.** The GitLab repository is named `roamingtb_main`, so a fresh `git clone` creates `~/roamingtb_main`, but the testbed's scripts and docs use the path `~/LKN_5G_Roaming_Testbed`. `setup.sh`'s **very first step renames the project directory to `LKN_5G_Roaming_Testbed`** and re-runs itself from the new path. So on a fresh GitLab clone just `cd ~/roamingtb_main/HPLMN && ./setup.sh`. (If it's already named `LKN_5G_Roaming_Testbed`, the step is a no-op; you can also rename it yourself first: `mv ~/roamingtb_main ~/LKN_5G_Roaming_Testbed`.)

```bash
cd ~/LKN_5G_Roaming_Testbed/HPLMN
./setup.sh
```

You don't need to create `.env` beforehand — if it's missing, `setup.sh` prompts you for `HPLMN_IP`, `VPLMN_IP`, and the other values and creates it for you. Pre-creating it is optional, useful mainly if you want to fill it in without answering prompts:

```bash
cp lib/setup/.env.template .env
nano .env  # Set HPLMN_IP, VPLMN_IP, and other credentials
./setup.sh
```

The setup script will automatically:
- Install Docker, Docker Compose, and Open5GS v2.8.0 (with user confirmation)
- Configure IP addresses across all configuration files
- Prepare NF binaries and restore TLS certificates
- Build all Docker images
- Create external Docker network
- Configure host networking for UPF
- Configure passwordless sudo (`docker`, `ipsec`, `tc`, `sed`, `bash`) so the VPLMN WebUI and automation can control HPLMN over SSH
- Optionally set up the N4 (SMF ⇄ UPF) IPsec tunnel (certificates + config; the tunnel stays off until started)

**Total time: 40-60 minutes** (includes Open5GS compilation from source if needed)

See [lib/setup/README.md](lib/setup/README.md) for complete setup documentation.

---

### Manual Setup

> **Note:** The steps below are only needed if you are **not** using `setup.sh`. If you ran the automated setup above, your testbed is ready — skip to [Running the Testbed](#running-the-testbed).

> **Run the file-preparation steps as your normal user (no `sudo`).** `give_permissions.sh`, `configure_ip_from_env.sh`, `prepare_nfs.sh`, and `redistribute_certificates.sh` (and the per-NF `start_*.sh` that `prepare_nfs.sh` calls) resolve paths through `~`/`$HOME`; running them with `sudo` makes `~` resolve to `/root` and the copies fail with `cp: cannot create regular file '/root/LKN_5G_Roaming_Testbed/...': No such file or directory`. Add your user to the `docker` group once — `sudo usermod -aG docker $USER`, then log out and back in — so Docker build steps can run without prefixing them with `sudo`. Host networking setup still needs root for iptables and system settings.

### Build Open5GS from Source

Same as VPLMN — see [VPLMN Prerequisites](../VPLMN/README.md#build-open5gs-from-source).

### Step 1: Set Script Permissions

Grant execute permissions to all `.sh` files in the project:

```bash
cd ~/LKN_5G_Roaming_Testbed/HPLMN
bash lib/setup/give_permissions.sh
```

### Step 2: Configure IP Addresses

If `.env` doesn't exist yet, create it from the template:

```bash
cp lib/setup/.env.template .env
```

Then edit the variables to match your machines:

```bash
nano .env
```

Update these lines:
```
HPLMN_IP=<your HPLMN machine IP>
VPLMN_IP=<your VPLMN machine IP>
```

Then propagate the new IPs to all configuration files:

```bash
bash lib/setup/configure_ip_from_env.sh
```

The script reads `VPLMN_IP` and `HPLMN_IP` from `.env` and updates every file that contains IP addresses.

**Files updated by the script:**

| File | IP Updated | Purpose |
|------|------------|---------|
| `docker/upf-docker/upf.yaml` & `upf_tls.yaml` | HPLMN IP | GTP-U bind address for N9 (UPF-UPF) traffic in HR mode |
| `docker/smf-docker/smf.yaml` & `smf_tls.yaml` | HPLMN IP | UPF address for PFCP (N4 interface) |
| `docker-compose.yml` | VPLMN IP | SEPP extra_hosts — maps `sepp1.localdomain` to the VPLMN PC |
| `docker/sepp-docker/sepp.yaml` | VPLMN IP | Remote SEPP peer address for N32 signaling |
| `docker/ipsectunnel/01_setup_ca.sh` | Both IPs | Hardcoded `VPLMN_IP`/`HPLMN_IP` variables used when generating IPsec CA and peer certificates |
| `docker/ipsectunnel/ipsec_certificates/pc1/03_setup_ipsec_pc1_cert.sh` | Both IPs | Hardcoded `VPLMN_IP`/`HPLMN_IP` — PC1 strongSwan tunnel endpoint IPs |
| `docker/ipsectunnel/ipsec_certificates/pc2/03_setup_ipsec_pc2_cert.sh` | Both IPs | Hardcoded `VPLMN_IP`/`HPLMN_IP` — PC2 strongSwan tunnel endpoint IPs |

> **Note:** `lib/features/set-open5gs-mode.sh` preserves the IP lines in `.env` when it rewrites the file — your IP configuration will not be lost when switching security modes.

### Step 3: Prepare NF Binaries

Copy the compiled Open5GS binaries from your local installation (`~/open5gs/install`) into each NF's `files/` directory:

```bash
bash lib/setup/prepare_nfs.sh
```

The script supports two modes: **initial setup** (all NFs at once) or **selective** (choose specific NFs to update). The script checks that `~/open5gs/install` exists before proceeding. It only copies when `~/open5gs/install` is the **same Open5GS version the repo is at** (read from the committed daemons in git). The repo ships its own v2.8.0 binaries, and an install of another version would silently change the tree's version — and the next image build would mix daemons and `libogs` from different releases (`symbol lookup error` / `stack smashing`). On a mismatch it copies nothing, says so, and exits successfully; the repo's own files are used. Set `PREPARE_NFS_ALLOW_VERSION_MISMATCH=1` to move the repo to a different release on purpose.

> Run it **without `sudo`**. It resolves the HPLMN root from its own location and copies binaries into the `docker/<nf>-docker/` directories, so it no longer depends on your current working directory. Running under `sudo` can still break `~`-based paths (`~` → `/root`).

### Step 4: Restore TLS Certificates

Distribute pre-generated certificates from `lib/setup/certificates_backup/` into each NF's `files/` directory:

```bash
bash lib/setup/redistribute_certificates.sh
```

Sets proper file permissions: `644` for `.crt`, `600` for `.key`. For details on the certificates, see the [VPLMN TLS Certificate Management](../VPLMN/README.md#tls-certificate-management) section.

### Step 5: Build Docker Images

Build Docker images for all HPLMN network functions:

```bash
bash lib/setup/build_all.sh
```

Build time is approximately 10–15 minutes. All builds are chained — if any single build fails, the subsequent builds will not execute.

### Step 6: Create Docker Network

The Docker Compose file uses an **externally-managed network** that must exist before you run `docker compose up`. Create it once — it persists across `docker compose down` / `up` cycles:

```bash
docker network create --driver bridge --subnet 192.168.60.0/24 my_custom_network
```

This command is idempotent — if the network already exists, Docker will return an error that can be safely ignored.

### Step 7: Configure Host Networking

Configure IP forwarding, NAT rules, and the `ogstun` TUN interface on the host:

```bash
sudo bash lib/setup/open5gs_network_setup.sh
```

This also installs a systemd service to persist the settings across reboots, and sets the IP fragment buffer (`/etc/sysctl.d/90-ipfrag.conf`: 64 MB, 5 s; the 4 MB default overflowed with N9 IPsec). See the [VPLMN Host Networking](../VPLMN/README.md#step-8-configure-host-networking) section for full details on what the script configures.

## Running the Testbed

> **Important:** The HPLMN should be started **before** the VPLMN, as the VPLMN's SEPP needs to connect to the HPLMN's SEPP over the N32 interface during startup.

### Docker Network

The HPLMN Compose file uses an externally-managed network (`my_custom_network`, `192.168.60.0/24`) created in [Step 6](#step-6-create-docker-network) of the installation. If you've already run `setup.sh` or Step 6, it is already in place.

To verify it exists:
```bash
docker network ls | grep my_custom_network
```

### Start Services

```bash
cd ~/LKN_5G_Roaming_Testbed/HPLMN
./lib/features/set-open5gs-mode.sh    # Select the security mode (TLS / Non-TLS) — must match VPLMN security
docker compose up
```

Then start the VPLMN on PC1 — see the [VPLMN Running Guide](../VPLMN/README.md#running-the-testbed).

### Verify Deployment

```bash
docker compose ps
docker compose logs
docker logs open5gs-nrf
docker logs open5gs-sepp
```

Key things to look for:
- **NRF** — all NFs successfully registered
- **SEPP** — N32 interface listening and ready for connection from VPLMN SEPP
- **UPF** — `ogstun` created successfully (relevant in HR mode where HPLMN UPF provides the Data Network breakout)

### Stop Services

```bash
docker compose down
```

---

## IPsec Tunnel (N9, Home-Routed mode)

In Home-Routed roaming the N9 interface (VPLMN UPF ↔ HPLMN UPF) can be protected by an IPsec tunnel. The tunnel is managed by [`docker/ipsectunnel/ipsec_tunnel.sh`](docker/ipsectunnel/ipsec_tunnel.sh), which drives **both PCs at once** — it auto-detects whether it is running on the VPLMN (PC1, initiator) or HPLMN (PC2, responder) and configures the peer over SSH.

```bash
cd ~/LKN_5G_Roaming_Testbed/HPLMN/docker/ipsectunnel

./ipsec_tunnel.sh start    # Bring the tunnel up on both PCs (PC2 first, then PC1)
./ipsec_tunnel.sh status   # Show the Security Association on both PCs
./ipsec_tunnel.sh stop     # Tear the tunnel down and flush xfrm state/policy on both PCs
```

**Requirements:**
- SSH key-based auth to the other PC, and passwordless (or cached) `sudo` on both machines.
- The following variables in `.env` (in addition to `HPLMN_IP` / `VPLMN_IP`):
  ```
  HPLMN_USER=<login user on this (HPLMN) PC>
  VPLMN_USER=<login user on the VPLMN PC>
  ```
  These are used for the SSH connection to the remote PC. If omitted, the current user (`whoami`) is assumed on both ends.

One-time certificate setup and full details are in the [IPsec Tunnel guide](../docs/IPSEC.md).

---

## N4 (PFCP) IPsec

The N4 interface (SMF ⇄ UPF, PFCP/UDP 8805) can be secured with IPsec ESP independently of the N9 tunnel — see [`docker/n4-ipsec/README.md`](docker/n4-ipsec/README.md).

---

## SEPP Mutual TLS (mTLS) on N32

The SEPP ships two config files: `docker/sepp-docker/sepp_tls.yaml` (server-side TLS) and `docker/sepp-docker/sepp_tls_mtls.yaml` (mutual TLS — each SEPP verifies the peer's client certificate on N32). To require mTLS, select the `_mtls` file on the SEPP **on both PLMNs**. `verify_client` is scoped to the `n32.server` block only; do **not** move it to the `default` server block or the SEPP will demand a client cert on its SBI `:443` socket and break its own core (roaming registration fails with 5GMM cause #90). See the [top-level README](../README.md#inter-plmn-security--sepp-tls--mtls).

---

## Subscribers

The HPLMN MongoDB is seeded automatically (`docker/mongodb-docker/start_services.sh`) with **only the roaming subscribers it is home to** — `001010000000001…` (LBO) and `001010000001001…` (HR), using the HPLMN's own K/OPc (distinct from the VPLMN's). Non-roaming subscribers belong to the VPLMN DB. See [Subscribers & Credentials](../README.md#subscribers--credentials).

---

## Troubleshooting

For detailed troubleshooting steps, see the [VPLMN Troubleshooting](../VPLMN/README.md#troubleshooting) section. The same common issues and solutions apply. HPLMN-specific notes:

- **Setup fails with `cp: cannot create regular file '/root/LKN_5G_Roaming_Testbed/.../source_file/': No such file or directory`:** You ran a file-preparation script (usually `prepare_nfs.sh` / `setup.sh`) with `sudo`, so `~` resolved to `/root`. Re-run **without** `sudo` from the HPLMN root. See the [Manual Setup](#manual-setup) note above.
- **`prepare_nfs.sh` errors with `docker-compose.yml not found`:** Make sure the repository layout is intact and `~/LKN_5G_Roaming_Testbed/HPLMN/docker-compose.yml` exists. The script resolves the HPLMN root automatically, so this error usually means the file is missing or the script was copied outside the repository.
- **SEPP not accepting connections:** Verify the HPLMN is fully started before launching the VPLMN. Check that ports 8080 and 8081 are accessible from the VPLMN PC (`nc -zv <HPLMN_IP> 8080`). Check firewall rules with `sudo ufw status`.
- **No internet from UE in HR mode:** In Home Routed mode, UE traffic exits through the HPLMN UPF. Ensure `open5gs_network_setup.sh` has been run on this PC so NAT and forwarding are configured.
- **Duplicate routes:** Check with `ip route show | grep "192.168.60.0/24"` (note: HPLMN uses `192.168.60.0/24`, not `192.168.50.0/24`).
- **Crashes right after a `git pull`** (`symbol lookup error: ... ogs_home_network_domain_from_fqdn`, `*** stack smashing detected ***`, or `No amf.ngap.address`): stale Docker images — the pulled binaries run against the old `libogs` baked into images built before the pull. The installed `post-merge` hook flags this automatically; to fix manually, follow [VPLMN → Crashes After a `git pull`](../VPLMN/README.md#crashes-after-a-git-pull-stale-docker-images), but run the commands from `HPLMN`.

---

## Further Documentation

| Document | Description |
|----------|-------------|
| [Main README](../README.md) | Project overview, architecture, and network configuration |
| [VPLMN Setup Guide](../VPLMN/README.md) | Full installation details, PacketRusher, TLS certificates, and troubleshooting |
| [Automation Scripts](../docs/AUTOMATION.md) | Testbed automation script usage and config format |
| [Batch Runner](../docs/BATCH_RUNNER.md) | Running batch experiments across multiple configurations |
| [IPsec Tunnel (N9)](../docs/IPSEC.md) | Establishment of the IPsec tunnel for the N9 interface during HR roaming |
| [N4 (PFCP) IPsec](docker/n4-ipsec/README.md) | Securing the N4 (SMF ⇄ UPF, PFCP) interface with IPsec ESP in tunnel mode |
| [Web UI](../VPLMN/webui/README.md) | Browser-based Web UI for managing, monitoring, and automating the testbed |
