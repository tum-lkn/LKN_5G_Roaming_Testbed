#!/usr/bin/env bash

set -e

# ============================================================================
# Open5GS Roaming Testbed - Batch Automation Script v3.2.5
# v3.3.0: BROWSERTIME WEB PAGE LOADING TESTS
#         - Replaced curl-based webpage test with real browser (Browsertime)
#         - Uses sitespeedio/browsertime Docker image sharing PacketRusher netns
#         - Traffic routed through 5G GTP tunnel via VRF policy routing
#         - VRF l3mdev socket accept auto-enabled/restored per test run
#         - Configurable list of URLs (WEBPAGE_URL_1, WEBPAGE_URL_2, ...)
#         - Interactive URL selection menu in interactive mode
#         - Metrics: TTFB (ms) and Page Load time (ms) per URL per iteration
#         - Results in JSON: array of per-URL objects, aggregated in summary
#         - Configurable browser (firefox/chrome) and Browsertime iterations
#         - Backward compat: WEBPAGE_YOUTUBE_URL / WEBPAGE_INSTAGRAM_URL mapped
# v3.2.5: WEB PAGE LOADING TESTS
#         - Added test_single_webpage() and perform_webpage_test()
#         - Tests YouTube and Instagram loading time through UE PDU session
#         - Manual DNS resolution (nslookup) to work inside VRF
#         - Detailed timing: DNS, TCP connect, TLS handshake, TTFB, total
#         - Results in JSON per iteration and aggregated in summary
#         - Configurable URLs and timeout via config file or interactive mode
#         - Added MAX_LOG_FILES to prune old PacketRusher logs automatically
# v3.2.4: IPERF3 SERVER OUTPUT SUPPORT
#         - Added --get-server-output flag to iperf3 commands
#         - Captures server-side throughput, retransmits, jitter, packet loss
#         - Both client and server perspectives shown in results table
#         - Server output included in JSON results per iteration
#         - Summary aggregates server-side metrics (min/max/avg)
#         - Graceful fallback if server iperf3 version doesn't support JSON output
# v3.2.3: MERGED N6 DELAY + SERVER UPDATE
#         - Merged N6 ogstun delay and server delay into single config
#         - When N6_DELAY_ENABLED=true, delay applied to BOTH:
#           * UPF ogstun (tun device) - LBO→local, HR→remote
#           * Server main interface (ens18) - all traffic
#         - Removed separate N6_SERVER_DELAY_* parameters
#         - Updated default server to 10.0.0.30 (perf-server)
#         - Added SERVER_IP, SERVER_USER, SERVER_INTERFACE config params
#         - Default server interface changed to ens18
# v3.2.2: N6 INTERFACE DELAY MODE
#         - Added N6 delay mode for simulating data network latency
#         - Delay applied to UPF's ogstun interface (tun device)
#         - For LBO: delay on local UPF (VPLMN handles DN traffic)
#         - For HR: delay on remote UPF (HPLMN handles DN traffic)
#         - Added server port delay for bidirectional delay simulation
#         - Updated default server URLs to VPLMN VM (10.0.0.10)
# v3.2.1: NEW FEATURE - IPERF3 TEST MODE
#         - Added iperf3-based throughput test for accurate bandwidth measurement
#         - Supports TCP and UDP modes with configurable parameters
#         - Reverse mode (download) and parallel streams support
#         - Captures throughput, retransmits (TCP), jitter and packet loss (UDP)
#         - Requires iperf3 server running on target machine
# v3.2.0: NEW FEATURE - DOWNLOAD TEST MODE
#         - Added curl-based download test after ping tests
#         - Configurable download URL and file size label
#         - Captures detailed metrics: size, speed, timing breakdown
#         - Results saved to JSON including download statistics
#         - Supports HTTP/HTTPS downloads through UE PDU session
# v3.1.2: IMPROVED PREFLIGHT DIAGNOSTICS
#         - Preflight checks now run sequentially with detailed status output
#         - Each check reports success/failure individually
#         - Error message shows exactly which check(s) failed
#         - Removed parallel background checks (caused silent failures)
# v3.1.1: BUG FIX - ARITHMETIC OPERATIONS WITH set -e
#         - Fixed ((var++)) causing script exit when var=0
#         - ((0++)) evaluates to 0, which returns exit code 1 in bash
#         - Changed to var=$((var + 1)) which always returns exit code 0
#         - Affected: preflight_check, start_networks_parallel, start_all_ipsec
# v3.1.0: NEW FEATURE - IPSEC MODE SELECTION
#         - Added IPSEC_MODE parameter (1-6) to select ESP configuration
#         - Integrates with esp_config.sh for automatic IPsec config updates
#         - Supports AES-GCM, AES-CBC+SHA256, and NULL (integrity-only) modes
#         - IPsec mode is recorded in test results JSON
# v3.0.3: CRITICAL BUG FIX
#         - Fixed IPsec status check functions returning 1 when stopped
#         - With set -e, return 1 caused script to exit silently
#         - Status checks now always return 0 (success) since they're not errors
# v3.0.2: IPSEC HANDLING IMPROVEMENT
#         - Always stops IPsec at the beginning regardless of IPSEC_ENABLED flag
#         - Ensures clean state before optionally starting IPsec
# v3.0.1: BUG FIX
#         - Fixed IPsec status check using subshells (variables not propagating)
#         - Now always stops IPsec when IPSEC_ENABLED=false regardless of status
# v3.0.0: ENHANCED VERSION
#         - Fixed DELAY_ENABLED flag bug (explicit false now honored)
#         - Added SEPP N32 delay modes (ports 8080/8081)
#         - Added SMF PFCP delay mode (port 8805)
#         - Added jitter support for all delay configurations
#         - Made ping payload size configurable
#         - Made ping interval configurable
#         - Parallel network startup (HPLMN + VPLMN simultaneously)
#         - Health-check based waiting instead of fixed sleeps
# ============================================================================

