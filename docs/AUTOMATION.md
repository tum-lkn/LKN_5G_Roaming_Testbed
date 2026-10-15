# Testbed Automation

This document describes the `testbed_automation.sh` script (v3.3.0) and its configuration file format. The script automates the full lifecycle of a test run — starting both PLMNs, configuring IPsec, applying network delays, launching PacketRusher, running tests, collecting results, and cleaning up.

The script runs from the **VPLMN PC (PC1)** and controls the HPLMN (PC2) over SSH.

For batch experiments across multiple configurations, see [Batch Runner](BATCH_RUNNER.md).

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Operating Modes](#operating-modes)
- [Configuration File Reference](#configuration-file-reference)
- [Test Types](#test-types)
- [Network Delay Emulation](#network-delay-emulation)
- [IPsec Configuration](#ipsec-configuration)
- [Output Format](#output-format)
- [Execution Flow](#execution-flow)
- [Hardcoded Values](#hardcoded-values)
- [Example Configurations](#example-configurations)
- [Internal Structure](#internal-structure)

---

## Prerequisites

The following tools must be available on the VPLMN PC:

```bash
docker ssh jq bc curl nsenter
```

The script checks for these at startup and exits if any are missing.

Additionally:
- **SSH key-based access** from PC1 to PC2 (passwordless) for controlling the HPLMN
- **SSH key-based access** from PC1 to the performance test server (if download/iperf/video tests or N6 delay are enabled)
- **iperf3 server** running on the performance test server (if iperf tests are enabled)
- **HTTP file server** running on the performance test server (if download/video tests are enabled)
- **`sitespeedio/browsertime` Docker image** pulled on the VPLMN PC (if webpage tests are enabled):
  ```bash
  docker pull sitespeedio/browsertime
  ```

---

## Quick Start

**Generate a sample config and run it:**

```bash
cd ~/LKN_5G_Roaming_Testbed/VPLMN

# Generate a sample configuration file
./testbed_automation.sh --generate-config my_test.conf

# Edit to match your setup
nano my_test.conf

# Run the automated test
./testbed_automation.sh --config my_test.conf
```

**Interactive mode (prompts for all settings):**

```bash
./testbed_automation.sh
```

---

## Operating Modes

| Mode | Flag | Description |
|------|------|-------------|
| **Interactive** | _(no flags)_ | Prompts for roaming mode, security, IPsec, delays, and test parameters. Starts both PLMNs, runs tests, then cleans up. |
| **Config file** | `--config <file>` | Reads all settings from a `.conf` file. No user prompts. Recommended for reproducible experiments. |
| **Quick** | `--quick` | Assumes both PLMNs are already running. Prompts only for test parameters. Useful for re-running tests without restarting containers. |
| **Generate config** | `--generate-config <file>` | Outputs a sample configuration file with all available parameters and exits. |

```bash
./testbed_automation.sh                            # Interactive
./testbed_automation.sh --config my_test.conf      # Config file
./testbed_automation.sh --quick                    # Quick mode
./testbed_automation.sh --generate-config test.conf # Generate sample
```

---


---

## Configuration File Reference

The configuration file is a key-value file (`.conf`) with `#` comments. All parameters are optional — defaults are used if not specified. Boolean values accept `true/false`, `yes/no`, or `1/0`.

### Roaming & Security

| Parameter | Values | Default | Description |
|-----------|--------|---------|-------------|
| `ROAMING_MODE` | `hr`, `lbo`, `non-roaming` | _(required)_ | Roaming mode for the test |
| `IPSEC_ENABLED` | `true/false` | `false` | Enable IPsec for N9 user plane (HR mode only) |
| `IPSEC_MODE` | `1`–`6` | _(current config)_ | IPsec ESP algorithm selection (see [IPsec Configuration](#ipsec-configuration)) |
| `VPLMN_SECURITY` | `tls`, `plain` | `plain` | VPLMN NF-to-NF security mode |
| `HPLMN_SECURITY` | `tls`, `plain` | `plain` | HPLMN NF-to-NF security mode |

### UE Type (PacketRusher or Commercial RAN)

| Parameter | Values | Default | Description |
|-----------|--------|---------|-------------|
| `UE_TYPE` | `packetrusher`, `dsk` | `packetrusher` | Which UE runs the tests. `dsk` uses the commercial gNB with a USB dongle instead of PacketRusher |
| `DSK_DONGLE` | `a`, `b` | `a` | Which dongle to use (`UE_TYPE=dsk`) |
| `DSK_CYCLE` | `airplane`, `reboot` | `airplane` | How each iteration makes the dongle re-register: radio off/on (seconds) or a reboot (minutes) |

With `UE_TYPE=dsk` the same steps run against the dongle: registration / PDU timings from the NGAP capture, and ping, download and iperf3 as the same commands run on the dongle. The core is restarted per config as usual, after which the gNB is restarted and the dongle re-registered; the SIM in the dongle must match `ROAMING_MODE`; the video test is skipped; results go to `results_dsk/`. See [COMMERCIAL_RAN.md](COMMERCIAL_RAN.md#running-the-automation-and-the-batch-runner-with-the-dongle).

### Test Parameters

| Parameter | Values | Default | Description |
|-----------|--------|---------|-------------|
| `ITERATIONS` | `1`–`100` | `5` | Number of test iterations. Each iteration starts PacketRusher, runs all enabled tests, then stops PacketRusher. |
| `PING_COUNT` | integer | `10` | Number of pings per iteration |
| `PING_TARGET` | IP address | `8.8.8.8` | Ping destination |
| `PING_INTERVAL` | seconds | `1` | Interval between pings (e.g., `0.02` for 20ms) |
| `PING_PAYLOAD_SIZE` | bytes | `56` (default) | Ping payload size (e.g., `1400`) |
| `ITERATION_DELAY` | seconds | `2` | Wait time between iterations |
| `TESTBED_RESTART_INTERVAL` | integer | `0` | Restart both PLMNs every N iterations. `0` = never restart. |
| `MAX_LOG_FILES` | integer | `20` | Maximum number of log files to keep per category (`batch_*.log`, `packetrusher_iter*.log`). Older files are deleted automatically when the limit is reached. |

### Test Enable/Disable

| Parameter | Default | Description |
|-----------|---------|-------------|
| `PING_TEST_ENABLED` | `true` | Enable ICMP ping latency test |
| `DOWNLOAD_TEST_ENABLED` | `false` | Enable HTTP file download test |
| `VIDEO_TEST_ENABLED` | `false` | Enable video streaming download test |
| `IPERF_TEST_ENABLED` | `false` | Enable iperf3 throughput test |
| `WEBPAGE_TEST_ENABLED` | `false` | Enable real-browser webpage loading test (Browsertime) |

### Server Configuration

> **What the performance server must provide.** The automation applies the DN server's half of the N6 delay over SSH with `sudo tc` on `SERVER_INTERFACE`. So the SSH user needs key-based login **and passwordless `sudo tc`** on that server, and `SERVER_INTERFACE` must be the server's interface that carries the testbed network (check with `ip -br addr` there; it is not always `ens18`). One-time, on the server:
>
> ```bash
> echo '<user> ALL=(root) NOPASSWD: /usr/sbin/tc' | sudo tee /etc/sudoers.d/roamingtb-tc && sudo chmod 440 /etc/sudoers.d/roamingtb-tc
> ```
>
> The preflight checks both and stops the run before anything is restarted if either is missing. The delay is netem on the whole interface, so it also slows everything else that server sends on it while a config runs.

The download, video streaming, and iperf3 tests require a performance test server running an HTTP file server and/or iperf3 daemon. In the default configuration, this is a local server on the same LAN as the testbed PCs. The script connects to this server via SSH to apply N6 delays on its network interface.

> **Note:** You are free to use any server — local or public — for performance testing. Simply update the `SERVER_IP`, `SERVER_USER`, `SERVER_INTERFACE`, `DOWNLOAD_TEST_URL`, `VIDEO_TEST_URL`, and `IPERF_SERVER_IP` parameters in the configuration file to point to your own server. If using a public server, note that N6 delay emulation on the server side will not be available (it requires SSH access to apply `tc` rules on the server's interface). In that case, set `N6_DELAY_ENABLED=false` or use only the ogstun-side delay via traditional delay rules.
>
> To deploy your own local performance server:
> 1. Set up any HTTP file server (e.g., `python3 -m http.server`, nginx, or a custom server) serving test files (e.g., `1MB.bin`, `10MB.bin`, `100MB.bin`)
> 2. Run `iperf3 -s -p 5201 -D` for throughput testing
> 3. Ensure SSH key-based access from PC1 to the server (required for N6 delay emulation)
> 4. Update the server parameters in your `.conf` file accordingly

| Parameter | Default | Description |
|-----------|---------|-------------|
| `SERVER_IP` | `10.0.0.30` | Performance test server IP |
| `SERVER_USER` | `roaming` | SSH user for the server |
| `SERVER_INTERFACE` | `ens18` | Server's main network interface (for N6 delay application) |

### Download Test Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `DOWNLOAD_TEST_URL` | _(none)_ | Full URL to download (e.g., `http://10.0.0.30:9000/10MB.bin`) |
| `DOWNLOAD_TEST_SIZE_LABEL` | _(none)_ | Label for the file size (e.g., `10MB`) — used in results output only |

### Video Streaming Test Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `VIDEO_TEST_URL` | _(none)_ | Full URL to video file (e.g., `http://10.0.0.30:9000/video_150MB.mp4`) |
| `VIDEO_TEST_SIZE_LABEL` | _(none)_ | Label for display (e.g., `150MB Video`) |

### iperf3 Test Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `IPERF_SERVER_IP` | _(none)_ | iperf3 server IP address |
| `IPERF_SERVER_PORT` | `5201` | iperf3 server port |
| `IPERF_DURATION` | `10` | Test duration in seconds |
| `IPERF_PARALLEL` | `1` | Number of parallel streams |
| `IPERF_REVERSE` | `false` | Reverse mode — server sends to client (measures download speed) |
| `IPERF_UDP` | `false` | Use UDP instead of TCP |
| `IPERF_BANDWIDTH` | _(none)_ | Target bandwidth for UDP mode only (e.g., `25M`, `100M`) |
| `IPERF_TCP_BANDWIDTH` | _(none)_ | Rate cap for TCP mode; empty = uncapped |

### Webpage Test Configuration (Browsertime — v3.3.0)

Loads real web pages through the UE's PDU session using a real browser (Firefox or Chrome) via the [`sitespeedio/browsertime`](https://github.com/sitespeedio/browsertime) Docker image. The browser container shares the PacketRusher network namespace (`--net container:packetrusher`) so all traffic flows through the 5G GTP tunnel. VRF policy routing is configured inside the container so infrastructure traffic stays on the local network and all other traffic is routed through the GTP tunnel.

Captured metrics per URL, per iteration:

| Metric | Description |
|--------|-------------|
| **TTFB** | Time to First Byte — server response latency |
| **FCP** | First Contentful Paint — first visible content rendered |
| **LCP** | Largest Contentful Paint — main content rendered (may be 0 on SPA/JS-heavy pages) |
| **DCL** | DOMContentLoaded — HTML parsed, DOM ready |
| **Page Load** | `pageLoadTime` — the browser's load event (`loadEventEnd`): the page and all its synchronous resources have loaded. A page whose load event never fires within the timeout is recorded as a **failed** load |
| **Net idle** | `fullyLoaded` — the network went fully quiet; includes background traffic after the page has loaded (analytics, lazy loads, polling), so it is noisy and not the page-load time |

> **LCP note:** LCP is 0 for heavily client-rendered pages (e.g., Facebook) because the browser closes the LCP observation window before JavaScript injects large content. FCP and Page Load are still valid for such pages.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `WEBPAGE_TEST_ENABLED` | `false` | Enable the Browsertime webpage loading test |
| `WEBPAGE_BROWSER` | `firefox` | Browser to use: `firefox` or `chrome` |
| `WEBPAGE_ITERATIONS` | `1` | Number of Browsertime iterations per URL (medians are reported) |
| `WEBPAGE_TIMEOUT` | `120` | Timeout in seconds per URL |
| `WEBPAGE_URL_1` | _(none)_ | First URL to test |
| `WEBPAGE_URL_2` | _(none)_ | Second URL to test |
| `WEBPAGE_URL_N` | _(none)_ | Add as many URLs as needed, incrementing N |

Old parameters `WEBPAGE_YOUTUBE_URL` and `WEBPAGE_INSTAGRAM_URL` are still accepted for backward compatibility and are appended to the URL list with a deprecation warning.

**Requirements:**
- The `sitespeedio/browsertime` Docker image must be available (`docker pull sitespeedio/browsertime`)
- The `jq` command must be installed on the host
- Working internet access through the UE's PDU session (DNS, HTTP/HTTPS)
- The `nsenter` command (standard on Ubuntu — part of `util-linux`)

> **Note:** Raw Browsertime JSON output is saved to `logs/browsertime_<TIMESTAMP>/` for each run, organized by site name. These contain the full timing breakdown, HAR files, and screenshots if visual metrics are enabled.

---

### Performance Tuning

| Parameter | Default | Description |
|-----------|---------|-------------|
| `NETWORK_READY_TIMEOUT` | `30` | Max seconds to wait for services to become healthy |
| `SERVICE_CHECK_INTERVAL` | `1` | Seconds between health checks |
| `IPSEC_ESTABLISH_TIMEOUT` | `10` | Max seconds to wait for IPsec SA establishment |
| `MIN_NETWORK_STABILIZE_TIME` | `10` | Minimum wait after services are healthy before running tests |
| `MIN_LINK_SPEED_MBPS` | `1000` | Preflight fails if the VPLMN or HPLMN NIC (the interface towards the other PC) is slower, e.g. a gigabit link that fell back to 100 Mb/s. `0` disables the check |

---

## Test Types

Each iteration runs the enabled tests in this order:

### 1. Ping Test

Sends ICMP pings from the UE (inside the PacketRusher container) through the PDU session to the target. Captures min/avg/max/mdev RTT, packet loss, and individual RTT values.

### 2. Download Test

Uses `curl` inside the PacketRusher container to download a file from the performance server through the UE's PDU session. Captures file size, download speed, and timing breakdown (DNS lookup, TCP connect, TLS handshake, time to first byte, total time).

### 3. Video Streaming Test

Same as the download test but with a larger video file. Additionally calculates the effective streaming bitrate in Mbps to estimate video streaming quality.

### 4. iperf3 Test

Runs an iperf3 client inside the PacketRusher container connected to the iperf3 server. Supports both TCP (captures throughput and retransmits) and UDP (captures throughput, jitter, and packet loss). Reverse mode measures download throughput.

- TCP throughput is the **received** rate in both directions.
- `target_bandwidth` in the results is the rate passed to iperf3: `IPERF_BANDWIDTH` for UDP, `IPERF_TCP_BANDWIDTH` for TCP (`null` = uncapped).
- iperf 3.0/3.1 (the dongle has 3.1.3) also counts reordered UDP datagrams as lost. Loss is reported as `lost − out_of_order`; the raw values are kept in `lost_packets_raw` and `out_of_order`.

### 5. Webpage Loading Test (Browsertime)

Launches a `sitespeedio/browsertime` Docker container that shares the PacketRusher network namespace. Policy routing rules are configured inside the container to route non-infrastructure traffic through the GTP VRF. The VRF `l3mdev` socket accept sysctl (`net.ipv4.tcp_l3mdev_accept`) is enabled before the test and restored after. Runs Firefox or Chrome against each configured URL and captures TTFB, FCP, LCP, DCL, and Page Load time (all in milliseconds, median across Browsertime iterations). Raw Browsertime JSON output is saved to `logs/browsertime_<TIMESTAMP>/`.

---

## Network Delay Emulation

The script supports two types of network delay emulation using Linux `tc` (traffic control):

### N6 Delay (Data Network Latency)

Simulates the latency between the UPF and the internet (Data Network). When enabled, the same delay is applied to **both** the UPF's `ogstun` interface and the performance server's network interface, creating symmetric bidirectional delay.

Both halves act on traffic to the performance server, which is what ping, download and iperf use. Traffic to any other destination — the pages of the webpage test — never reaches that server, so the automation also applies the same delay at the UPF in the uplink direction for all destinations except the performance server (via an IFB device on `ogstun`). Every destination therefore sees the full N6 delay (RTT + 2 × `N6_DELAY_VALUE`).

| Parameter | Description |
|-----------|-------------|
| `N6_DELAY_ENABLED` | Enable/disable N6 delay |
| `N6_DELAY_VALUE` | Delay per direction (e.g., `50ms` → ~100ms RTT) |
| `N6_DELAY_JITTER` | Optional jitter (e.g., `10ms`) |

Where the delay is applied depends on the roaming mode:

| Roaming Mode | ogstun Delay Applied On | Reason |
|--------------|------------------------|--------|
| HR | HPLMN UPF (remote, via SSH) | HPLMN UPF provides Data Network breakout |
| LBO | VPLMN UPF (local) | VPLMN UPF provides Data Network breakout |
| Non-Roaming | VPLMN UPF (local) | Only one UPF |

**Typical latency values:**

| Scenario | One-way delay (`N6_DELAY_VALUE`) | Approximate RTT |
|----------|----------------------------------|-----------------|
| Same country | `10ms` | ~20ms |
| US East Coast | `50ms` | ~100ms |
| US West Coast | `75ms` | ~150ms |
| Europe | `50ms` | ~100ms |
| Asia | `100ms` | ~200ms |

### Traditional Delay Rules (Per-Interface)

For fine-grained control, you can add delay to specific NF interfaces using `DELAY_RULE_*` parameters. These require `DELAY_ENABLED=true` to take effect.

Every netem queue (batch and WebUI) holds `NETEM_LIMIT` packets (default 10000, set in `lib/automation/delays.sh`). The kernel default of 1000 dropped 25–70 % of a 100 Mb/s iperf stream at 150 ms delay.

> **Important — Delay Directionality:** Linux `tc` (traffic control) can only apply delay to **outgoing (egress) packets**. This means traditional delay rules are **unidirectional** — they only affect traffic leaving the specified interface. For example, `local:open5gs-upf:gtpu=50ms` adds 50ms delay only to GTP-U packets **sent by** the local UPF, not to incoming packets. To simulate bidirectional delay, you must add matching rules on both ends (e.g., `DELAY_RULE_1=local:open5gs-upf:gtpu=50ms` and `DELAY_RULE_2=remote:open5gs-upf:gtpu=50ms`).
>
> In contrast, **N6 delay** achieves bidirectional delay by applying the same `tc` rule on both the UPF's `ogstun` interface and the performance server's network interface, so outgoing packets are delayed at both ends.

**Format:**
```
DELAY_RULE_<N>=<location>:<service>:<mode>=<delay>[:<jitter>]
```

**Location:** `local` (VPLMN) or `remote` (HPLMN, applied via SSH)

**Available modes per service:**

| Service | Mode | What It Affects |
|---------|------|-----------------|
| `open5gs-upf` | `gtpu` | N9 user plane to the other PLMN's host only: GTP-U (udp/2152), ESP when N9 IPsec is on, and all other UDP to that host (IP fragments carry no port). IKE (udp/500) is not delayed |
| `open5gs-upf` | `ipsec` | ESP protocol traffic — IPsec-encrypted N9 |
| `open5gs-upf` | `pfcp` | PFCP traffic (port 8805) — N4 control plane (SMF ↔ UPF) |
| `open5gs-upf` | `n6` | N6 interface (`ogstun`) — UPF to Data Network |
| `open5gs-upf` | `n3` | N3 interface (local only) — gNB to UPF |
| `open5gs-upf` | `full` | All UPF traffic |
| `open5gs-sepp` | `n32` | N32 interface (ports 8080/8081) — inter-PLMN signaling |
| `open5gs-sepp` | `eth0` | All SEPP container traffic |
| `open5gs-smf` | `pfcp` | PFCP traffic to UPF (port 8805) |
| `open5gs-smf` | `eth0` | All SMF container traffic |
| _(other NFs)_ | `eth0` | All container traffic (applied to the container's `eth0`) |

**Examples:**

```bash
# 50ms delay on N9 GTP-U between UPFs (both directions)
DELAY_RULE_1=local:open5gs-upf:gtpu=50ms
DELAY_RULE_2=remote:open5gs-upf:gtpu=50ms

# 25ms delay with 5ms jitter on SEPP N32 signaling
DELAY_RULE_3=local:open5gs-sepp:n32=25ms:5ms

# Combined N9 + N6 delay for full roaming simulation
DELAY_ENABLED=true
DELAY_RULE_1=local:open5gs-upf:ipsec=25ms:5ms
DELAY_RULE_2=remote:open5gs-upf:ipsec=25ms:5ms
N6_DELAY_ENABLED=true
N6_DELAY_VALUE=50ms
N6_DELAY_JITTER=10ms
```

> **Note:** N6 delay (`N6_DELAY_ENABLED`) and traditional delay rules (`DELAY_ENABLED`) are independent. You can use either or both together.

---

## IPsec Configuration

When `IPSEC_ENABLED=true`, the script configures IPsec between the VPLMN and HPLMN UPFs to encrypt N9 user plane traffic (GTP-U). This is only relevant in **HR roaming mode**.

The `IPSEC_MODE` parameter selects the ESP algorithm:

| Mode | Algorithm | Description |
|------|-----------|-------------|
| 1 | AES-128-GCM | AEAD, fast, hardware-accelerated |
| 2 | AES-256-GCM | AEAD, stronger key |
| 3 | AES-128-CBC + HMAC-SHA256 | Separate encryption and integrity |
| 4 | AES-256-CBC + HMAC-SHA256 | Separate, stronger key |
| 5 | NULL + SHA256 | No encryption — integrity only |
| 6 | NULL + GMAC | No encryption — integrity only |

If `IPSEC_MODE` is not set, the current IPsec configuration on the system is used without modification.

The script manages IPsec lifecycle automatically: it always stops IPsec at the beginning of a run to ensure a clean state, then starts it if `IPSEC_ENABLED=true`. IPsec status is checked on both PCs.

---

## Output Format

Results are saved as JSON to the `results/` directory. The filename is derived from the config file name and the run timestamp:

```
results/<config_name>_<YYYYMMDD_HHMMSS>.json
```

Where `<config_name>` is the config file's basename without the `.conf` extension (e.g., `--config roaming_baseline.conf` → `roaming_baseline_20260410_123150.json`). In interactive mode (no `--config`), the filename falls back to `batch_results_<YYYYMMDD_HHMMSS>.json`.

### JSON Structure

```json
{
  "test_info": {
    "version": "3.3.0",
    "timestamp": "2025-01-15T10:30:00+00:00",
    "roaming_mode": "hr",
    "ipsec_enabled": true,
    "ipsec_mode": "1",
    "vplmn_security": "plain",
    "hplmn_security": "plain",
    "iterations": 10,
    "ping_count": 10,
    "ping_target": "8.8.8.8",
    "delays": { ... }
  },
  "iterations": [
    {
      "iteration": 1,
      "timestamp": "2025-01-15T10:30:05+00:00",
      "status": "success",
      "ue_ip": "10.45.0.2",
      "vrf": "vrf0000000001",
      "timing_ms": {
        "total": 1250,
        "startup_to_registration": 800,
        "registration_to_pdu_init": 150,
        "pdu_setup": 300
      },
      "ping_results": {
        "total": 10,
        "successful": 10,
        "failed": 0,
        "min_ms": 5.2,
        "avg_ms": 8.1,
        "max_ms": 12.3,
        "mdev_ms": 2.1,
        "individual_rtts": [5.2, 7.8, ...]
      },
      "download_results": {
        "success": true,
        "size_bytes": 10485760,
        "speed_bytes_per_sec": 5242880,
        "time_dns_sec": 0.002,
        "time_connect_sec": 0.005,
        "time_ttfb_sec": 0.010,
        "time_total_sec": 2.0,
        "remote_ip": "10.0.0.30",
        "http_code": 200
      },
      "video_results": { ... },
      "iperf_results": {
        "success": true,
        "bits_per_second": 25000000,
        "bytes_transferred": 93750000,
        "retransmits": 0,
        "jitter_ms": 1.2,
        "lost_packets": 5,
        "lost_percent": 0.01,
        "lost_packets_raw": 5,
        "out_of_order": 0,
        "protocol": "udp",
        "reverse_mode": true
      },
      "webpage_results": [
        {
          "url": "https://www.youtube.com/@Cristiano",
          "site_name": "www.youtube.com",
          "success": true,
          "ttfb_ms": 312,
          "fcp_ms": 525,
          "lcp_ms": 525,
          "dcl_ms": 591,
          "page_load_ms": 7445
        },
        { ... }
      ]
    }
  ],
  "summary": {
    "total_iterations": 10,
    "successful_iterations": 10,
    "failed_iterations": 0,
    "timing_total_ms": { "min": 1100, "max": 1400, "avg": 1250 },
    "ping_rtt_ms": { "min": 4.8, "max": 15.2, "avg": 8.1 },
    "download_test": { "speed_bytes_per_sec": { "min": ..., "max": ..., "avg": ... } },
    "iperf_test": { "bits_per_second": { "min": ..., "max": ..., "avg": ... } },
    "webpage_test": {
      "by_url": [
        {
          "url": "https://www.youtube.com/@Cristiano",
          "successful": 10,
          "failed": 0,
          "ttfb_ms":      { "min": 280, "max": 420, "avg": 312 },
          "fcp_ms":       { "min": 490, "max": 650, "avg": 525 },
          "lcp_ms":       { "min": 490, "max": 650, "avg": 525 },
          "dcl_ms":       { "min": 540, "max": 710, "avg": 591 },
          "page_load_ms": { "min": 6800, "max": 9200, "avg": 7445 }
        },
        { ... }
      ]
    }
  }
}
```

The `timing_ms` fields capture PacketRusher's UE registration and PDU session establishment timings, parsed from the container logs.

---

## Execution Flow

When running with `--config`, the script follows this sequence:

```
1. Parse configuration file
2. Print config summary
3. Generate .env files for both PLMNs
4. Preflight checks:
   ├── Docker available (local + remote)
   ├── SSH to HPLMN (PC2)
   ├── SSH to performance server (if N6 delay or tests need it)
   ├── Link speed of the VPLMN/HPLMN NICs (MIN_LINK_SPEED_MBPS)
   ├── Required Docker images exist
   └── PacketRusher image available
5. Check current IPsec status (HR mode)
6. Start both PLMNs in parallel:
   ├── HPLMN: docker compose up (via SSH)
   └── VPLMN: docker compose up (local)
7. Wait for services to be healthy:
   ├── Local critical NFs: AMF, SMF, UPF, NRF
   └── Remote critical NFs: AMF, SMF, UPF, NRF, SEPP
8. Configure IPsec (if enabled)
9. Apply traditional delay rules (if DELAY_ENABLED=true)
10. Apply N6 delays (if N6_DELAY_ENABLED=true):
    ├── ogstun delay on appropriate UPF
    └── Server interface delay via SSH
11. Run batch iterations:
    For each iteration:
    ├── Start PacketRusher → parse UE IP and VRF
    ├── Run ping test (if enabled)
    ├── Run download test (if enabled)
    ├── Run video test (if enabled)
    ├── Run iperf3 test (if enabled)
    ├── Run webpage loading test (if enabled)
    ├── Record results to JSON
    ├── Stop PacketRusher
    └── Wait iteration delay
12. Compute summary statistics
13. Cleanup:
    ├── Remove all applied delays
    └── Stop PacketRusher
```

> **Note:** The script does NOT stop the Docker containers on exit. Both PLMNs remain running after the test completes.

---

## Hardcoded Values

The following values are hardcoded in the script and must be edited manually if your environment differs:

| Variable | Value | Description |
|----------|-------|-------------|
| `REMOTE_PC_IP` | `10.0.0.21` | HPLMN PC IP for SSH |
| `REMOTE_PC_USER` | `roaming` | SSH user for HPLMN PC |
| `REMOTE_PC_PATH` | `~/LKN_5G_Roaming_Testbed/HPLMN` | HPLMN project directory |
| `PR_IP` | `192.168.70.190` | PacketRusher container IP |
| `PR_IMAGE` | `packetrusher:20250225` | PacketRusher Docker image (built from source by `docker/packetrusher-docker/build_packetrusher.sh`) |
| `PR_NETWORK` | `5gc_research_testbed_vplmn_my_second_network` | Docker network for PacketRusher |

Update these at the top of `testbed_automation.sh` before first use.

---

## Example Configurations

### Basic HR Roaming (no delays)

```bash
ROAMING_MODE=hr
IPSEC_ENABLED=true
IPSEC_MODE=1
VPLMN_SECURITY=plain
HPLMN_SECURITY=plain
ITERATIONS=5
PING_TEST_ENABLED=true
DOWNLOAD_TEST_ENABLED=true
IPERF_TEST_ENABLED=true
DELAY_ENABLED=false
N6_DELAY_ENABLED=false
```

### HR Roaming with N6 Delay (simulate 100ms RTT to internet)

```bash
ROAMING_MODE=hr
IPSEC_ENABLED=true
IPSEC_MODE=1
ITERATIONS=5
PING_TEST_ENABLED=true
DOWNLOAD_TEST_ENABLED=true
# 50ms applied to BOTH ogstun (remote UPF) and server (ens18)
# Total RTT ≈ 100ms (50ms each direction)
N6_DELAY_ENABLED=true
N6_DELAY_VALUE=50ms
N6_DELAY_JITTER=10ms
```

### Combined N9 + N6 Delay (full roaming simulation)

```bash
ROAMING_MODE=hr
IPSEC_ENABLED=true
IPSEC_MODE=1
ITERATIONS=5
PING_TEST_ENABLED=true
DOWNLOAD_TEST_ENABLED=true
# N9 delay (IPsec tunnel between UPFs)
DELAY_ENABLED=true
DELAY_RULE_1=local:open5gs-upf:ipsec=25ms:5ms
DELAY_RULE_2=remote:open5gs-upf:ipsec=25ms:5ms
# N6 delay (to data network)
N6_DELAY_ENABLED=true
N6_DELAY_VALUE=50ms
N6_DELAY_JITTER=10ms
```

### LBO with iperf3 UDP throughput test

```bash
ROAMING_MODE=lbo
ITERATIONS=3
PING_TEST_ENABLED=false
DOWNLOAD_TEST_ENABLED=false
IPERF_TEST_ENABLED=true
IPERF_SERVER_IP=10.0.0.30
IPERF_SERVER_PORT=5201
IPERF_DURATION=30
IPERF_UDP=true
IPERF_BANDWIDTH=50M
IPERF_REVERSE=true
```

### Full benchmark suite with Browsertime webpage test

```bash
ROAMING_MODE=hr
IPSEC_ENABLED=false
VPLMN_SECURITY=plain
HPLMN_SECURITY=plain
SERVER_IP=10.0.0.30
SERVER_USER=roaming
SERVER_INTERFACE=ens18
ITERATIONS=5
PING_TEST_ENABLED=true
PING_COUNT=10
DOWNLOAD_TEST_ENABLED=true
DOWNLOAD_TEST_URL=http://10.0.0.30:9000/10MB.bin
DOWNLOAD_TEST_SIZE_LABEL=10MB
VIDEO_TEST_ENABLED=true
VIDEO_TEST_URL=http://10.0.0.30:9000/video_150MB.mp4
VIDEO_TEST_SIZE_LABEL=150MB Video
IPERF_TEST_ENABLED=true
IPERF_SERVER_IP=10.0.0.30
IPERF_SERVER_PORT=5201
IPERF_DURATION=10
WEBPAGE_TEST_ENABLED=true
WEBPAGE_BROWSER=firefox
WEBPAGE_ITERATIONS=1
WEBPAGE_TIMEOUT=120
WEBPAGE_URL_1=https://www.youtube.com/@Cristiano
WEBPAGE_URL_2=https://www.instagram.com/leomessi/
WEBPAGE_URL_3=https://www.google.com/search?q=lionel+messi
WEBPAGE_URL_4=https://en.wikipedia.org/wiki/Cristiano_Ronaldo
WEBPAGE_URL_5=https://github.com/open5gs/open5gs
WEBPAGE_URL_6=http://1.1.1.1
DELAY_ENABLED=false
N6_DELAY_ENABLED=false
```

### Full benchmark suite (all tests, no webpage)

```bash
ROAMING_MODE=hr
IPSEC_ENABLED=true
IPSEC_MODE=1
VPLMN_SECURITY=plain
HPLMN_SECURITY=plain
SERVER_IP=10.0.0.30
SERVER_USER=roaming
SERVER_INTERFACE=ens18
ITERATIONS=10
PING_TEST_ENABLED=true
PING_COUNT=20
PING_INTERVAL=0.1
DOWNLOAD_TEST_ENABLED=true
DOWNLOAD_TEST_URL=http://10.0.0.30:9000/10MB.bin
DOWNLOAD_TEST_SIZE_LABEL=10MB
VIDEO_TEST_ENABLED=true
VIDEO_TEST_URL=http://10.0.0.30:9000/video_150MB.mp4
VIDEO_TEST_SIZE_LABEL=150MB Video
IPERF_TEST_ENABLED=true
IPERF_SERVER_IP=10.0.0.30
IPERF_SERVER_PORT=5201
IPERF_DURATION=30
IPERF_UDP=true
IPERF_BANDWIDTH=50M
IPERF_REVERSE=true
DELAY_ENABLED=false
N6_DELAY_ENABLED=false
```

---

## Internal Structure

`testbed_automation.sh` is a thin orchestrator — the actual logic lives in shared subscripts under `lib/automation/`. See [`lib/automation/README.md`](../VPLMN/lib/automation/README.md) if you need to modify a specific component (delay logic, test types, results handling, etc.).
