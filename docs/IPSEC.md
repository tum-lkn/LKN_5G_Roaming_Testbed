# IPsec Tunnel for N9 Interface

This document describes the optional IPsec tunnel that encrypts GTP-U traffic on the N9 interface between the VPLMN UPF (PC1) and HPLMN UPF (PC2) during **Home Routed roaming mode**. The tunnel uses strongSwan with X.509 certificate-based authentication, compliant with 3GPP TS 33.210 security recommendations.

IPsec is **optional** — the testbed works without it. It is only relevant in HR roaming mode where user plane traffic traverses the N9 interface between the two UPFs.

---

## Table of Contents

- [Overview](#overview)
- [How It Works](#how-it-works)
- [Directory Structure](#directory-structure)
- [Setup Guide](#setup-guide)
- [Stopping / Disabling the Tunnel](#stopping--disabling-the-tunnel)
- [Adapting to Your Environment](#adapting-to-your-environment)
- [ESP Algorithm Modes](#esp-algorithm-modes)
- [Verification](#verification)
- [Integration with Automation](#integration-with-automation)
- [Troubleshooting](#troubleshooting)

---

## Overview

> **Scope:** This guide covers the **N9** interface (UPF ⇄ UPF, GTP-U). The **N4** interface (SMF ⇄ UPF, PFCP) has its own separate IPsec setup — see [`n4-ipsec/README.md`](../VPLMN/docker/n4-ipsec/README.md).

In Home Routed roaming, UE data traffic flows through a GTP-U tunnel between the VPLMN UPF and the HPLMN UPF over the N9 interface. This traffic is unencrypted by default. The IPsec tunnel encrypts **only** GTP-U packets (UDP port 2152) between the two UPFs — all other traffic (SSH, ping, NF signaling, etc.) remains unaffected.

```
UE → gNB → VPLMN UPF ──[ IPsec Tunnel (ESP) ]──→ HPLMN UPF → Internet
                         N9 (GTP-U, port 2152)
                         Encrypted in tunnel mode
```

**Key properties:**
- **Mode:** IPsec tunnel mode (entire GTP-U packets encapsulated and encrypted)
- **Authentication:** X.509 certificates with IKEv2 key exchange
- **Scope:** Only GTP-U traffic (UDP port 2152) between the two UPF host IPs
- **Implementation:** strongSwan
- **Cipher suites:** Configurable (AES-GCM, AES-CBC+SHA256, NULL+integrity — see [ESP Algorithm Modes](#esp-algorithm-modes))

---

## How It Works

The setup uses a 3-step process on each PC:

1. **CA Setup** (`01_setup_ca.sh`) — Run once on any machine. Generates a private Certificate Authority (CA) and issues X.509 certificates for both UPFs. The CA key signs both certificates so they can mutually authenticate.

2. **Certificate Installation** (`02_install_certs_pcX.sh`) — Run on each PC. Copies the CA certificate, UPF certificate, and private key to `/etc/ipsec.d/` where strongSwan expects them.

3. **IPsec Configuration** (`03_setup_ipsec_pcX_cert.sh`) — Run on each PC. Installs strongSwan (if not present), writes `/etc/ipsec.conf` and `/etc/ipsec.secrets`, and starts the IPsec tunnel. PC1 initiates the connection (`auto=start`), PC2 waits for it (`auto=add`).

Once both PCs are configured, the IKEv2 handshake completes and an IPsec Security Association (SA) is established. From this point, any GTP-U packet between the two UPF IPs is automatically encrypted by the kernel's XFRM framework — no application changes needed.

---

## Directory Structure

The IPsec configuration is split across two directories in the VPLMN and HPLMN repository:

```
VPLMN/
├── docker/ipsectunnel/                          # IPsec tunnel setup (CA, certs, config scripts)
│   ├── 01_setup_ca.sh                    # CA and certificate generation (run once on PC1)
│   ├── update_ipsec_ips.sh               # Update hardcoded IPs for your environment
│   └── ipsec_certificates/
│       ├── pc1/
│       │   ├── ca-cert.pem               # CA certificate
│       │   ├── pc1-upf-cert.pem          # VPLMN UPF certificate
│       │   ├── pc1-upf-key.pem           # VPLMN UPF private key
│       │   ├── 02_install_certs_pc1.sh   # Install certs on PC1
│       │   ├── 03_setup_ipsec_pc1_cert.sh # Configure & start IPsec on PC1
│       │   └── README.txt
│       └── pc2/
│           ├── ca-cert.pem               # CA certificate (same as PC1)
│           ├── pc2-upf-cert.pem          # HPLMN UPF certificate
│           ├── pc2-upf-key.pem           # HPLMN UPF private key
│           ├── 02_install_certs_pc2.sh   # Install certs on PC2
│           ├── 03_setup_ipsec_pc2_cert.sh # Configure & start IPsec on PC2
│           └── README.txt
└── ipsec_update_configs/
    └── esp_config.sh                     # ESP algorithm selection (used by automation script)

HPLMN/
├── docker/ipsectunnel/                          # IPsec tunnel setup (CA, certs, config scripts)
│   ├── 01_setup_ca.sh                    # CA and certificate generation (run once on PC1)
│   ├── update_ipsec_ips.sh               # Update hardcoded IPs for your environment
│   └── ipsec_certificates/
│       ├── pc1/
│       │   ├── ca-cert.pem               # CA certificate
│       │   ├── pc1-upf-cert.pem          # VPLMN UPF certificate
│       │   ├── pc1-upf-key.pem           # VPLMN UPF private key
│       │   ├── 02_install_certs_pc1.sh   # Install certs on PC1
│       │   ├── 03_setup_ipsec_pc1_cert.sh # Configure & start IPsec on PC1
│       │   └── README.txt
│       └── pc2/
│           ├── ca-cert.pem               # CA certificate (same as PC1)
│           ├── pc2-upf-cert.pem          # HPLMN UPF certificate
│           ├── pc2-upf-key.pem           # HPLMN UPF private key
│           ├── 02_install_certs_pc2.sh   # Install certs on PC2
│           ├── 03_setup_ipsec_pc2_cert.sh # Configure & start IPsec on PC2
│           └── README.txt
```

---

## Setup Guide

> **Run HPLMN's `setup.sh` (PC2) before VPLMN's `setup.sh` (PC1).** VPLMN's setup ends with an optional prompt to deploy this IPsec tunnel, which drives both PCs over SSH and requires HPLMN already set up and reachable. Setting up HPLMN first lets that step complete in the same pass instead of failing and needing a manual `deploy_ipsec.sh` re-run afterward.

> **Automated setup (recommended):** Instead of running Steps 2–5 by hand, you can run a single orchestrator **on PC1 (VPLMN)** that drives both PCs over SSH — it checks/installs strongSwan on both sides, generates the CA, distributes and installs the certificates, then asks whether to start the tunnel (PC2 first, then PC1) and verifies the SA:
>
> ```bash
> cd ~/LKN_5G_Roaming_Testbed/VPLMN/lib/setup
> ./deploy_ipsec.sh            # full setup, then prompts before starting
> # ./deploy_ipsec.sh --yes    # setup + start, no prompt
> # ./deploy_ipsec.sh --no-start  # setup + write config on both PCs, but don't start the tunnel
> # ./deploy_ipsec.sh --help   # all options
> ```
>
> It reads PC IPs/users from `.env`, so still do **Step 1** first. Requires SSH key auth to PC2 and passwordless (or cached) `sudo` on both. The manual steps below remain the reference for what it automates and for troubleshooting.
>
> **Answering "no" to the start prompt (or `--no-start`) still regenerates `/etc/ipsec.conf` on *both* PCs** so the on-disk peer IPs (`left=`/`right=`) stay consistent with `.env` — it just skips `ipsec start`. This closes a subtle trap: previously, setup-without-start left the old peer IPs in place, so a later start (CLI or WebUI) failed with `NO_PROPOSAL_CHOSEN`. Regenerating the config stops any currently-running tunnel as part of the clean reconfigure.

### Step 1: Update IP Addresses

The scripts ship with hardcoded development IPs. Before anything else, update them to your actual PC IPs:

```bash
cd ~/LKN_5G_Roaming_Testbed/VPLMN/docker/ipsectunnel
./update_ipsec_ips.sh --new-pc1 <YOUR_VPLMN_IP> --new-pc2 <YOUR_HPLMN_IP>
```

Or run interactively (prompts for IPs):

```bash
./update_ipsec_ips.sh
```

The script updates IPs in `01_setup_ca.sh`, all `02_install_certs_*.sh`, all `03_setup_ipsec_*.sh`, and the README files. It also creates a backup of all modified files.

> **Note:** Use `--dry-run` to preview changes without modifying files.

### Step 2: Generate Certificates

This script uses strongSwan's `ipsec pki` tooling, so strongSwan must be available. You have two options:

**Option A — Install strongSwan manually first (recommended for offline/controlled setups):**

```bash
sudo apt install strongswan strongswan-pki strongswan-starter
```

**Option B — Let the script install it automatically:**

The script checks whether strongSwan is installed and **installs it automatically** if missing (`strongswan strongswan-pki strongswan-starter` via `apt`, with `dnf`/`yum`/`pacman` fallbacks). This requires internet/package-manager access on first run.

Then run the CA setup script **once on one machine only** (typically PC1). It generates the CA and certificates for **both** UPFs:

```bash
sudo ./01_setup_ca.sh
```

> **Critical:** Do **NOT** run `01_setup_ca.sh` on PC2 as well. The CA and both UPF certificates must be generated together on a single machine so they share the same CA trust chain. If you regenerate certificates on PC2, it will create a different CA, and the two PCs will not be able to authenticate each other. Always generate once, then copy the appropriate certificate package to the other PC.

This creates certificates in `ipsec_certificates/pc1/` and `ipsec_certificates/pc2/` with the following identities:
- **PC1 (VPLMN):** `upf.5gc.mnc071.mcc999.3gppnetwork.org`
- **PC2 (HPLMN):** `upf.5gc.mnc001.mcc001.3gppnetwork.org`

Each certificate includes SANs for the UPF IP address, the 3GPP FQDN, and a local alias.

### Step 3: Distribute Certificates

After generating on PC1, copy the PC2-specific certificate package to the HPLMN machine. The PC1 certificates are already on the machine where they were generated.

```bash
# From PC1: copy the PC2 certificate package into the existing pc2 folder of the HPLMN repo
scp -r ipsec_certificates/pc2/* user@<HPLMN_IP>:~/LKN_5G_Roaming_Testbed/HPLMN/docker/ipsectunnel/ipsec_certificates/pc2/
```

> **Note:** No `mkdir` is needed — the `pc2/` folder already exists in the HPLMN repo, so the certificates are copied straight into it.

> **Note:** Both PCs share the **same** `ca-cert.pem` (the CA certificate). The only difference is each PC gets its own UPF certificate and private key. The `pc1/` package contains `pc1-upf-cert.pem` + `pc1-upf-key.pem`, and the `pc2/` package contains `pc2-upf-cert.pem` + `pc2-upf-key.pem`.

### Step 4: Install Certificates (on each PC)

**On PC1 (VPLMN)** — the certs were generated here, so run them in place from the repo:
```bash
cd ~/LKN_5G_Roaming_Testbed/VPLMN/docker/ipsectunnel/ipsec_certificates/pc1
chmod +x *.sh
sudo ./02_install_certs_pc1.sh
```

**On PC2 (HPLMN)** — from the `pc2/` folder in the HPLMN repo (where the certs were copied):
```bash
cd ~/LKN_5G_Roaming_Testbed/HPLMN/docker/ipsectunnel/ipsec_certificates/pc2
chmod +x *.sh
sudo ./02_install_certs_pc2.sh
```

These scripts copy certificates to `/etc/ipsec.d/` and verify them against the CA.

### Step 5: Configure and Start IPsec (on each PC)

> **Shortcut — start both PCs at once:** from either machine you can run the helper in `docker/ipsectunnel/`, which runs the `03` scripts on both ends in the correct order (PC2 first, then PC1) over SSH:
> ```bash
> cd ~/LKN_5G_Roaming_Testbed/VPLMN/docker/ipsectunnel   # (or the HPLMN repo, if on PC2)
> ./ipsec_tunnel.sh start
> ```
> It self-detects which PC it's on (by IP) and drives the other over SSH. The manual per-PC steps below are the underlying reference.

**On PC2 (HPLMN) first** — it runs in `auto=add` mode (waits for connection):
```bash
cd ~/LKN_5G_Roaming_Testbed/HPLMN/docker/ipsectunnel/ipsec_certificates/pc2
sudo ./03_setup_ipsec_pc2_cert.sh
```

**Then on PC1 (VPLMN)** — it runs in `auto=start` mode (initiates connection):
```bash
cd ~/LKN_5G_Roaming_Testbed/VPLMN/docker/ipsectunnel/ipsec_certificates/pc1
sudo ./03_setup_ipsec_pc1_cert.sh
```

The tunnel should establish within a few seconds. Verify with:
```bash
sudo ipsec statusall
```

> **Write config without starting the tunnel:** pass `--no-start` (or `--config-only`, or set `IPSEC_CONFIG_ONLY=1`) to either `03` script. It writes `/etc/ipsec.conf` + `/etc/ipsec.secrets`, applies the sysctl settings, and verifies the certificate, then exits **before** `ipsec start`:
> ```bash
> sudo ./03_setup_ipsec_pc2_cert.sh --no-start
> ```
> Use this to refresh the peer IPs on disk (e.g. after an IP change) while leaving the tunnel down. Note it still stops any running strongSwan/flushes XFRM state first, so a currently-established tunnel is torn down.

---

## Stopping / Disabling the Tunnel

To take the tunnel down — for example to fall back to **unencrypted** N9 (plain GTP-U), or to re-apply a changed config from a clean state — run the following on **both PCs**.

> **Shortcut — stop both PCs at once:** the same helper does the full teardown (stop + flush xfrm) on both ends:
> ```bash
> cd ~/LKN_5G_Roaming_Testbed/VPLMN/docker/ipsectunnel   # (or the HPLMN repo, if on PC2)
> ./ipsec_tunnel.sh stop      # also: ./ipsec_tunnel.sh status
> ```
> The manual commands below are what it runs under the hood.

**Quick stop** (stops the strongSwan daemon and the active SA):
```bash
sudo ipsec stop
```

**Full teardown** (recommended) — also clears the kernel's IPsec policies/states so N9 traffic returns fully to cleartext:
```bash
sudo ipsec stop
sudo ip xfrm state flush
sudo ip xfrm policy flush
```

> **Why the flush matters:** a plain `sudo ipsec stop` stops the daemon, but **stale XFRM policies can survive in the kernel** and keep silently affecting N9 traffic (e.g. a leftover policy can blackhole or drop GTP-U even though strongSwan is no longer running). Flushing `xfrm state` and `xfrm policy` is the reliable way to get back to a known-good, cleartext N9 path. If you ever see the data plane misbehave after disabling IPsec, run the flush.

To drop **only one connection** while leaving the daemon running:
```bash
sudo ipsec down pc1-to-pc2-gtpu-tunnel-cert   # connection name from ipsec statusall
```

To bring the tunnel back up, re-run the setup scripts (**PC2 first, then PC1** — see [Step 5](#step-5-configure-and-start-ipsec-on-each-pc)) or simply `sudo ipsec start` on both PCs.

---

## Adapting to Your Environment

The following values are **hardcoded** in the scripts and must be updated for deployment on different machines. The `update_ipsec_ips.sh` script handles the IP addresses automatically, but you may need to manually adjust other values.

### IP Addresses (handled by update_ipsec_ips.sh)

| Script | Variable | Default | What to Change |
|--------|----------|---------|---------------|
| `01_setup_ca.sh` | `PC1_IP` | `10.0.0.10` | Your VPLMN PC IP |
| `01_setup_ca.sh` | `PC2_IP` | `10.0.0.21` | Your HPLMN PC IP |
| `03_setup_ipsec_pc1_cert.sh` | `left` | `10.0.0.10` | Your VPLMN PC IP |
| `03_setup_ipsec_pc1_cert.sh` | `right` | `10.0.0.21` | Your HPLMN PC IP |
| `03_setup_ipsec_pc2_cert.sh` | `left` | `10.0.0.21` | Your HPLMN PC IP |
| `03_setup_ipsec_pc2_cert.sh` | `right` | `10.0.0.10` | Your VPLMN PC IP |

### PLMN Identity (manual change if needed)

If you change the PLMN MCC/MNC values, update the certificate FQDNs and `leftid`/`rightid` in the IPsec configs:

| Value | PC1 (VPLMN) | PC2 (HPLMN) |
|-------|-------------|-------------|
| Certificate CN | `upf.5gc.mnc070.mcc999.3gppnetwork.org` | `upf.5gc.mnc001.mcc001.3gppnetwork.org` |
| IPsec leftid/rightid | Same as CN (in DN format) | Same as CN (in DN format) |

### Certificate Validity

| Parameter | Default | Location |
|-----------|---------|----------|
| CA validity | 3650 days (10 years) | `01_setup_ca.sh` → `CA_DAYS` |
| UPF certificate validity | 1825 days (5 years) | `01_setup_ca.sh` → `CERT_DAYS` |

---

## ESP Algorithm Modes

The testbed supports 6 ESP algorithm configurations, selectable via the `IPSEC_MODE` parameter in the automation config or via `esp_config.sh`:

| Mode | Algorithm | Encryption | Integrity |
|------|-----------|------------|-----------|
| 1 | AES-128-GCM | AES-128 (AEAD) | Built-in (GCM) |
| 2 | AES-256-GCM | AES-256 (AEAD) | Built-in (GCM) |
| 3 | AES-128-CBC + HMAC-SHA256 | AES-128 (CBC) | SHA-256 (separate) |
| 4 | AES-256-CBC + HMAC-SHA256 | AES-256 (CBC) | SHA-256 (separate) |
| 5 | NULL + SHA256 | **None** | SHA-256 |
| 6 | NULL + GMAC | **None** | AES-GMAC |

> **Warning:** Modes 5 and 6 provide **no encryption** — traffic is authenticated but readable. Use these only for benchmarking the overhead of encryption vs. integrity-only.

The IKE (Phase 1) negotiation always uses strong algorithms regardless of ESP mode: `aes128gcm16-prfsha256-ecp256` or `aes256gcm16-prfsha384-ecp384`.

---

## Verification

After setup, use these commands to verify the IPsec tunnel:

```bash
# Check tunnel status — look for "ESTABLISHED" (IKE SA) and "INSTALLED" (ESP SA)
sudo ipsec statusall

# View XFRM policies — should show entries for UDP port 2152
sudo ip xfrm policy

# View XFRM state — shows active SAs with encryption details
sudo ip xfrm state

# Monitor ESP packets in real time (while GTP-U traffic is flowing)
sudo tcpdump -i <interface> -nn esp

# List installed certificates
sudo ipsec listcerts
sudo ipsec listcacerts

# Check strongSwan logs
sudo journalctl -u strongswan -f
```

### Expected XFRM Policy Output

```
src 10.0.0.10/32[udp/2152] dst 10.0.0.21/32[udp/2152]
    dir out priority 375423
    tmpl src 10.0.0.10 dst 10.0.0.21
        proto esp spi 0xXXXXXXXX reqid 1 mode tunnel
```

This confirms that only GTP-U packets (UDP 2152) are captured by the IPsec policy.

---

## Integration with Automation

The `testbed_automation.sh` script can manage IPsec automatically during test runs. Set the following in your config file:

```bash
IPSEC_ENABLED=true
IPSEC_MODE=1          # Optional: select ESP algorithm (1-6)
```

The automation script will:
1. Stop any existing IPsec SAs at the beginning of the run
2. Start IPsec on both PCs (via SSH to HPLMN)
3. Wait for the tunnel to establish
4. Run the tests with IPsec active
5. Record IPsec mode in the JSON results

See [Automation Scripts](AUTOMATION.md#ipsec-configuration) for full details.

---

## Troubleshooting

### Tunnel Not Establishing

```bash
# Check logs for IKE negotiation errors
sudo journalctl -u strongswan -n 100

# Verify certificates are valid and trusted
sudo ipsec listcerts
sudo ipsec pki --verify --in /etc/ipsec.d/certs/pc1-upf-cert.pem \
    --cacert /etc/ipsec.d/cacerts/ca-cert.pem
```

### Common Issues

| Problem | Likely Cause | Solution |
|---------|-------------|----------|
| **IKE SA not establishing** | Firewall blocking UDP 500/4500 | Allow IKE ports: `sudo ufw allow 500/udp && sudo ufw allow 4500/udp` |
| **`NO_PROPOSAL_CHOSEN` / responder log says `no IKE config found for <A>...<B>`** | Stale peer IP: the responder's `/etc/ipsec.conf` `left=`/`right=` don't match the initiator's real IP (often after an IP change where the config was edited but never redeployed) | Compare `right=` (and `left=`) on both PCs against `.env`. Fix by regenerating config on the affected PC: `sudo ./03_setup_ipsec_pcX_cert.sh --no-start` (or re-run `deploy_ipsec.sh`). Despite the name, `NO_PROPOSAL_CHOSEN` here means "no matching connection," **not** a cipher mismatch. |
| **Certificate verification failed** | IP in cert doesn't match actual IP | Regenerate certificates after running `update_ipsec_ips.sh` with correct IPs, then re-run `01_setup_ca.sh` |
| **ESP SA not installing** | Mismatched ESP algorithms between PCs | Ensure both PCs use the same `esp=` line in `/etc/ipsec.conf`, or use `esp_config.sh` to set the same mode on both |
| **Tunnel established but no encryption** | XFRM policy not matching traffic | Verify UPF host IPs match `leftsubnet`/`rightsubnet` in ipsec.conf. Run `ip xfrm policy` to check. |
| **strongSwan not starting** | Service conflict | Stop existing: `sudo ipsec stop && sudo systemctl stop strongswan-starter`. Then retry. |
| **`ipsec pki` command not found** | strongSwan not installed | `sudo apt install strongswan strongswan-pki libcharon-extra-plugins` |

### Restart IPsec

```bash
# On both PCs
sudo ipsec restart

# Or force clean restart
sudo ipsec stop
sudo ip xfrm state flush
sudo ip xfrm policy flush
sudo ipsec start
```

---

## Further Documentation

| Document | Description |
|----------|-------------|
| [VPLMN Setup Guide](../VPLMN/README.md) | Full VPLMN installation and configuration |
| [HPLMN Setup Guide](../HPLMN/README.md) | HPLMN installation and configuration |
| [Automation Scripts](AUTOMATION.md) | Automated test execution with IPsec mode selection |
| [3GPP TS 33.210](https://portal.3gpp.org/desktopmodules/Specifications/SpecificationDetails.aspx?specificationId=2279) | 3GPP security specification for network domain security |