SCRIPT_VERSION="3.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE=".env"
CONFIG_DIR="$SCRIPT_DIR/configs/Packetrusher_Configs"
LOG_DIR="$SCRIPT_DIR/logs"
RESULTS_DIR="$SCRIPT_DIR/results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BATCH_RESULTS_FILE=""  # Will be set based on config name or using default

# Cooperative cancellation flag. The WebUI backend writes this file to request a
# cancel (in addition to SIGINT); the script polls it via check_cancel() at every
# checkpoint. Clear any stale flag from a previous run at startup.
CANCEL_FLAG="$LOG_DIR/.automation_cancel"
mkdir -p "$LOG_DIR" 2>/dev/null || true
rm -f "$CANCEL_FLAG" 2>/dev/null || true

# Remote PC settings (Home Network - HPLMN)
HPLMN_IP="10.162.149.24"
REMOTE_PC_USER="wassim"
REMOTE_PC_PATH="~/LKN_5G_Roaming_Testbed/HPLMN"

# PacketRusher settings
PR_IP="192.168.70.190"
PR_CONTAINER="packetrusher"
PR_IMAGE="packetrusher:20250225"
PR_NETWORK="my_second_network"

# Network names
VPLMN_CONTROL_PLANE_NETWORK="my_custom_network"
VPLMN_USER_PLANE_NETWORK="my_second_network"
HPLMN_CONTROL_PLANE_NETWORK="my_custom_network"

# IPsec settings
IPSEC_ENABLED="false"
IPSEC_MODE=""                     # IPsec ESP mode (1-6), empty = use current config
N4_IPSEC_ENABLED="false"          # N4 (SMF<->UPF PFCP) IPsec — legacy alias, sets both per-PLMN flags
N4_IPSEC_VPLMN_ENABLED="false"    # N4 IPsec on VPLMN (SMF<->UPF, local host)
N4_IPSEC_HPLMN_ENABLED="false"    # N4 IPsec on HPLMN (SMF<->UPF, remote host; roaming modes only)
N4_IPSEC_VPLMN_MODE=""            # N4 VPLMN ESP mode (1-6), empty = keep current/last cipher
N4_IPSEC_HPLMN_MODE=""            # N4 HPLMN ESP mode (1-6), empty = keep current/last cipher
N9_CONN="pc1-to-pc2-gtpu-tunnel-cert"  # N9 IPsec conn (VPLMN initiator); auto=add, so it must be brought up explicitly
LOCAL_IPSEC_STATUS=""
REMOTE_IPSEC_STATUS=""

