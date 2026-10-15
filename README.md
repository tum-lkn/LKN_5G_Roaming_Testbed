<p align="center">
  <img src="docs/figures/header.png" alt="Testbed Architecture — Two-PC 5G Core Roaming Setup" width="100%"/>
</p>

# LKN 5G Roaming Testbed

A containerized 5G research testbed for roaming, built on [Open5GS](https://open5gs.org/) **v2.8.0**, supporting **Home Routed (HR)**, **Local Breakout (LBO)** and **Non-Roaming** scenarios across two machines (physical PCs or VMs). UEs are driven by the built-in [PacketRusher](https://github.com/HewlettPackard/PacketRusher) simulator or an optional commercial RAN (real gNB + USB-dongle UE), with optional control-plane TLS and N9/N4 user-plane IPsec encryption.

> This testbed is developed as part of the research at the Chair of Communication Networks at the Technical University of Munich. If you use this work, please [cite us](#citation).

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Deployment Modes](#deployment-modes)
- [Network Configuration](#network-configuration)
- [Subscribers & Credentials](#subscribers--credentials)
- [Inter-PLMN Security — SEPP TLS & mTLS](#inter-plmn-security--sepp-tls--mtls)
- [Getting Started](#getting-started)
- [Repository Structure](#repository-structure)
- [Optional Web UI](#optional-web-ui)
- [Further Documentation](#further-documentation)
- [References](#references)
- [Citation](#citation)

---

## Overview

This testbed provides a complete 5G core network deployment using Open5GS with Docker containers distributed across **two machines**:

- **PC1 (VPLMN)**: Visited Public Land Mobile Network
- **PC2 (HPLMN)**: Home Public Land Mobile Network

The testbed is built on **Open5GS v2.8.0**, using a single unified image set for every mode — HR, LBO and Non-Roaming share the same UPF image (the mode is a per-subscriber runtime toggle, `lbo_roaming_allowed`, rather than a different UPF build). All images, including MongoDB, carry the `v2.8.0` tag for consistency (MongoDB's image content is not itself Open5GS-derived).

### Key Features

| Feature | Description |
|---------|-------------|
| **Home Routed (HR) Roaming** | Traffic is routed back to the home network via N9 interface |
| **Local Breakout (LBO) Roaming** | Traffic breaks out at the visited network |
| **Non-Roaming Mode** | Single network operation without roaming |
| **TLS/Non-TLS Modes** | Configurable security for NF communications |
| **Live Binary Updates** | Modify source code and test without rebuilding Docker images |
| **PacketRusher Integration** | Built-in UE/gNB simulation for all roaming modes |
| **Automated Batch Testing** | Scripts for running experiments across all configurations with delay emulation |
| **Real-Browser Web Performance** | Browsertime-based webpage tests capturing TTFB, FCP, LCP, DOMContentLoaded, and Page Load through the GTP tunnel |
| **Network Delay Injection** | Per-direction `tc netem` delays on N32 (SEPP ⇄ SEPP), N9 (UPF ⇄ UPF) and N6 (UPF ⇄ DN), from the WebUI or the automation |
| **IPsec on N9 and N4** | strongSwan tunnels for UPF ⇄ UPF (GTP-U) and SMF ⇄ UPF (PFCP), with selectable ESP ciphers |
| **Post-Quantum IKEv2** | Local sub-testbed comparing ML-KEM / ML-DSA IKEv2 handshakes against classical ones |
| **Commercial RAN (optional)** | Drive a real gNB and USB-dongle UEs instead of PacketRusher |

---

## Architecture

<p align="center">
  <img src="docs/figures/testbed_architecture.png" alt="Testbed Architecture — Two-PC 5G Core Roaming Setup" width="100%"/>
</p>

### Network Functions Deployed

Each network (VPLMN and HPLMN) deploys the following containerized 5G Core Network Functions:

| Network Function | Description |
|------------------|-------------|
| **AMF** | Access and Mobility Management Function |
| **SMF** | Session Management Function |
| **UPF** | User Plane Function (runs in host network mode) |
| **NRF** | Network Repository Function |
| **SCP** | Service Communication Proxy |
| **AUSF** | Authentication Server Function |
| **UDM** | Unified Data Management |
| **UDR** | Unified Data Repository |
| **PCF** | Policy Control Function |
| **NSSF** | Network Slice Selection Function |
| **BSF** | Binding Support Function |
| **SEPP** | Security Edge Protection Proxy (inter-PLMN) |
| **MongoDB** | Subscriber database |

All NFs run in Docker containers on dedicated bridge networks, except the UPF which uses **host network mode** to handle GTP-U tunneling and data plane traffic directly on the host.

---

## Deployment Modes

The VPLMN side supports three operating modes, each configurable with TLS or non-TLS security via `VPLMN/lib/features/set-open5gs-mode.sh`. The HPLMN side uses `HPLMN/lib/features/set-open5gs-mode.sh` to select the matching NF-to-NF security mode.

| Mode | Description | Inter-PLMN Interfaces |
|------|-------------|-----------------------|
| **Home Routed (HR)** | User traffic is routed back to the home network | N32 + N9  |
| **Local Breakout (LBO)** | User traffic breaks out locally at the visited network | N32 |
| **Non-Roaming** | Single-network standalone operation | None |

Combining the three roaming modes with TLS/non-TLS security yields **6 testable configurations**.

UE and gNB simulation is handled by [PacketRusher](https://github.com/HewlettPackard/PacketRusher), running on the VPLMN PC with per-mode configuration files.

---

## Network Configuration

### Docker Networks

| Network | Subnet | Purpose |
|---------|--------|---------|
| my_custom_network (VPLMN) | 192.168.50.0/24 | Core NF communication |
| my_custom_network (HPLMN) | 192.168.60.0/24 | Core NF communication |
| my_second_network | 192.168.70.0/24 | N2/N3 interfaces (gNB - AMF/UPF) |
| my_isolated_network | 192.168.80.0/24 | UPF2 (if second UPF is deployed on VPLMN) |

### IP Address Mapping — VPLMN (192.168.50.0/24)

| Network Function | IP Address | FQDN |
|------------------|------------|------|
| MongoDB | 192.168.50.198 | — |
| NRF | 192.168.50.189 | nrf.5gc.mnc071.mcc999.3gppnetwork.org |
| SCP | 192.168.50.188 | scp.localdomain |
| AMF | 192.168.50.185 | amf.localdomain |
| SMF | 192.168.50.193 | smf.5gc.mnc071.mcc999.3gppnetwork.org |
| UPF | Host Network | upf.localdomain |
| AUSF | 192.168.50.191 | ausf.5gc.mnc071.mcc999.3gppnetwork.org |
| UDM | 192.168.50.192 | udm.5gc.mnc071.mcc999.3gppnetwork.org |
| PCF | 192.168.50.194 | pcf.localdomain |
| NSSF | 192.168.50.195 | nssf.5gc.mnc071.mcc999.3gppnetwork.org |
| BSF | 192.168.50.196 | bsf.5gc.mnc071.mcc999.3gppnetwork.org |
| UDR | 192.168.50.199 | udr.localdomain |
| SEPP | 192.168.50.251 | sepp.localdomain |

### IP Address Mapping — HPLMN (192.168.60.0/24)

| Network Function | IP Address | FQDN |
|------------------|------------|------|
| MongoDB | 192.168.60.198 | — |
| NRF | 192.168.60.189 | nrf.5gc.mnc001.mcc001.3gppnetwork.org |
| SCP | 192.168.60.188 | scp.localdomain |
| AMF | 192.168.60.185 | amf.localdomain |
| SMF | 192.168.60.193 | smf.5gc.mnc001.mcc001.3gppnetwork.org |
| UPF | Host Network | upf.localdomain |
| AUSF | 192.168.60.191 | ausf.5gc.mnc001.mcc001.3gppnetwork.org |
| UDM | 192.168.60.192 | udm.5gc.mnc001.mcc001.3gppnetwork.org |
| PCF | 192.168.60.194 | pcf.localdomain |
| NSSF | 192.168.60.195 | nssf.5gc.mnc001.mcc001.3gppnetwork.org |
| BSF | 192.168.60.196 | bsf.5gc.mnc001.mcc001.3gppnetwork.org |
| UDR | 192.168.60.199 | udr.localdomain |
| SEPP | 192.168.60.251 | sepp.localdomain |

### Exposed Ports

| Port | Protocol | Service | Description |
|------|----------|---------|-------------|
| 38412 | SCTP | AMF | N2 interface (NGAP) |
| 8080 | TCP | SEPP | N32-c interface |
| 8081 | TCP | SEPP | N32-f interface |

---

## Subscribers & Credentials

Each network provisions **only the subscribers it is the home operator for**, and the two operators use **different** subscriber credentials (K / OPc) — a roaming UE never shares a key with the visited network. HR/LBO authentication is relayed to the home network over N32, so the VPLMN never holds (or needs) the home subscriber's K/OPc.

| Database | PLMN | IMSI range | Mode | K (subscriber key) | OPc |
|----------|------|-----------|------|--------------------|-----|
| **VPLMN** | `999/71` | `999710000000001`–`…000101` | Non-Roaming | `465B5CE8B199B49FAA5F0A2EE238A6BC` | `E8ED289DEBA952E4283B54E88E6183CA` |
| **HPLMN** | `001/01` | `001010000000001`–`…000101` | LBO Roaming | `8BAF473F2F8FD09487CCCBD7097C6862` | `8E27B6AF0E692E750F32667A3B14605D` |
| **HPLMN** | `001/01` | `001010000001001`–`…001101` | HR Roaming | `8BAF473F2F8FD09487CCCBD7097C6862` | `8E27B6AF0E692E750F32667A3B14605D` |

- **Network side (MongoDB):** seeded by `<PLMN>/docker/mongodb-docker/start_services.sh` on container start (idempotent — it wipes and re-inserts).
- **UE / SIM side:** `VPLMN/configs/Packetrusher_Configs/config_<mode>.yml`. The `key`/`opc` there must match the DB of whichever core authenticates that UE — VPLMN for non-roaming, HPLMN for HR/LBO. Per-iteration copies are produced by `generate_Packetrusher_configs.sh`.
- **Roaming subscribers exist only in the HPLMN DB** (their home); the VPLMN authenticates roamers purely by relaying to the HPLMN over N32.

---

## Inter-PLMN Security — SEPP TLS & mTLS

On top of the per-NF TLS/non-TLS choice (see [Deployment Modes](#deployment-modes)), the N32 link between the two SEPPs can use **mutual TLS (mTLS)**, where each SEPP also verifies the other's client certificate. Each SEPP ships two config files; enable mTLS by selecting the `_mtls` variant on **both** PLMNs:

| File | N32 security |
|------|--------------|
| `<PLMN>/docker/sepp-docker/sepp_tls.yaml` | Server-side TLS only |
| `<PLMN>/docker/sepp-docker/sepp_tls_mtls.yaml` | Mutual TLS (client-cert verification) on N32 |

> **Important:** `verify_client` is scoped to the **`n32.server`** block only — never the `default` server block. In Open5GS `verify_client` applies to *every* server socket of the NF, including the SBI `:443` interface the PLMN's own NFs (e.g. the SCP) reach without a client cert; enabling it globally makes the SEPP reject its own core and roaming registration fails with **5GMM cause #90**. The `_mtls.yaml` files already scope it correctly.

---

## Getting Started

### Prerequisites

- 2 PCs running Ubuntu 20.04/22.04 LTS with network connectivity between them
- Docker and Docker Compose (v2) installed on both PCs
- Open5GS v2.8.0 — the repository ships its own v2.8.0 binaries; a local build at `~/open5gs/install` is only used if it is the same version
- PacketRusher with the gtp5g kernel module on PC1 (VPLMN only)

### Installation & Setup

> **Project folder name.** The GitLab repository is named `roamingtb_main`, so `git clone` creates `~/roamingtb_main`, but the testbed's scripts and docs use the path `~/LKN_5G_Roaming_Testbed`. Each `setup.sh` renames the project directory to `LKN_5G_Roaming_Testbed` as its **first step** (and re-runs itself from the new path), so a fresh GitLab clone just needs `cd ~/roamingtb_main/<VPLMN|HPLMN> && ./setup.sh`. Already-correctly-named clones are unaffected.

For step-by-step installation instructions, see the setup guide for each PLMN:

- **[VPLMN Setup Guide (PC1)](VPLMN/README.md)** — Full installation, IP configuration, PacketRusher setup, and troubleshooting
- **[HPLMN Setup Guide (PC2)](HPLMN/README.md)** — Installation and configuration for the home network

> **Setup order:** run `HPLMN/setup.sh` on PC2 before `VPLMN/setup.sh` on PC1. VPLMN's setup ends with an optional N9 IPsec tunnel step ([docs/IPSEC.md](docs/IPSEC.md)) that drives both PCs over SSH and requires HPLMN already set up and reachable — starting with HPLMN lets that step complete in one pass instead of failing and needing a manual re-run later.

---

## Repository Structure

```
.
├── README.md                        # This file (project overview)
├── VPLMN/      # Visited PLMN — setup guide, NFs, automation scripts
│   ├── README.md
│   ├── docker-compose.yml
│   ├── docker/                      # Per-NF Dockerfiles, YAML configs, certs, binaries
│   │   ├── <nf>-docker/
│   │   └── pq-ike-docker/           # Local post-quantum IKEv2 sub-testbed
│   ├── testbed_automation.sh
│   ├── batch_runner.sh
│   ├── configs/
│   └── ...
├── HPLMN/      # Home PLMN — setup guide and NFs
│   ├── README.md
│   ├── docker-compose.yml
│   ├── docker/
│   │   └── <nf>-docker/
│   └── ...
├── docs/
│   ├── figures/
│   ├── AUTOMATION.md
│   ├── BATCH_RUNNER.md
│   ├── COMMERCIAL_RAN.md
│   ├── DN_LATENCY_*.md
│   └── IPSEC.md
```

---
## Optional Web UI

<p align="center">
  <img src="docs/figures/testbed_gui.png" alt="Testbed Architecture — Two-PC 5G Core Roaming Setup" width="100%"/>
</p>


---
## Further Documentation

| Document | Description |
|----------|-------------|
| [VPLMN Setup Guide](VPLMN/README.md) | Installation, configuration, and troubleshooting for the visited network |
| [HPLMN Setup Guide](HPLMN/README.md) | Installation and configuration for the home network |
| [Automation Script](docs/AUTOMATION.md) | Testbed automation script usage, config file format, and delay modes |
| [Batch Runner](docs/BATCH_RUNNER.md) | Running batch experiments across multiple configurations |
| [IPsec Tunnel (N9)](docs/IPSEC.md) | Establishment of the IPsec tunnel for the N9 interface during HR roaming |
| [N4 (PFCP) IPsec](VPLMN/docker/n4-ipsec/README.md) | Securing the N4 (SMF ⇄ UPF, PFCP) interface with IPsec ESP in tunnel mode |
| [Web UI](VPLMN/webui/README.md) | Browser-based Web UI for managing, monitoring, and automating the testbed |
| [Commercial RAN](docs/COMMERCIAL_RAN.md) | Real gNB + USB-dongle UEs: how the tests run, how their timings are measured, troubleshooting |
| [Post-Quantum IKEv2](VPLMN/docker/pq-ike-docker/README.md) | ML-KEM / ML-DSA IKEv2 performance sub-testbed |
| [DN Latency](docs/DN_LATENCY_QUICK_REFERENCE.md) | N6 (UPF ⇄ DN) delay emulation — [technical reference](docs/DN_LATENCY_TECHNICAL_REFERENCE.md) |

---

## References

- [Open5GS Documentation](https://open5gs.org/open5gs/docs/)
- [Open5GS GitHub Repository](https://github.com/open5gs/open5gs)
- [PacketRusher GitHub Repository](https://github.com/HewlettPackard/PacketRusher)

---

## Citation

If you use this testbed in your research, please cite the project repository.

Parts of this testbed were first presented as a demo at ACM WiSec '26:
```
@inproceedings{zeidler_demo_2026,
	address = {New York, NY, USA},
	series = {{WiSec} '26},
	title = {{DEMO: 5G SA Roaming Testbed for Post Quantum IPsec Security Evaluations}},
	url = {https://dl.acm.org/doi/10.1145/3765613.3814568},
	doi = {10.1145/3765613.3814568},
	booktitle = {Proceedings of the 19th ACM Conference on Security and Privacy in Wireless and Mobile Networks},
	publisher = {Association for Computing Machinery},
	author = {Zeidler, Oliver and Günes, Mert and Anirudh M., Sai and Kellerer, Wolfgang},
	month = june,
	year = {2026},
}
```

---

## Affiliation

This project is developed at the **[Chair of Communication Networks](https://www.ce.cit.tum.de/en/lkn/home/)**, **Technical University of Munich (TUM)**.
