# VPLMN (Visited Network) — Setup Guide

This guide covers the installation, configuration, and operation of the **Visited PLMN (PC1)** side of the testbed.

For a general overview of the testbed architecture and supported modes, see the [main README](../README.md).

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Directory Structure](#directory-structure)
- [Installation](#installation)
- [Deployment Modes](#deployment-modes)
- [Running the Testbed](#running-the-testbed)
- [UE Simulation with PacketRusher](#ue-simulation-with-packetrusher)
- [Post-Quantum IKEv2 Evaluation](#post-quantum-ikev2-evaluation)
- [TLS Certificate Management](#tls-certificate-management)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

- Ubuntu 20.04/22.04 LTS
- Docker and Docker Compose (v2)
- Open5GS v2.7.6 built from source
- PacketRusher with the gtp5g kernel module
- Network connectivity to PC2 (HPLMN)

---

## Installation

### Quick Start (Fully Automated)

The `setup.sh` script automates the entire VPLMN setup process, including prerequisite installation. Simply run:

```bash
cd ~/LKN_5G_Roaming_Testbed/VPLMN
./setup.sh
```

You don't need to create `.env` beforehand — if it's missing, `setup.sh` prompts you for `VPLMN_IP`, `HPLMN_IP`, SSH usernames, and the optional performance-server settings, and creates it for you. Pre-creating it is optional, useful mainly if you want to fill it in without answering prompts:

```bash
cp lib/setup/.env.template .env
nano .env  # Set VPLMN_IP, HPLMN_IP, and other credentials
./setup.sh
```

The setup script will automatically:
- Install Docker, Docker Compose, and Open5GS v2.7.6 (with user confirmation)
- Configure IP addresses across all configuration files
- Prepare NF binaries and restore TLS certificates
- Build all Docker images
- Create external Docker networks
- Configure host networking for UPF
- Optionally install PacketRusher with gtp5g kernel module

**Total time: 40-60 minutes** (includes Open5GS compilation from source if needed)

See [lib/setup/README.md](lib/setup/README.md) for complete setup documentation.

---

### Manual Setup

> **Note:** The steps below are only needed if you are **not** using `setup.sh`. If you ran the automated setup above, your testbed is ready — skip to [Deployment Modes](#deployment-modes).

### Build Open5GS from Source

Before building Docker images, you must build Open5GS following the [official build guide](https://open5gs.org/open5gs/docs/guide/02-building-open5gs-from-sources/).

> **Important:** Install all required libraries before building.

```bash
# Install dependencies
sudo apt install python3-pip python3-setuptools python3-wheel ninja-build \
  build-essential flex bison git cmake libsctp-dev libgnutls28-dev \
  libgcrypt-dev libssl-dev libmongoc-dev libbson-dev libyaml-dev \
  libnghttp2-dev libmicrohttpd-dev libcurl4-gnutls-dev libnghttp2-dev \
  libtins-dev libtalloc-dev meson

# Clone and build (v2.7.6)
git clone https://github.com/open5gs/open5gs
cd open5gs
meson build --prefix=`pwd`/install
ninja -C build
ninja -C build install
```

---

### Step 1: Set Script Permissions

The testbed includes multiple shell scripts for building, configuring, and running the network functions. Before proceeding, grant execute permissions to all `.sh` files in the project:

```bash
cd ~/LKN_5G_Roaming_Testbed/VPLMN
bash lib/setup/give_permissions.sh
```

### Step 2: Configure IP Addresses

IP addresses are managed through the `.env` file, which is the single source of truth for the entire testbed. If `.env` doesn't exist yet, create it from the template:

```bash
cp lib/setup/.env.template .env
```

Then edit the variables to match your machines:

```bash
nano .env
```

Update these lines:
```
VPLMN_IP=<your VPLMN machine IP>
HPLMN_IP=<your HPLMN machine IP>
VPLMN_USER=<your SSH username on this PC>
HPLMN_USER=<your SSH username on PC2>
PERF_SERVER_IP=<performance server IP, if used>
PERF_SERVER_USER=<performance server SSH username, if used>
```

Then propagate the new IPs to all configuration files:

```bash
bash lib/setup/configure_ip_from_env.sh
```

The script reads `VPLMN_IP` and `HPLMN_IP` from `.env` and updates every file that contains IP addresses. It exits with an error if either variable is missing. After updating, it verifies that no old IPs remain in the modified files and updates its own baseline so subsequent runs work correctly.

**Files updated by the script:**

| File | IP Updated | Purpose |
|------|------------|---------|
| `docker/upf-docker/upf.yaml` | VPLMN IP | GTP-U bind address — the UPF runs in host network mode and needs the host's actual IP to bind GTP-U tunnels for N3 (gNB-UPF) and N9 (UPF-UPF) traffic |
| `docker/upf-docker/upf_tls.yaml` | VPLMN IP | Same as above, TLS variant |
| `docker/smf-docker/smf.yaml` | VPLMN IP | UPF address in SMF configuration — tells the SMF where to reach the UPF over PFCP (N4 interface) |
| `docker/smf-docker/smf_tls.yaml` | VPLMN IP | Same as above, TLS variant |
| `docker-compose.yml` | HPLMN IP | SEPP extra_hosts entry — maps `sepp2.localdomain` to the HPLMN PC so the local SEPP can reach the remote SEPP over N32 |
| `docker/sepp-docker/sepp.yaml` | HPLMN IP | Remote SEPP peer address — the N32 connection target for inter-PLMN signaling |
| `testbed_automation.sh` | HPLMN IP | `REMOTE_PC_IP` — used to SSH into HPLMN for coordinated test runs |
| `webui/backend/app.py` | Both IPs | Flask API configuration — service binding and SEPP peer address |
| `webui/frontend/index.html` | Both IPs | Frontend display — IP addresses shown in the Web UI |
| `webui/start.sh` | Both IPs | WebUI lifecycle manager |
| `docker/ipsectunnel/01_setup_ca.sh` | Both IPs | Hardcoded `VPLMN_IP`/`HPLMN_IP` variables used when generating IPsec CA and peer certificates |
| `docker/ipsectunnel/ipsec_certificates/pc1/03_setup_ipsec_pc1_cert.sh` | Both IPs | Hardcoded `VPLMN_IP`/`HPLMN_IP` — PC1 strongSwan tunnel endpoint IPs |
| `docker/ipsectunnel/ipsec_certificates/pc2/03_setup_ipsec_pc2_cert.sh` | Both IPs | Hardcoded `VPLMN_IP`/`HPLMN_IP` — PC2 strongSwan tunnel endpoint IPs |

> **Note:** `lib/features/set-open5gs-mode.sh` and `testbed_automation.sh` preserve the IP lines in `.env` when they rewrite it — your IP configuration will not be lost when switching modes.

### Step 3: Prepare NF Binaries

The Docker containers mount Open5GS binaries from the host filesystem rather than bundling them into the image. This enables live binary updates — you can recompile Open5GS and copy the new binaries without rebuilding Docker images.

The `prepare_nfs.sh` script copies the compiled binaries from your local Open5GS installation (`~/open5gs/install`) into each NF's Docker directory:
```bash
bash lib/setup/prepare_nfs.sh
```

The script supports two modes:
- **Initial setup** (default) — prepares all 13 NFs at once
- **Selective setup** — lets you choose specific NFs to update by number, useful when you only recompiled a single NF

The script checks that `~/open5gs/install` exists before proceeding.

**NFs prepared by this script:**

| NF Directory | Binary Copied | Description |
|--------------|---------------|---------|
| `docker/amf-docker/` | `open5gs-amfd` | Access and Mobility Management |
| `docker/smf-docker/` | `open5gs-smfd` | Session Management |
| `docker/upf-docker/` | `open5gs-upfd` | User Plane Function |
| `docker/upf2-docker/` | `open5gs-upfd` | Secondary UPF (VPLMN only, for LBO) |
| `docker/nrf-docker/` | `open5gs-nrfd` | Network Repository Function |
| `docker/scp-docker/` | `open5gs-scpd` | Service Communication Proxy |
| `docker/ausf-docker/` | `open5gs-ausfd` | Authentication Server |
| `docker/udm-docker/` | `open5gs-udmd` | Unified Data Management |
| `docker/udr-docker/` | `open5gs-udrd` | Unified Data Repository |
| `docker/pcf-docker/` | `open5gs-pcfd` | Policy Control |
| `docker/nssf-docker/` | `open5gs-nssfd` | Network Slice Selection |
| `docker/bsf-docker/` | `open5gs-bsfd` | Binding Support |
| `docker/sepp-docker/` | `open5gs-seppd` | Security Edge Protection Proxy |

Each binary is placed in the NF's `files/` directory and mounted into the container at runtime via `docker-compose.yml`.

### Step 4: Restore TLS Certificates

The testbed supports TLS-secured communication between NFs. Pre-generated certificates are stored in the `lib/setup/certificates_backup/` directory and need to be distributed to each NF's `files/` directory before building the Docker images.

The `redistribute_certificates.sh` script copies the CA certificate, NF certificate, and private key from the backup into each NF's `files/` directory. It also sets proper file permissions — `644` for certificates (`.crt`) and `600` for private keys (`.key`).
```bash
bash lib/setup/redistribute_certificates.sh
```

**Certificates restored per NF:**

Each NF receives the following files in its `docker/<nf>-docker/files/` directory:

| File | Permission | Description |
|------|------------|-------------|
| `ca.crt` | 644 | Certificate Authority — shared across all NFs, used to verify peer certificates |
| `<nf>.crt` | 644 | NF-specific certificate — identifies this NF to other NFs during TLS handshake |
| `<nf>.key` | 600 | NF private key — used for TLS authentication, restricted permissions for security |

These files are mounted read-only into the containers at `/etc/open5gs/default/tls/` via `docker-compose.yml`. When running in non-TLS mode, the certificates are still mounted but not used by the NFs.

> **Note:** If you need to generate new certificates (e.g., for different FQDNs), see the [TLS Certificate Management](#tls-certificate-management) section below.

### Step 5: Install PacketRusher (VPLMN Only)

[PacketRusher](https://github.com/HewlettPackard/PacketRusher) is used to simulate a 5G UE and gNB (RAN) for testing the testbed.

**Pull the Docker image:**
```bash
docker pull ghcr.io/borjis131/packetrusher:main
```

**Install dependencies and the gtp5g kernel module:**

PacketRusher requires the `gtp5g` kernel module to create GTP-U tunnel interfaces. Install the build dependencies, Go compiler, and compile the kernel module:
```bash
# Install build dependencies
sudo apt install build-essential linux-headers-generic make git wget tar \
  linux-modules-extra-$(uname -r)

# Install Go
wget https://go.dev/dl/go1.24.1.linux-amd64.tar.gz
sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf go1.24.1.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> $HOME/.profile

# Clone PacketRusher and build the gtp5g kernel module
git clone https://github.com/HewlettPackard/PacketRusher
cd PacketRusher && echo "export PACKETRUSHER=$PWD" >> $HOME/.profile
source $HOME/.profile
cd $PACKETRUSHER/lib/gtp5g
make clean && make && sudo make install
```

> **Note:** Secure Boot must be disabled in BIOS to install the gtp5g kernel module. If `make install` fails with a permission error, check your BIOS settings.

> **Note:** This step is only required on the VPLMN PC (PC1). The HPLMN does not run PacketRusher.

### Step 6: Build Docker Images

The `build_all.sh` script builds Docker images for all 13 network functions, plus a base image and an alternative UPF image for LBO/Non-Roaming modes. Each NF image is built from its own Dockerfile located in the corresponding `docker/<nf>-docker/` directory. The `--no-cache` flag ensures a clean build every time.
```bash
bash lib/setup/build_all.sh
```

**Images built by this script:**

| Image | Tag | Dockerfile | Purpose |
|-------|-----|------------|---------|
| `open5gs-amf` | `v2.7.6-hr` | `docker/amf-docker/Dockerfile.amf` | Access and Mobility Management |
| `open5gs-smf` | `v2.7.6-hr` | `docker/smf-docker/Dockerfile.smf` | Session Management |
| `open5gs-upf` | `v2.7.6-hr` | `docker/upf-docker/Dockerfile.upf` | User Plane Function (HR mode) |
| `open5gs-nrf` | `v2.7.6-hr` | `docker/nrf-docker/Dockerfile.nrf` | Network Repository Function |
| `open5gs-scp` | `v2.7.6-hr` | `docker/scp-docker/Dockerfile.scp` | Service Communication Proxy |
| `open5gs-ausf` | `v2.7.6-hr` | `docker/ausf-docker/Dockerfile.ausf` | Authentication Server |
| `open5gs-udm` | `v2.7.6-hr` | `docker/udm-docker/Dockerfile.udm` | Unified Data Management |
| `open5gs-udr` | `v2.7.6-hr` | `docker/udr-docker/Dockerfile.udr` | Unified Data Repository |
| `open5gs-pcf` | `v2.7.6-hr` | `docker/pcf-docker/Dockerfile.pcf` | Policy Control |
| `open5gs-nssf` | `v2.7.6-hr` | `docker/nssf-docker/Dockerfile.nssf` | Network Slice Selection |
| `open5gs-bsf` | `v2.7.6-hr` | `docker/bsf-docker/Dockerfile.bsf` | Binding Support |
| `open5gs-sepp` | `v2.7.6-hr` | `docker/sepp-docker/Dockerfile.sepp` | Security Edge Protection Proxy |
| `open5gs-mongodb` | `v2.7.6-hr` | `docker/mongodb-docker/Dockerfile` | Subscriber database |
| `base-open5gs` | `v2.7.2` | `Dockerfile.base` | Base image used to build the LBO UPF |
| `open5gs-upf` | `v2.7.2` | `docker/upf-docker/Dockerfile.upf_lbo` | UPF for LBO and Non-Roaming modes |

Build time is approximately 10–15 minutes depending on hardware. All builds are chained — if any single build fails, the subsequent builds will not execute.

### Step 7: Create Docker Networks

The Docker Compose file uses **externally-managed networks** that must exist before you run `docker compose up`. Create them once — they persist across `docker compose down` / `up` cycles.

```bash
docker network create --driver bridge --subnet 192.168.50.0/24 my_custom_network   # NF management network
docker network create --driver bridge --subnet 192.168.70.0/24 my_second_network   # N2/N3 network (gNB ↔ AMF/UPF)
docker network create --driver bridge --subnet 192.168.80.0/24 my_isolated_network # UPF2 isolated network (LBO)
```

These commands are idempotent — if a network already exists, Docker will return an error that can be safely ignored.

### Step 8: Configure Host Networking

For UE traffic to reach the internet through the 5G core, the host machine needs IP forwarding, NAT (masquerade) rules, and proper routing configured. Without this, the UPF will establish GTP-U tunnels but UE packets will have no path to the internet.

You can configure these network settings **manually** based on your own network environment, or use the provided script which automates the entire process.

> **Note on the `ogstun` TUN device:** Unlike a bare-metal Open5GS installation where you must manually create the TUN device with `ip tuntap add name ogstun mode tun` (as described in the [official Open5GS quickstart](https://open5gs.org/open5gs/docs/guide/01-quickstart/)), in this testbed the UPF container's entrypoint script creates and configures `ogstun` automatically at startup. Since the UPF runs in Docker's host network mode, the TUN device appears directly on the host. The entrypoint also assigns the IP address (`10.45.0.1/16`) and adds NAT rules for the `ogstun` interface. You still need to ensure IP forwarding is enabled and that proper FORWARD rules exist on the host for traffic to reach the internet.

**Manual configuration (minimum required):**
```bash
# Enable IP forwarding
sudo sysctl -w net.ipv4.ip_forward=1
sudo sysctl -w net.ipv6.conf.all.forwarding=1

# Add forwarding rules (replace <main_iface> with your interface, e.g., eth0 or ens18)
sudo iptables -I FORWARD 1 -i ogstun -o <main_iface> -j ACCEPT
sudo iptables -I FORWARD 1 -i <main_iface> -o ogstun -m state --state RELATED,ESTABLISHED -j ACCEPT
```

> **Note:** These manual settings are **not persistent** and will be lost on reboot. Use the automated script below for persistent configuration.

**Automated configuration (recommended):**

The `open5gs_network_setup.sh` script handles everything automatically. It auto-detects the main network interface (the one with the default route) and configures all required settings:
```bash
sudo bash lib/setup/open5gs_network_setup.sh
```

**What the script does step by step:**

| Step | Action | Details |
|------|--------|---------|
| 1. Interface detection | Finds the main network interface | Uses `ip route show default` to identify the interface with the default route (e.g., `eth0`, `ens18`) |
| 2. Docker network detection | Discovers custom Docker bridge networks | Lists all non-default Docker bridge subnets (e.g., `192.168.50.0/24`, `192.168.70.0/24`) for route cleanup |
| 3. Prerequisite check | Verifies Docker and sudo access | Ensures Docker, Docker Compose, and root permissions are available |
| 4. Stale config cleanup | Removes duplicate routes and stale ARP entries | Finds Docker bridge routes pointing to DOWN interfaces and removes them; flushes FAILED/INCOMPLETE ARP entries |
| 5. IP forwarding | Enables packet forwarding | Sets `net.ipv4.ip_forward=1`, `net.ipv6.conf.all.forwarding=1`, and `net.ipv4.conf.all.rp_filter=2` (loose mode). Persists to `/etc/sysctl.d/99-open5gs.conf` |
| 6. iptables rules | Configures NAT and FORWARD rules | **NAT:** `POSTROUTING -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE` (IPv4 + IPv6) — masquerades UE traffic to the internet. **FORWARD:** `ogstun → <main_iface>` ACCEPT + `<main_iface> → ogstun` ESTABLISHED — allows bidirectional traffic between UE tunnel and internet. Sets FORWARD policy to ACCEPT. |
| 7. ogstun configuration | Configures the TUN interface (if present) | Brings `ogstun` up, adds `10.45.0.1/16` + `2001:db8:cafe::1/48`, adds routes for `10.45.0.0/16` and `2001:db8:cafe::/48`. If `ogstun` doesn't exist yet (UPF not started), skips this and defers to the persistent service. |
| 8. Persistence | Creates a systemd service | Installs `open5gs-network-setup.service` that runs `/usr/local/bin/configure-open5gs-network.sh` on boot. The boot script re-applies all sysctl, iptables, and ogstun settings, and waits up to 30 seconds for `ogstun` to appear. |
| 9. Post-cleanup | Removes any new duplicate routes | Re-checks all Docker subnets for duplicate routes after configuration |
| 10. Validation | Verifies the final configuration | Checks: IPv4/IPv6 forwarding enabled, NAT rule exists, no duplicate routes, gateway reachable, ogstun configured correctly, systemd service enabled |

The script logs all output to `setup_logs/` inside the VPLMN directory for debugging.

> **Note:** This script should be run on **both PCs**. Run it once before starting the testbed for the first time, and again if you encounter networking issues after a reboot.

### Step 9: Repeat on HPLMN (PC2)

Repeat Steps 1–4, 6, 7, and 8 on the HPLMN PC with the appropriate IP addresses. Step 5 (PacketRusher) is not needed on the HPLMN side, and the Docker Networks in Step 7 use a different subnet (`192.168.60.0/24`) with only one network.

For HPLMN-specific instructions, see the [HPLMN Setup Guide](../HPLMN/README.md).

---

## Deployment Modes

### Configure Operating Mode

Before starting the testbed, you need to select the roaming mode and security configuration. The `lib/features/set-open5gs-mode.sh` script handles this by generating a `.env` file that Docker Compose reads at startup.

The script prompts for two choices:
1. **Roaming mode** — determines which UPF image to use and which NF configuration files are loaded
2. **Security mode** — selects between TLS-secured (`_tls.yaml`) and plain HTTP (`.yaml`) configuration files for all NFs

The generated `.env` file sets environment variables such as `UPF_IMAGE`, `AMF_CONFIG`, `SMF_CONFIG`, etc., which are referenced in `docker-compose.yml` to mount the correct YAML configuration into each container.
```bash
./lib/features/set-open5gs-mode.sh
```

**Example output:**
```
=======================================
 Open5GS Mode Configuration
=======================================

Select UPF Roaming Mode:
  1) Home Routed (HR)
  2) Local Breakout (LBO)
  3) Select 2) for Non-Roaming as well
Enter choice [1-2]: 1

Select Security Mode:
  1) TLS
  2) Non-TLS (Plain HTTP)
Enter choice [1-2]: 1

=======================================
 Applying Configuration
=======================================
 Roaming Mode : hr
 Security Mode: tls

✅ .env file updated successfully!

Next steps:
  docker compose up
```

### Mode Summary

| Use Case | Roaming Choice | Security Choice | Selected vUPF Image | Config Suffix |
|----------|----------------|-----------------|-----------|---------------|
| HR Roaming with TLS | 1 | 1 | `open5gs-upf:v2.7.6-hr` | `_tls.yaml` |
| HR Roaming without TLS | 1 | 2 | `open5gs-upf:v2.7.6-hr` | `.yaml` |
| LBO Roaming with TLS | 2 | 1 | `open5gs-upf:v2.7.2` | `_tls.yaml` |
| LBO Roaming without TLS | 2 | 2 | `open5gs-upf:v2.7.2` | `.yaml` |
| Non-Roaming with TLS | 2 | 1 | `open5gs-upf:v2.7.2` | `_tls.yaml` |
| Non-Roaming without TLS | 2 | 2 | `open5gs-upf:v2.7.2` | `.yaml` |

> **Important:** Run `VPLMN/lib/features/set-open5gs-mode.sh` to select the roaming mode and security mode. On HPLMN, run `HPLMN/lib/features/set-open5gs-mode.sh` and select the matching security mode before starting the testbed.

> **Note:** These are the three core deployment modes selected by `lib/features/set-open5gs-mode.sh`. The automation/batch layer adds two HR variants on top of the HR mode — **`hr-ipsec`** (Home Routed with the N9/N32 traffic carried over an IPsec tunnel) and **`hr-remote-upf`** (Home Routed selecting the remote/home UPF for the data anchor). Both are driven from the config files and the batch matrix (`main.conf`); see the [Automation Scripts](../docs/AUTOMATION.md) docs.

---

## Running the Testbed

### Docker Networks

The three external Docker networks required by the Compose file are created in [Step 7](#step-7-create-docker-networks) of the installation. If you've already run `setup.sh` or Step 7, they are already in place.

To verify they exist:

```bash
docker network ls | grep -E 'my_custom_network|my_second_network|my_isolated_network'
```

> **Why external networks?** `docker compose down` and `up` are run frequently between test iterations. If Docker Compose owned the networks, it would tear them down and recreate them on every cycle — triggering kernel bridge creation, iptables updates, and route changes each time. By defining networks externally, `docker compose down` only stops and removes containers while the networks stay up, reducing overhead and log noise.

### Start Services

> Start HPLMN (PC2) first, then VPLMN (PC1).

```bash
# 1. On HPLMN (PC2) — start first
cd ~/LKN_5G_Roaming_Testbed/HPLMN
./lib/features/set-open5gs-mode.sh
docker compose up

# 2. On VPLMN (PC1)
cd ~/LKN_5G_Roaming_Testbed/VPLMN
./lib/features/set-open5gs-mode.sh
docker compose up
```

### Verify Deployment

```bash
# Check all containers are running
docker compose ps

# View logs
docker compose logs

# View specific NF logs
docker logs open5gs-amf
docker logs open5gs-sepp
```

### Stop Services

```bash
docker compose down
```

---

## UE Simulation with PacketRusher

[PacketRusher](https://github.com/HewlettPackard/PacketRusher) simulates a 5G UE and gNB (RAN), allowing you to test UE registration, PDU session establishment, and end-to-end data connectivity through the 5G core without physical radio hardware.

### Start PacketRusher

The `lib/features/start_packetrusher.sh` script removes any existing PacketRusher container, then launches a new one on the N2/N3 Docker network (`192.168.70.0/24`) with IP `192.168.70.190`. It prompts you to select the roaming mode, which determines which configuration file is loaded — each config sets the correct PLMN IDs (MCC/MNC), SUPI range, and AMF address for the selected mode.
```bash
./lib/features/start_packetrusher.sh
```

Select the roaming mode that matches your current deployment:

| Testbed Mode | PacketRusher Choice | Config File Used |
|--------------|---------------------|------------------|
| HR Roaming | 1 | `configs/Packetrusher_Configs/config_hr_roaming.yml` |
| LBO Roaming | 2 | `configs/Packetrusher_Configs/config_lbo_roaming.yml` |
| Non-Roaming | 3 | `configs/Packetrusher_Configs/config_non_roaming.yml` |

Once started, PacketRusher performs the UE registration procedure (authentication via AUSF/UDM) and establishes a PDU session through the SMF/UPF. You should see the assigned UE IP address and VRF name in the PacketRusher output.

### Test Connectivity

Enter the PacketRusher container and ping through the established PDU session to verify end-to-end connectivity:
```bash
# Enter the PacketRusher container
docker exec -it packetrusher /bin/bash

# Ping through the PDU session
ip vrf exec vrf0000000001 ping -I 10.45.0.2 8.8.8.8
```

> Replace `10.45.0.2` and `vrf0000000001` with the actual UE IP address and VRF shown in the PacketRusher output.

A successful ping confirms that the entire 5G data path is working: UE → gNB → AMF/SMF (control plane) → UPF (user plane via GTP-U) → internet. In Home Routed mode, traffic additionally traverses the N9 tunnel between VPLMN UPF and HPLMN UPF before reaching the internet.

If the ping fails, see the [Troubleshooting](#troubleshooting) section below.

---

## Post-Quantum IKEv2 Evaluation

In Home Routed roaming the **N9** interface (VPLMN UPF ⇄ HPLMN UPF) is protected by **IPsec**, whose keys are negotiated with **IKEv2** — today using ECDH key exchange and RSA authentication, both of which a quantum computer breaks. The `docker/pq-ike-docker/` sub-testbed measures what it costs to make that tunnel quantum-safe, using NIST's standardised **ML-KEM** (key exchange) and **ML-DSA** (signatures).

It is **self-contained**: two strongSwan containers (`pq-vplmn` ⇄ `pq-hplmn`) on an isolated `192.168.40.0/24` bridge on **this machine only** — it does not need the HPLMN PC, the 5G core, or a router, and it cannot collide with the lab network.

### Four scenarios (a 2×2 design)

Splitting key exchange from authentication lets you attribute the cost of each independently:

| # | Scenario | Key exchange | Authentication |
|---|----------|--------------|----------------|
| 1 | Classical (baseline) | ECP-256 | RSA |
| 2 | PQ Key Exchange | **ML-KEM-768** | RSA |
| 3 | PQ Auth | ECP-256 | **ML-DSA-65** |
| 4 | Fully PQ | **ML-KEM-768** | **ML-DSA-65** |
| 5 | All four, sequentially (full comparison) | | |

### Quick start

```bash
cd docker/pq-ike-docker
docker build -t pq-ike-strongswan:local --build-arg SWAN_REF=ml-dsa .   # ~5-10 min, needs internet
docker compose run --rm certs      # generate the RSA + ML-DSA-65 PKI
docker compose up -d               # start pq-vplmn (.55) + pq-hplmn (.230)

sudo ./ike_eval_docker.sh 5 30     # all 4 scenarios, 30 iterations
sudo ./ike_eval_docker.sh 5 30 10  # same, +10 ms netem each way (+20 ms RTT)
```

Or drive the whole thing from the WebUI's **Post-Quantum** tab (build/certs/up/down, run, and result charts).

> **Note:** use `docker build`, not `docker compose build` — under a snap-confined docker the latter exits 1 on a `/tmp` metadata file even though the image builds fine. See [docker/pq-ike-docker/README.md](docker/pq-ike-docker/README.md).

### What it measures

- **Wall clock** — charon start → CHILD_SA `INSTALLED`, timed *inside* the initiator container so `docker exec` latency never pollutes it.
- **Wire timings** — extracted from real packet captures with tshark (`ike_sa_init_rtt_us`, `ike_auth_rtt_us`, `total_wire_us`), including a fallback for IP-fragmented SA_INIT (ML-KEM keys exceed the 1500-byte MTU).

Results: `docker/pq-ike-docker/results/json/` (per-run JSON, also shown in the WebUI), pcaps in `results/pcaps/`.

> **Caveat:** both containers share one host (~0.1 ms RTT), so *absolute* numbers are a lower bound and differ from a real two-VM deployment — the *relative* comparison of the four scenarios is what's valid. Use the delay argument to emulate distance; the PQ penalty (bigger keys → fragmentation → extra round trips) only shows its full cost over a realistic WAN.

Full details, prerequisites, and the JSON schema: **[docker/pq-ike-docker/README.md](docker/pq-ike-docker/README.md)**.

---

## TLS Certificate Management

When running in TLS mode, all NF-to-NF communication within a PLMN is secured using mutual TLS (mTLS). Each NF presents its own certificate and verifies the peer's certificate against a shared Certificate Authority (CA). The testbed ships with pre-generated certificates for all NFs.

### Certificate Structure

Each NF has its certificates in the `files/` directory within its Docker folder. These files are mounted into the container at runtime via `docker-compose.yml`:
```
docker/<nf>-docker/files/
├── ca.crt      # Certificate Authority — shared across all NFs, used to verify peer certificates
├── <nf>.crt    # NF certificate — signed by the CA, contains the NF's FQDN in the SAN field
└── <nf>.key    # NF private key — used during TLS handshake (restricted permissions: 600)
```

The certificates use **Subject Alternative Names (SAN)** matching the NF's FQDN as configured in the Open5GS YAML files (e.g., `nrf.5gc.mnc071.mcc999.3gppnetwork.org` for the VPLMN NRF). When running in non-TLS mode, these files are still mounted but not used by the NFs.

### Backup & Restore

All certificates are backed up in the `lib/setup/certificates_backup/` directory, organized by NF. To restore them to each NF's `files/` directory (e.g., after a fresh clone or if certificates were accidentally deleted):
```bash
bash lib/setup/redistribute_certificates.sh
```

This is the same script used during [Step 4](#step-4-restore-tls-certificates) of the installation.

### Generate New Certificates

If you need to regenerate certificates (e.g., for different FQDNs or if they have expired), you can use `openssl` to create new ones signed by the existing CA. Below is an example for the NRF — the same process applies to any NF by replacing the NF name and FQDN:
```bash
cd ~/LKN_5G_Roaming_Testbed/VPLMN/docker/nrf-docker/files/

# Create SAN configuration with all hostnames the NF needs to be reachable by
cat > nrf-san.cnf << 'EOF'
subjectAltName=DNS:nrf.5gc.mnc071.mcc999.3gppnetwork.org,DNS:nrf.localdomain,DNS:open5gs-nrf
EOF

# Generate a new RSA key and Certificate Signing Request (CSR)
openssl req -new -newkey rsa:2048 -nodes \
  -keyout nrf.key \
  -out nrf.csr \
  -subj "/C=US/ST=State/L=Locality/O=Open5GS/OU=NRF/CN=nrf.5gc.mnc071.mcc999.3gppnetwork.org"

# Sign the CSR with the CA to produce the NF certificate
openssl x509 -req -in nrf.csr \
  -CA ca.crt -CAkey ca.key \
  -CAcreateserial \
  -out nrf.crt \
  -days 365 \
  -sha256 \
  -extfile nrf-san.cnf

# Verify the certificate contains the correct SANs
openssl x509 -in nrf.crt -text -noout | grep -A 2 "Subject:\|DNS:"

# Clean up the CSR (no longer needed)
rm nrf.csr
```

> **Important:** The `ca.key` file is required to sign new certificates. It is located in the `lib/setup/certificates_backup/` directory. After generating new certificates, update the backup by copying the new files back into `lib/setup/certificates_backup/<nf>-docker/`.

---

## Troubleshooting

### UE Ping Fails

If the UE cannot reach the internet after PacketRusher successfully registers and establishes a PDU session, the issue is most likely related to host networking. Run the network setup script to reconfigure IP forwarding, NAT, and routing:
```bash
sudo bash lib/setup/open5gs_network_setup.sh
```

If you already ran the script during installation, you can also try restarting the persistent service:
```bash
sudo systemctl restart open5gs-network-setup.service
```

### Duplicate Routes

Docker can sometimes create duplicate routes when networks are recreated (e.g., after `docker compose down` and `up`). This causes packets to be routed to a stale bridge interface instead of the active one.

Check for duplicate routes:
```bash
ip route show | grep "192.168.70.0/24"
```

If you see two routes and one shows `linkdown`, remove the stale one:
```bash
# Replace br-XXXXX with the actual bridge ID shown in the route
sudo ip route del 192.168.70.0/24 dev br-XXXXX
```

You can also verify routing from inside the UPF container:
```bash
docker exec open5gs-upf ip route show | grep "192.168.70.0/24"
```

> **Tip:** The `lib/setup/open5gs_network_setup.sh` script automatically detects and removes duplicate routes. Running it again will clean these up.

### IP Forwarding Not Enabled

If IP forwarding was not persisted or was reset, UE traffic will not be routed. Enable it manually:
```bash
sudo sysctl -w net.ipv4.ip_forward=1
sudo sysctl -w net.ipv6.conf.all.forwarding=1
```

To verify the current state:
```bash
sysctl net.ipv4.ip_forward
sysctl net.ipv6.conf.all.forwarding
```

Both should return `= 1`. The `open5gs_network_setup.sh` script persists these settings to `/etc/sysctl.d/99-open5gs.conf` so they survive reboots.

### Crashes After a `git pull` (Stale Docker Images)

If the NFs were working and then start crashing **right after a `git pull`**, with errors such as:

```
open5gs-smf  | symbol lookup error: ... undefined symbol: ogs_home_network_domain_from_fqdn
open5gs-pcf  | symbol lookup error: ... undefined symbol: ogs_home_network_domain_from_fqdn
open5gs-nrf  | *** stack smashing detected ***: terminated        (exits with code 139)
open5gs-amf  | ERROR: No amf.ngap.address in '/etc/open5gs/default/amf.yaml'
open5gs-nssf | ERROR: No nssf.nsi in '/etc/open5gs/default/nssf.yaml'
```

**Cause.** Each NF is split into two pieces that must come from the same Open5GS build: the daemon binary (`docker/<nf>-docker/files/open5gs-<nf>d`) and the shared `libogs*.so.2` libraries. Both are committed to git, but the **Docker images are not** — they are built locally and carry their own copy of `libogs`. When a pull updates the binaries (and libs) but your images were built *before* the pull, the new binary runs against the **old `libogs`** inside the stale image. The dynamic linker can't resolve a symbol the old library doesn't have (`symbol lookup error`), struct layouts disagree (`stack smashing`), or the newer config parser rejects the old YAML schema (`No amf.ngap.address`). A `git pull` alone can never fix this, because it does not touch images.

**Automatic fix (post-merge hook).** `setup.sh` installs a `post-merge` git hook (in `.git/hooks/post-merge`). After every pull, it detects whether any `docker/<nf>-docker/files/` daemon or library changed for **this** testbed (the one whose folder contains a `.env`) and prints the exact rebuild command. To make it rebuild automatically instead of just warning, export the flag before pulling:

```bash
OPEN5GS_AUTO_REBUILD=1 git pull
```

**Manual fix (if the hook didn't run).** Remove the existing images and rebuild — this is required because `build_all.sh` **skips** any image that already exists. The commands below also remove `base-open5gs` and the LBO UPF; they are built from a pinned `v2.7.2` source compile and are not affected by the pull, but rebuilding them does no harm and keeps everything consistent:

```bash
cd VPLMN     # or HPLMN on the HPLMN VM

# 1. Remove existing Open5GS images so they get rebuilt from the freshly-pulled files
docker rmi -f \
  open5gs-amf:v2.7.6-hr  open5gs-smf:v2.7.6-hr  open5gs-upf:v2.7.6-hr \
  open5gs-nrf:v2.7.6-hr  open5gs-scp:v2.7.6-hr  open5gs-ausf:v2.7.6-hr \
  open5gs-udm:v2.7.6-hr  open5gs-udr:v2.7.6-hr  open5gs-pcf:v2.7.6-hr \
  open5gs-nssf:v2.7.6-hr open5gs-bsf:v2.7.6-hr  open5gs-sepp:v2.7.6-hr \
  open5gs-mongodb:v2.7.6-hr \
  base-open5gs:v2.7.2    open5gs-upf:v2.7.2  2>/dev/null

# 2. Rebuild every image (skips any that still exist)
bash lib/setup/build_all.sh --rebuild

# 3. Start the core
docker compose up
```

> **Note:** Images are not shared through git. Whenever someone rebuilds Open5GS and pushes new binaries, every other VM must rebuild (or reload) its images to stay matched — that is exactly what the post-merge hook automates.

### Common Issues

| Problem | Likely Cause | Solution |
|---------|-------------|----------|
| **SEPP connection failed** | Firewall or IP misconfiguration between PCs | Verify both PCs can reach each other on ports 8080 and 8081. Check `ufw` or `iptables` rules. Verify IPs in `sepp.yaml` and `docker-compose.yml` are correct. |
| **NF registration fails** | NRF unreachable or TLS certificate mismatch | Check NRF logs (`docker logs open5gs-nrf`). In TLS mode, verify certificates are valid and SANs match the NF FQDNs. Run `bash lib/setup/redistribute_certificates.sh` if needed. |
| **UE registration fails** | Subscriber not provisioned or PLMN mismatch | Verify the subscriber is added in MongoDB with the correct IMSI, key (K), and OPc. Check AMF and AUSF logs. Ensure PacketRusher config matches the selected roaming mode. |
| **No internet from UE** | Missing NAT or forwarding rules on host | Run `sudo bash lib/setup/open5gs_network_setup.sh`. |
| **Container won't start** | Missing binary in NF's `files/` directory | Check if the compiled binary exists (e.g., `ls docker/amf-docker/files/open5gs-amfd`). If missing, run `bash lib/setup/prepare_nfs.sh` to copy binaries from the Open5GS build. |
| **`symbol lookup error` / `stack smashing` / `No amf.ngap.address` right after a `git pull`** | Stale Docker images: new binaries from the pull running against the old `libogs` baked into images built before the pull | Rebuild the affected images — see [Crashes After a `git pull`](#crashes-after-a-git-pull-stale-docker-images). The post-merge hook flags this automatically; otherwise `docker rmi -f` the images and re-run `bash lib/setup/build_all.sh --rebuild`. |
| **PacketRusher fails to start** | gtp5g kernel module not loaded | Verify with `lsmod | grep gtp5g`. If not loaded, rebuild and install: `cd $PACKETRUSHER/lib/gtp5g && make clean && make && sudo make install`. Ensure Secure Boot is disabled. |
| **Containers up but NFs not communicating** | Wrong mode/security selected | Ensure VPLMN selected the intended roaming mode and security mode, and HPLMN selected the matching security mode before starting. Check the `.env` files to verify the current configuration. |
| **Webpage test produces no output / exits immediately** | `sitespeedio/browsertime` image not present | Run `docker pull sitespeedio/browsertime` to download the image before enabling `WEBPAGE_TEST_ENABLED=true`. |
| **All webpage metrics are 0 or test times out** | No internet access through PDU session | Verify `ip vrf exec <vrf> curl http://1.1.1.1` succeeds from inside PacketRusher before running the webpage test. Check that `net.ipv4.tcp_l3mdev_accept=1` is set in the PacketRusher network namespace. |


> **Tip:** To filter logs for errors, use: `docker compose logs 2>&1 | grep -i error`

---

## Further Documentation

| Document | Description |
|----------|-------------|
| [Main README](../README.md) | Project overview, architecture, and network configuration |
| [HPLMN Setup Guide](../HPLMN/README.md) | Installation and configuration for the home network |
| [Automation Scripts](../docs/AUTOMATION.md) | Testbed automation script (v3.3.0) usage, config file format, delay emulation modes, Browsertime webpage test, and the startup-only script |
| [Batch Runner](../docs/BATCH_RUNNER.md) | Running batch experiments across multiple configurations |
| [IPsec Tunnel](../docs/IPSEC.md) | Establishment of the IPsec tunnel for the N9 interface during HR roaming |
| [Post-Quantum IKEv2](docker/pq-ike-docker/README.md) | Dockerized ML-KEM / ML-DSA IKEv2 performance testbed — scenarios, layout, JSON schema, and troubleshooting |
| [Web UI](webui/README.md) | Browser-based Web UI for managing, monitoring, and automating the testbed |