# IPsec ESP configuration script path (relative to SCRIPT_DIR)
IPSEC_CONFIG_SCRIPT="$SCRIPT_DIR/docker/ipsectunnel/ipsec_update_configs/esp_config.sh"

# IPsec mode descriptions for display
declare -A IPSEC_MODE_NAMES
IPSEC_MODE_NAMES[1]="AES-128-GCM (AEAD)"
IPSEC_MODE_NAMES[2]="AES-256-GCM (AEAD)"
IPSEC_MODE_NAMES[3]="AES-128-CBC + HMAC-SHA256"
IPSEC_MODE_NAMES[4]="AES-256-CBC + HMAC-SHA256"
IPSEC_MODE_NAMES[5]="NULL + SHA256 (NO ENCRYPTION)"
IPSEC_MODE_NAMES[6]="NULL + GMAC (NO ENCRYPTION)"

# Roaming mode descriptions for display
declare -A ROAMING_MODE_NAMES
ROAMING_MODE_NAMES["non-roaming"]="non-roaming"
ROAMING_MODE_NAMES["lbo"]="lbo (Local Breakout)"
ROAMING_MODE_NAMES["hr"]="hr (Home Routed)"
ROAMING_MODE_NAMES["hr-ipsec"]="hr-ipsec (Home Routed with IPsec)"
ROAMING_MODE_NAMES["hr-remote-upf"]="hr-remote-upf (Home Routed with Remote UPF)"

# Port configurations
GTPU_PORT=2152
PFCP_PORT=8805
IPSEC_NAT_T_PORT=4500
IPSEC_IKE_PORT=500
ESP_PROTOCOL=50
SEPP_N32_PORT_1=8080
SEPP_N32_PORT_2=8081

# Delay configuration
declare -A DELAY_CONFIGS
declare -a APPLIED_DELAYS
DELAY_ENABLED="false"
DELAY_ENABLED_EXPLICIT="false"  # Track if DELAY_ENABLED was explicitly set

# N6 Delay Configuration (MERGED in v3.2.3)
# Simulates data network (internet) latency
# When enabled, delay is applied to BOTH:
#   1) UPF ogstun (tun device) - LBO→local UPF, HR→remote UPF
#   2) Server main interface - all traffic
N6_DELAY_ENABLED="false"
N6_DELAY_VALUE=""              # Delay value (e.g., 50ms)
N6_DELAY_JITTER=""             # Optional jitter (e.g., 10ms)

# Performance test server configuration (Updated in v3.2.3)
SERVER_IP="10.162.149.185"         # Performance test server IP
SERVER_USER="roaming"              # SSH user for server
SERVER_INTERFACE="ens18"           # Server main network interface
MIN_LINK_SPEED_MBPS=1000           # Preflight fails if a testbed link is slower (0 = off)
DEFAULT_DOWNLOAD_PORT="9000"
DEFAULT_IPERF_PORT="5201"

# Performance tuning - CONFIGURABLE TIMEOUTS
NETWORK_READY_TIMEOUT=30          # Max seconds to wait for services to be healthy
SERVICE_CHECK_INTERVAL=1          # Seconds between health checks
IPSEC_ESTABLISH_TIMEOUT=10        # Max seconds to wait for IPsec
MIN_NETWORK_STABILIZE_TIME=10     # Minimum time to allow network stabilization
SSH_CONNECT_TIMEOUT=10            # SSH connection timeout
SSH_BATCH_MODE="yes"              # Use batch mode for SSH

