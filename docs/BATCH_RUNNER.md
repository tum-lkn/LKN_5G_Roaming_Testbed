# Batch Runner

The `batch_runner.sh` script orchestrates multiple test runs by invoking `testbed_automation.sh --config` for each configuration file in sequence. It supports running individual configs, all configs in a directory, repeating configs across multiple iterations, and auto-generating configs from a combinatorial `main.conf` file.

This script runs from the **VPLMN PC (PC1)**.

For details on the configuration file format and individual test parameters, see [Automation Scripts](AUTOMATION.md).

---

## Table of Contents

- [Quick Start](#quick-start)
- [Usage](#usage)
- [Modes of Operation](#modes-of-operation)
- [Dynamic Config Generation (main.conf)](#dynamic-config-generation-mainconf)
- [gtp5g Kernel Module Reload](#gtp5g-kernel-module-reload)
- [Performance Server Restarts](#performance-server-restarts)
- [Output & Logging](#output--logging)
- [Examples](#examples)

---

## Quick Start

```bash
cd ~/LKN_5G_Roaming_Testbed/VPLMN

# Run a single config
./batch_runner.sh configs/hr_plain.conf

# Run multiple configs
./batch_runner.sh configs/hr_plain.conf configs/lbo_plain.conf configs/non_roaming.conf

# Run all configs from main.conf with 3 repetitions
./batch_runner.sh --all --iterations 3
```

---

## Usage

```
./batch_runner.sh [OPTIONS] [<config_file> ...]
```

| Option | Description |
|--------|-------------|
| `-a`, `--all` | Generate and run all configurations from `configs/main.conf` |
| `-i`, `--iterations NUM` | Number of times to repeat each config (default: `1`) |
| `-r`, `--reload-interval NUM` | Reload the gtp5g kernel module every NUM completed runs (default: `10`, `0` to disable) |
| `-ris`, `--restart-iperf-server NUM` | Restart iPerf3 server via SSH every NUM completed runs (`0` to disable) |
| `-rds`, `--restart-download-server NUM` | Restart download server via SSH every NUM completed runs (`0` to disable) |
| `-h`, `--help` | Show help |

Config files can be specified as filenames (resolved relative to the `configs/` directory) or as absolute paths.

---

## Modes of Operation

### 1. Named Config Files

Pass one or more `.conf` files as arguments. Each is run sequentially through `testbed_automation.sh --config`:

```bash
./batch_runner.sh hr_plain.conf lbo_tls.conf
```

### 2. All Configs (`--all` with `main.conf`)

When `--all` is used, the script reads `configs/main.conf` and dynamically generates configuration files for all combinations of roaming modes, IXP latencies, Data Network locations, and ping payload sizes. Generated configs are saved to `configs/generated/` and executed sequentially. See [Dynamic Config Generation](#dynamic-config-generation-mainconf) below.

```bash
./batch_runner.sh --all
```

### 3. Multiple Iterations

The `--iterations` flag repeats the entire set of configs N times. The iteration order is: for each iteration, run all configs in order. This interleaves configs across iterations rather than running the same config N times consecutively.

```bash
# Run hr.conf and lbo.conf, 3 times each (6 total runs)
# Order: hr(1), lbo(1), hr(2), lbo(2), hr(3), lbo(3)
./batch_runner.sh -i 3 hr.conf lbo.conf
```

---

## Dynamic Config Generation (main.conf)

When `--all` is used, the script sources `configs/main.conf` which defines the test matrix as bash arrays. The script then generates a `.conf` file for every combination and runs them all.

### main.conf Structure

`main.conf` is a bash script that defines these arrays:

```bash
# Roaming modes to test
MODE_NAMES=("non-roaming" "lbo" "hr" "hr-ipsec")

# IXP latencies (one per simulated vPLMN location)
# Each index corresponds to a vPLMN (e.g., 0=France, 1=USA, 2=Australia)
LATENCIES=(10 50 100)
JITTERS=(2 5 10)
vPLMNs=("france" "usa" "australia")

# Data Network server locations and their latencies to various destinations
DN_LOCATIONS=("Frankfurt" "Paris" "Boston" "Sydney")
DN_LATENCIES_0=(1 10 50 150)     # Frankfurt → Frankfurt, Paris, Boston, Sydney
DN_LATENCIES_1=(10 1 45 160)     # Paris → Frankfurt, Paris, Boston, Sydney
DN_LATENCIES_2=(50 45 1 100)     # Boston → Frankfurt, Paris, Boston, Sydney
DN_LATENCIES_3=(150 160 100 1)   # Sydney → Frankfurt, Paris, Boston, Sydney
DN_JITTERS_0=(0 2 5 15)
DN_JITTERS_1=(2 0 5 16)
DN_JITTERS_2=(5 5 0 10)
DN_JITTERS_3=(15 16 10 0)

# Ping payload sizes to test
PING_PAYLOADS=(56 1400)

# Shared test parameters
ITERATIONS=10
PING_COUNT=20
PING_INTERVAL=0.02
PING_TARGET=8.8.8.8
ITERATION_DELAY=2
TESTBED_RESTART_INTERVAL=0
VPLMN_SECURITY=plain
HPLMN_SECURITY=plain

# Performance test configuration
PING_TEST_ENABLED=true
DOWNLOAD_TEST_ENABLED=true
DOWNLOAD_TEST_URL=http://10.162.149.210:9000/10MB.bin
DOWNLOAD_TEST_SIZE_LABEL=10MB
IPERF_TEST_ENABLED=true
IPERF_SERVER_IP=10.162.149.210
IPERF_SERVER_PORT=5201
IPERF_DURATION=30
IPERF_UDP=true
IPERF_BANDWIDTH=25M
IPERF_REVERSE=true
```

### How Combinations Are Generated

The script generates configs differently based on roaming mode:

**Non-Roaming:**
For each DN location × each payload size. No IXP latency is applied (no inter-PLMN link). N6 delay is applied based on the DN location's latency.

**LBO:**
For each vPLMN location (IXP latency) × corresponding DN location × each DN target destination × each payload size. The vPLMN-to-DN mapping follows geographic proximity (e.g., France vPLMN → Paris DN server).

**HR and HR-IPsec:**
For each vPLMN location (IXP latency) × Frankfurt DN only (home network is always Germany) × each DN target destination × each payload size. IPsec is enabled for HR-IPsec mode.

### Generated Config Naming Convention

```
<mode>_<vplmn>_dn_<dn_target>_pld<payload>.conf
```

Examples:
- `hr_france_dn_frankfurt_pld56.conf`
- `lbo_usa_dn_boston_pld1400.conf`
- `non_roaming_dn_paris_pld56.conf`

### Generated Delay Rules

Each generated config includes appropriate delay rules:

| Mode | IXP Delay Rules | N6 Delay |
|------|----------------|----------|
| Non-Roaming | None | DN location latency on local UPF + server |
| LBO | GTP-U delay on both UPFs + SEPP N32 delay on both SEPPs | DN location latency on local UPF + server |
| HR | GTP-U delay on both UPFs + SEPP N32 delay on both SEPPs | DN location latency on remote UPF + server |
| HR-IPsec | IPsec (ESP) delay on both UPFs + SEPP N32 delay on both SEPPs | DN location latency on remote UPF + server |

---

## gtp5g Kernel Module Reload

Long-running batch experiments can occasionally encounter gtp5g kernel module instability. The `--reload-interval` option periodically unloads and reloads the module to prevent this:

```bash
# Reload gtp5g every 10 completed runs
./batch_runner.sh --all -i 5 -r 10

# Disable automatic reload
./batch_runner.sh --all -i 5 -r 0
```

The reload is performed between test runs, not during an active test. The script calls `sudo rmmod gtp5g` followed by `sudo modprobe gtp5g`.

---

## Performance Server Restarts

The iPerf3 and download server can crash after running for several weeks. The `-ris` and `-rds` flags allow the batch runner to automatically restart the iPerf3 server and/or the download HTTP server via SSH at a configurable interval.

```bash
# Restart iPerf3 server every 20 completed runs
./batch_runner.sh --all -ris 20

# Restart download server every 15 completed runs
./batch_runner.sh --all -rds 15

# Restart both servers every 10 completed runs
./batch_runner.sh --all -i 3 -ris 10 -rds 10

# Disable server restarts (default)
./batch_runner.sh --all -ris 0 -rds 0
```

When a restart interval is set (> 0), the script also performs an **initial restart at the beginning** of the batch run, before the first test. This ensures a clean server state for the entire batch.

Restarts are performed **between** test runs, never during an active test.

### SSH Connection

Server restarts are performed via SSH using the same credentials as `testbed_automation.sh`:

| Parameter | Default | Override via |
|-----------|---------|--------------|
| Server IP | `10.162.149.210` | `IPERF_SERVER_IP` or `SERVER_IP` in `main.conf` |
| SSH user | `roaming` | `SERVER_USER` in `main.conf` |

Key-based SSH authentication must be configured (no password prompts). The testbed uses two performance servers depending on the config:

| Server | Used by |
|--------|---------|
| `10.162.149.210` | `main.conf`, non-roaming configs |
| `10.162.149.117` | `hr.conf`, `lbo.conf`, `hr_ipsec_*.conf` |

Both servers require the same one-time setup below.

#### Step 1 — Set up key-based SSH authentication

Run once from PC1 for each server (replace the IP accordingly):

```bash
# Remove any stale host key entry (if you get "Host key verification failed")
ssh-keygen -R <SERVER_IP>

# Connect interactively to accept and store the host key — type "yes" when prompted
ssh roaming@<SERVER_IP> "echo ok"

# Copy your public key so no password is needed going forward
# (generate a key first if you don't have one: ssh-keygen -t ed25519 -N "")
ssh-copy-id roaming@<SERVER_IP>

# Verify non-interactive (BatchMode) access works — should print "ok"
ssh -o ConnectTimeout=10 -o BatchMode=yes roaming@<SERVER_IP> "echo ok"
```

Repeat for both servers:
```bash
# perf-server 1
ssh-copy-id roaming@10.162.149.210
ssh -o BatchMode=yes roaming@10.162.149.210 "echo ok"

# perf-server 2
ssh-copy-id roaming@10.162.149.117
ssh -o BatchMode=yes roaming@10.162.149.117 "echo ok"
```

#### Step 2 — Configure passwordless sudo for service restarts

The restart commands use `sudo systemctl restart`. This must be allowed without a password on each server. SSH in interactively and run:

```bash
ssh roaming@<SERVER_IP>

# On the server:
echo "roaming ALL=(ALL) NOPASSWD: /bin/systemctl restart iperf3, /bin/systemctl restart iperf, /bin/systemctl restart caddy, /bin/systemctl restart nginx, /bin/systemctl restart apache2, /bin/systemctl restart httpd" | sudo tee /etc/sudoers.d/roaming-restart
sudo chmod 440 /etc/sudoers.d/roaming-restart

# Verify it works without a password prompt:
sudo systemctl restart iperf3
exit
```

Repeat for both servers.

#### Step 3 — Verify the restart function end-to-end

```bash
cd ~/LKN_5G_Roaming_Testbed/VPLMN

# Test both iPerf3 and download server against perf-server 1
bash --norc << 'TEST'
PERF_SERVER_IP="10.162.149.210"
PERF_SERVER_USER="roaming"
PERF_SSH_CONNECT_TIMEOUT=10
PERF_SSH_BATCH_MODE="yes"
log() { echo "[$(date +"%Y-%m-%d %H:%M:%S")] $*"; }
source <(sed -n "/^restart_iperf_server/,/^}/p" batch_runner.sh)
source <(sed -n "/^restart_download_server/,/^}/p" batch_runner.sh)
restart_iperf_server && restart_download_server
TEST

# Test against perf-server 2
bash --norc << 'TEST'
PERF_SERVER_IP="10.162.149.117"
PERF_SERVER_USER="roaming"
PERF_SSH_CONNECT_TIMEOUT=10
PERF_SSH_BATCH_MODE="yes"
log() { echo "[$(date +"%Y-%m-%d %H:%M:%S")] $*"; }
source <(sed -n "/^restart_iperf_server/,/^}/p" batch_runner.sh)
source <(sed -n "/^restart_download_server/,/^}/p" batch_runner.sh)
restart_iperf_server && restart_download_server
TEST
```

Both should print `✅ iPerf3 server restarted successfully` and `✅ Download server restarted successfully`.

### Restart Behaviour

- **iPerf3 server**: Attempts `sudo systemctl restart iperf3` (or `iperf` service). Falls back to `pkill iperf3` + `iperf3 -s --daemon` if no systemd service is found.
- **Download server**: Attempts `sudo systemctl restart` for common service names (`caddy`, `nginx`, `apache2`, `httpd`, `http-server`) in order. Falls back to `pkill -f file_download_server.py` + relaunch from `~/download_server` or `~/performance-server-main` with verification that port 9000 is listening.

If a restart fails, a warning is logged and the batch run **continues** rather than aborting.

---

### Results

Each config run produces its own JSON results file via `testbed_automation.sh`. All results are saved to the `results/` directory:

```
results/
├── hr_france_dn_frankfurt_pld56_20250115_103000.json
├── hr_france_dn_frankfurt_pld1400_20250115_103500.json
├── lbo_usa_dn_boston_pld56_20250115_104000.json
└── ...
```

### Runner Log

The batch runner maintains its own log file tracking the overall progress:

```
logs/batch_runner_<TIMESTAMP>.log
```

This log includes per-run success/failure status, execution time, progress estimates, and a final summary.

### Summary Output

At the end of the run (or on Ctrl+C interrupt), the script prints:

```
═══════════════════════════════════════════════════════════════
                    BATCH RUNNER SUMMARY
═══════════════════════════════════════════════════════════════

📊 Results:
   Successful: 24
   Failed: 1
   Total: 25

📋 Detailed Results:
   ✅ hr_france_dn_frankfurt_pld56 [Iteration 1/1]: SUCCESS (245.30s)
   ✅ hr_france_dn_frankfurt_pld1400 [Iteration 1/1]: SUCCESS (250.12s)
   ❌ lbo_usa_dn_boston_pld56 [Iteration 1/1]: FAILED (30.50s)
   ...

⏱️  Total Runner Execution Time: 6125.40s (102.09min)
═══════════════════════════════════════════════════════════════
```

### Interrupt Handling

Pressing Ctrl+C during a batch run triggers a graceful shutdown. The script prints a partial summary of completed runs before exiting. Results from already-completed configs are preserved.

---

## Examples

### Run a single test

```bash
./batch_runner.sh configs/hr_plain.conf
```

### Run multiple named configs, each repeated 3 times

```bash
./batch_runner.sh -i 3 hr_tls.conf lbo_tls.conf non_roaming_tls.conf
```

### Run all combinations from main.conf

```bash
./batch_runner.sh --all
```

### Run all combinations, 5 repetitions, gtp5g reload every 15 runs

```bash
./batch_runner.sh --all --iterations 5 --reload-interval 15
```

### Run all combinations with gtp5g reload disabled

```bash
./batch_runner.sh --all -i 10 -r 0
```

### Restart iPerf3 server every 20 runs

```bash
./batch_runner.sh --all -ris 20
```

### Restart both servers every 15 runs, 3 iterations

```bash
./batch_runner.sh --all -i 3 -ris 15 -rds 15
```

---

## Directory Structure

```
VPLMN/
├── batch_runner.sh                    # This script
├── testbed_automation.sh              # Invoked per config run
├── configs/
│   ├── main.conf                      # Test matrix definition (for --all)
│   ├── hr_plain.conf                  # Individual config files
│   ├── lbo_tls.conf
│   └── generated/                     # Auto-generated configs (created by --all)
│       ├── hr_france_dn_frankfurt_pld56.conf
│       ├── lbo_usa_dn_boston_pld1400.conf
│       └── ...
├── results/                           # JSON results from each run
└── logs/
    └── batch_runner_<TIMESTAMP>.log   # Runner log
```