# Ping configuration
PING_PAYLOAD_SIZE=""              # Empty = default (56 bytes), otherwise specify size in bytes
PING_INTERVAL="1"                 # Default ping interval in seconds
PING_TEST_ENABLED="true"          # Enable/disable ping test

# Config metadata (for JSON output)
VPLMN_NAME=""                     # vPLMN name extracted from config
DN_LOCATION=""                    # DN server location
DN_LATENCY=""                     # DN latency value
DN_JITTER=""                      # DN jitter value

# Download test configuration (NEW in v3.2.0)
DOWNLOAD_TEST_ENABLED="false"     # Enable/disable download test
DOWNLOAD_TEST_URL=""              # URL to download from (e.g., http://10.0.0.30:9000/10MB.bin)
DOWNLOAD_TEST_SIZE_LABEL=""       # Label for display (e.g., "10MB")

# Download test results (global for current iteration)
DL_SUCCESS=""
DL_SIZE_BYTES=0
DL_SPEED_BPS=0
DL_TIME_DNS=0
DL_TIME_CONNECT=0
DL_TIME_TLS=0
DL_TIME_TTFB=0
DL_TIME_TOTAL=0
DL_REMOTE_IP=""
DL_HTTP_CODE=0

# Video streaming test configuration (NEW in v3.2.0)
VIDEO_TEST_ENABLED="false"        # Enable/disable video streaming test
VIDEO_TEST_URL=""                 # URL to video file
VIDEO_TEST_SIZE_LABEL=""          # Label for display (e.g., "150MB Video")

# Video test results (global for current iteration)
VID_SUCCESS=""
VID_SIZE_BYTES=0
VID_SPEED_BPS=0
VID_TIME_DNS=0
VID_TIME_CONNECT=0
VID_TIME_TTFB=0
VID_TIME_TOTAL=0
VID_REMOTE_IP=""
VID_HTTP_CODE=0
VID_STREAMING_MBPS=0

# iperf3 test configuration (NEW in v3.2.1)
IPERF_TEST_ENABLED="false"        # Enable/disable iperf3 test
IPERF_SERVER_IP=""                # iperf3 server IP address
IPERF_SERVER_PORT="5201"          # iperf3 server port (default: 5201)
IPERF_DURATION="10"               # Test duration in seconds
IPERF_PARALLEL="1"                # Number of parallel streams
IPERF_REVERSE="false"             # Reverse mode (server sends to client)
IPERF_UDP="false"                 # Use UDP instead of TCP
IPERF_BANDWIDTH=""                # Target bandwidth for UDP (e.g., 100M)
# Optional rate cap for TCP (iperf3 -b, e.g. 100M). Empty = no cap: TCP then
# measures what the path can carry. A cap turns the test into "does the path
# sustain this rate, and with how many retransmits" (e.g. to compare TCP and
# UDP at the same load). Kept apart from IPERF_BANDWIDTH so a UDP rate set in
# main.conf does not silently cap TCP runs.
IPERF_TCP_BANDWIDTH=""

# iperf3 test results (global for current iteration)
IPERF_SUCCESS=""
IPERF_BITS_PER_SEC=0
IPERF_BYTES_TRANSFERRED=0
IPERF_RETRANSMITS=0
IPERF_JITTER_MS=0
IPERF_LOST_PACKETS=0
IPERF_LOST_PERCENT=0

# iperf3 server-side results (NEW in v3.2.4 - --get-server-output)
IPERF_SRV_BITS_PER_SEC=0
IPERF_SRV_BYTES_TRANSFERRED=0
IPERF_SRV_RETRANSMITS=0
IPERF_SRV_JITTER_MS=0
IPERF_SRV_LOST_PACKETS=0
IPERF_SRV_LOST_PERCENT=0
IPERF_SRV_OUTPUT_AVAILABLE="false"

# Web page loading test configuration (Updated in v3.3.0 — Browsertime-based)
WEBPAGE_TEST_ENABLED="false"      # Enable/disable webpage loading test
WEBPAGE_TIMEOUT=120               # Max seconds per URL (docker run timeout)
WEBPAGE_BROWSER="firefox"         # Browser: firefox, chrome or edge
WEBPAGE_ITERATIONS=1              # Browsertime iterations per URL (medians)
BT_IMAGE="sitespeedio/browsertime" # Browsertime Docker image
# Fixed container name, deliberately shared with lib/features/browsertime_5g.sh and the WebUI.
# Every browsertime run joins PacketRusher's network namespace, where the ip
# rules are global rather than per-container, so two concurrent runs delete each
# other's routing. Reusing one name makes Docker refuse the second run instead.
BT_CONTAINER="roamingtb-browsertime"
# Resolvers applied inside the browsertime container. The image otherwise
# inherits the host's resolvers, which are typically site-local addresses that
# become unreachable once traffic is routed into the tunnel. Public resolvers are
# reachable through the tunnel, keep DNS latency inside the measured 5G path, and
# carry no site-specific assumptions.
BT_DNS_SERVERS="${BT_DNS_SERVERS:-8.8.8.8 1.1.1.1}"
WEBPAGE_URLS=()                   # List of URLs to test (populated from config or interactive)

# Web page test results (global array of JSON strings, one entry per URL)
declare -a WEBPAGE_TEST_RESULTS=()

# Log file management (NEW in v3.2.5)
MAX_LOG_FILES=10                  # Keep the N most recent PacketRusher log files

VPLMN_SERVICES=("open5gs-nrf" "open5gs-scp" "open5gs-amf" "open5gs-smf" "open5gs-upf" "open5gs-ausf" "open5gs-udm" "open5gs-pcf" "open5gs-nssf" "open5gs-bsf" "open5gs-udr" "open5gs-sepp")
HPLMN_SERVICES=("open5gs-nrf" "open5gs-scp" "open5gs-amf" "open5gs-smf" "open5gs-upf" "open5gs-ausf" "open5gs-udm" "open5gs-pcf" "open5gs-nssf" "open5gs-bsf" "open5gs-udr" "open5gs-sepp")
HOST_NETWORK_SERVICES=("open5gs-upf")

# Services that support port-specific delay modes
PORT_DELAY_SERVICES=("open5gs-sepp" "open5gs-smf")

# Critical services to check for health (subset for faster checks)
CRITICAL_SERVICES_LOCAL=("amf" "smf" "upf" "nrf")
CRITICAL_SERVICES_REMOTE=("amf" "smf" "upf" "nrf" "sepp")

# Timing variables
PR_SUCCESS=""
PR_ERROR=""
PR_UE_IP=""
PR_VRF=""
PR_CONTAINER_START_TS=""
PR_REG_INIT_TS=""
PR_PDU_INIT_TS=""
PR_PDU_COMPLETE_TS=""
PR_TOTAL_MS=""
PR_STARTUP_TO_REG_MS=""
PR_REG_TO_PDU_INIT_MS=""
PR_PDU_SETUP_MS=""

TESTBED_RESTART_INTERVAL=0

# Config file mode
CONFIG_FILE_MODE="false"
CONFIG_FILE_PATH=""

# Timing metrics for optimization tracking
STARTUP_METRICS_ENABLED="true"
declare -A STARTUP_TIMINGS

# ============================================================================
# Utility Functions
# ============================================================================

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
}

error_exit() {
    log "❌ ERROR: $1"
    exit 1
}

get_timestamp_ms() {
    echo $(($(date +%s%N)/1000000))
}

# ============================================================================
# Local docker → sudo
# ============================================================================
# The automation may be launched by a process that is NOT in the 'docker' group
# — e.g. the WebUI backend, started right after setup adds the user to the group
# but before a re-login makes it active. Plain `docker` then fails with
# "permission denied ... /var/run/docker.sock" and preflight aborts with
# "Local Docker check failed". Route every LOCAL docker call through sudo, which
# is passwordless here (see lib/setup/setup_sudoers.sh). This does NOT affect
# the `docker ...` commands embedded in ssh strings to HPLMN: those are run by
# the remote login shell (which already has the docker group), never this
# function, so the remote side keeps working unchanged. `sudo` execs the docker
# binary from PATH, not this shell function, so there is no recursion.
docker() { sudo docker "$@"; }

# ============================================================================
# Load Subscript Libraries
# ============================================================================

source "$SCRIPT_DIR/lib/automation/config.sh"
source "$SCRIPT_DIR/lib/automation/preflight.sh"
source "$SCRIPT_DIR/lib/automation/networks.sh"
source "$SCRIPT_DIR/lib/automation/delays.sh"
source "$SCRIPT_DIR/lib/automation/tests.sh"
source "$SCRIPT_DIR/lib/automation/dsk.sh"
source "$SCRIPT_DIR/lib/automation/results.sh"

# ============================================================================
# Setup
# ============================================================================

mkdir -p "$LOG_DIR" "$RESULTS_DIR"

DEFAULT_ITERATIONS=5
DEFAULT_PING_COUNT=10
DEFAULT_TARGET="8.8.8.8"

# ============================================================================
# Main Functions
# ============================================================================

run_with_config_file() {
    local config_file="$1"
    CONFIG_FILE_MODE="true"; CONFIG_FILE_PATH="$config_file"

    # Extract config base name (without .conf extension) for JSON filename
    local config_basename=$(basename "$config_file" .conf)
    BATCH_RESULTS_FILE="$RESULTS_DIR/${config_basename}_${TIMESTAMP}.json"

    record_timing total_start

    log "╔════════════════════════════════════════════════════════════╗"
    log "║   Open5GS Batch Automation Script v$SCRIPT_VERSION                  ║"
    log "║   Mode: Configuration File (Automated + Optimized)        ║"
    log "╚════════════════════════════════════════════════════════════╝"

    parse_config_file "$config_file"
    # The file name above was built before the config was read, so a
    # RESULTS_DIR set in the config only created the folder and the results
    # still went to results/. Re-root the file in whatever RESULTS_DIR is now.
    BATCH_RESULTS_FILE="$RESULTS_DIR/$(basename "$BATCH_RESULTS_FILE")"
    if is_dsk; then
        dsk_load_settings
        dsk_apply_results_dir      # DSK results live apart from PacketRusher's
        if [ "$VIDEO_TEST_ENABLED" = "true" ]; then
            log "ℹ️  The video test is not available with a dongle (UE_TYPE=dsk) — skipping it"
            VIDEO_TEST_ENABLED=false
        fi
        log "📡 UE: commercial RAN — dongle $DSK_DONGLE ($DSK_DONGLE_HOST), re-registering by $DSK_CYCLE; results in $RESULTS_DIR"
    fi
    # batch_runner.sh needs to know which file belongs to which run, to set
    # it aside if the run is discarded later (RAN recovery).
    [ -n "${BATCH_RUN_RESULT_NOTE:-}" ] && echo "$BATCH_RESULTS_FILE" > "$BATCH_RUN_RESULT_NOTE"
    print_config_summary
    create_env_file_from_config

    # Optimized startup sequence
    preflight_check

    # Check IPsec status in parallel with preflight (for HR mode)
    [ "$ROAMING_MODE" = "hr" ] && check_ipsec_status
    check_n4_ipsec_status

    # Start both networks in parallel
    start_networks_parallel

    # Wait for services with health checks (parallel)
    wait_for_all_services

    # Commercial RAN: the core was just restarted, so the gNB has to be
    # restarted to connect to the new AMF, and the dongle to attach again.
    if is_dsk; then
        if ! dsk_bring_up_ran; then
            DSK_RAN_DEGRADED=1; DSK_DEGRADED_REASON="the RAN did not come up (gNB / dongle)"
            log "❌ ERROR: The commercial RAN did not come up (gNB / dongle) — see above"
            exit "$DSK_EXIT_RAN_DEGRADED"
        fi
        dsk_ru_snapshot
    fi

    # Configure IPsec (optimized parallel startup)
    configure_ipsec
    configure_n4_ipsec

    # Apply delays
    apply_preconfigured_delays
    apply_n6_delays

    record_timing total_end

    # Run the actual batch tests
    run_batch
    print_summary
    is_dsk && dsk_ru_report "the start of the run"
    is_dsk && dsk_fail_if_incomplete
    log "✅ All steps completed at $(date +'%Y-%m-%d %H:%M:%S')"
}

# --recover-ran: reboot the RU, wait, restart the gNB, reboot the dongle
# (dsk_recover_ran). batch_runner.sh calls it after a run stopped because the
# RAN degraded, and on its schedule. Uses the config only for the DSK settings;
# the core keeps running as it is.
recover_ran_with_config_file() {
    local config_file="$1"
    CONFIG_FILE_MODE="true"; CONFIG_FILE_PATH="$config_file"
    parse_config_file "$config_file"
    is_dsk || error_exit "--recover-ran needs a config with UE_TYPE=dsk"
    # Nothing of the run's own setup is brought up here, so the EXIT cleanup
    # must not tear any of it down (IPsec of the run that comes next).
    IPSEC_ENABLED=false; N4_IPSEC_ENABLED=false; N4_IPSEC_VPLMN_ENABLED=false; N4_IPSEC_HPLMN_ENABLED=false
    dsk_load_settings
    dsk_recover_ran || error_exit "RAN recovery failed — see above"
}

main() {
    clear
    record_timing total_start

    log "╔════════════════════════════════════════════════════════════╗"
    log "║   Open5GS Batch Automation Script v$SCRIPT_VERSION                  ║"
    log "║   Mode: Interactive (Optimized)                           ║"
    log "╚════════════════════════════════════════════════════════════╝"

    if [[ ! "$(pwd)" =~ VPLMN ]]; then
        log "⚠️  Warning: Not in VPLMN directory"
        read -rp "Continue anyway? [y/N]: " c; [[ ! "$c" =~ ^[Yy]$ ]] && exit 0
    fi

    select_mode
    preflight_check

    # Start both networks in parallel
    start_networks_parallel

    # Wait for services with health checks
    wait_for_all_services

    configure_ipsec
    configure_n4_ipsec
    apply_preconfigured_delays
    apply_n6_delays

    record_timing total_end

    run_batch
    print_summary
    is_dsk && dsk_fail_if_incomplete
    log "✅ All steps completed at $(date +'%Y-%m-%d %H:%M:%S')"
}

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Open5GS Batch Automation Script v$SCRIPT_VERSION

OPTIONS:
  --config, -c <file>      Run tests using configuration file (automated mode)
  --recover-ran <file>     UE_TYPE=dsk: reboot the RU, wait, restart the gNB, reboot the dongle
  --generate-config <file> Generate a sample configuration file
  --quick, -q              Quick mode (networks assumed running)
  --help, -h               Show this help message

NEW IN v3.3.0:
  - Real-browser webpage loading tests via Browsertime (sitespeedio/browsertime)
  - Configurable URL list: WEBPAGE_URL_1=..., WEBPAGE_URL_2=..., etc.
  - Interactive URL selection menu (add from defaults or enter custom)
  - Metrics: TTFB (ms) and Page Load time (ms) per URL, medians across iterations
  - Traffic routed through 5G GTP tunnel via VRF policy routing rules
  - VRF l3mdev sysctl auto-managed (tcp/udp_l3mdev_accept=1 during test)
  - Configurable browser (WEBPAGE_BROWSER) and per-URL iterations (WEBPAGE_ITERATIONS)
  - Backward compat: WEBPAGE_YOUTUBE_URL / WEBPAGE_INSTAGRAM_URL still accepted
  Config keys: WEBPAGE_TEST_ENABLED, WEBPAGE_BROWSER, WEBPAGE_ITERATIONS,
               WEBPAGE_TIMEOUT, WEBPAGE_URL_1, WEBPAGE_URL_2, ...

NEW IN v3.2.5:
  - Web page loading tests (YouTube, Instagram) through UE PDU session
  - Manual DNS resolution inside VRF for reliable external domain testing
  - Detailed per-site timing: DNS, TCP, TLS, TTFB, total load time
  - MAX_LOG_FILES: automatic pruning of old PacketRusher log files
  Config keys: WEBPAGE_TEST_ENABLED, WEBPAGE_TIMEOUT,
               WEBPAGE_YOUTUBE_URL, WEBPAGE_INSTAGRAM_URL, MAX_LOG_FILES

NEW IN v3.2.4:
  - iperf3 server-side output (--get-server-output)
  - Both client and server throughput in results table and JSON

NEW IN v3.2.3:
  - Merged N6 delay configuration: single delay value applied to BOTH
    UPF ogstun and server interface automatically
  - Added SERVER_IP, SERVER_USER, SERVER_INTERFACE config parameters
  - Updated default server to 10.0.0.30 (perf-server, ens18)

N6 DELAY (MERGED in v3.2.3):
  When N6_DELAY_ENABLED=true, the delay is applied to:
    1) UPF ogstun (tun device):
       - LBO mode  -> local UPF (VPLMN handles DN)
       - HR mode   -> remote UPF (HPLMN handles DN)
       - Non-roaming -> local UPF
    2) Server interface (ens18 on \$SERVER_IP):
       - Applied to all traffic on server interface

  Config:
    N6_DELAY_ENABLED=true
    N6_DELAY_VALUE=50ms
    N6_DELAY_JITTER=10ms    # optional

SERVER CONFIGURATION:
  SERVER_IP=10.0.0.30       # Performance test server IP
  SERVER_USER=roaming            # SSH user for server
  SERVER_INTERFACE=ens18         # Server network interface

IPSEC MODES (when IPSEC_ENABLED=true):
  1 = AES-128-GCM          (AEAD, fast, hardware accelerated)
  2 = AES-256-GCM          (AEAD, stronger key)
  3 = AES-128-CBC + SHA256 (Separate encryption + integrity)
  4 = AES-256-CBC + SHA256 (Separate, stronger key)
  5 = NULL + SHA256        (WARNING: NO ENCRYPTION - Integrity only)
  6 = NULL + GMAC          (WARNING: NO ENCRYPTION - Integrity only)

DELAY MODES:
  UPF (open5gs-upf):
    gtpu  - GTP-U traffic (port 2152)
    ipsec - ESP protocol traffic
    pfcp  - PFCP traffic (port 8805)
    n6    - N6 interface (ogstun)
    n3    - N3 interface (local only)
    full  - All traffic

  SEPP (open5gs-sepp):
    n32   - N32 interface (ports 8080/8081)
    eth0  - All container traffic

  SMF (open5gs-smf):
    pfcp  - PFCP traffic to UPF (port 8805)
    eth0  - All container traffic

EXAMPLES:
  $0                              # Interactive mode
  $0 --config my_test.conf        # Automated mode with config file
  $0 --generate-config test.conf  # Generate sample config
  $0 --quick                      # Quick mode
EOF
}

# ============================================================================
# Entry Point
# ============================================================================

for cmd in docker ssh jq bc curl; do
    command -v "$cmd" &>/dev/null || { echo "❌ Missing: $cmd"; exit 1; }
done

case "${1:-}" in
    --config|-c)
        [ -z "${2:-}" ] && { echo "❌ --config requires a file path"; exit 1; }
        run_with_config_file "$2"
        ;;
    --recover-ran)
        [ -z "${2:-}" ] && { echo "❌ --recover-ran requires a config file path"; exit 1; }
        recover_ran_with_config_file "$2"
        ;;
    --generate-config)
        generate_sample_config "${2:-batch_config_sample.conf}"
        ;;
    --quick|-q)
        quick_mode
        ;;
    --help|-h)
        show_help
        ;;
    "")
        main
        ;;
    *)
        echo "❌ Unknown option: $1"; echo "Use --help for usage"; exit 1
        ;;
esac
