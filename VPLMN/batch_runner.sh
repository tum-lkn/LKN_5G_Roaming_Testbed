#!/usr/bin/env bash

set -e

# ============================================================================
# Batch Runner Script for Open5GS Testbed Automation
# Runs multiple configuration files for a specified number of iterations
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/configs"
RUNNER_START_TIME=$(date +%s%N)
RUNNER_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RUNNER_LOG_FILE="$SCRIPT_DIR/logs/batch_runner_${RUNNER_TIMESTAMP}.log"
GTP5G_RELOAD_INTERVAL=10
IPERF_SERVER_RESTART_INTERVAL=0    # 0 = disabled, N = restart every N completed runs
DOWNLOAD_SERVER_RESTART_INTERVAL=0 # 0 = disabled, N = restart every N completed runs

# Performance server SSH configuration (for server restart via SSH)
PERF_SERVER_IP="10.162.149.210"    # Performance test server IP
PERF_SERVER_USER="roaming"         # SSH user for performance server
PERF_SSH_CONNECT_TIMEOUT=10        # SSH connection timeout
PERF_SSH_BATCH_MODE="yes"          # Use batch mode for SSH

# Global variables for tracking results (accessible to trap handler)
declare -a TEST_RESULTS=()
TOTAL_SUCCESSFUL=0
TOTAL_FAILED=0
INTERRUPTED=false

# Create necessary directories
mkdir -p "$SCRIPT_DIR/logs"

# ============================================================================
# Helper Functions
# ============================================================================

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$RUNNER_LOG_FILE"
}

error_exit() {
    log "❌ ERROR: $1"
    exit 1
}

# ============================================================================
# Summary Printing Functions
# ============================================================================

print_summary() {
    # Print summary (can be called on normal exit or when interrupted)
    log ""
    log "═══════════════════════════════════════════════════════════════"
    if [ "$INTERRUPTED" = true ]; then
        log "                 BATCH RUNNER INTERRUPTED"
        log "                  (Partial Results Summary)"
    else
        log "                    BATCH RUNNER SUMMARY"
    fi
    log "═══════════════════════════════════════════════════════════════"
    log ""
    log "📊 Results:"
    log "   Successful: $TOTAL_SUCCESSFUL"
    log "   Failed: $TOTAL_FAILED"
    log "   Total: $((TOTAL_SUCCESSFUL + TOTAL_FAILED))"
    log ""
    
    if [ "${#TEST_RESULTS[@]}" -gt 0 ]; then
        log "📋 Detailed Results:"
        for result in "${TEST_RESULTS[@]}"; do
            log "   $result"
        done
        log ""
    fi
    
    # Calculate total runner time
    local runner_end_time=$(date +%s%N)
    local runner_total_ms=$(( (runner_end_time - RUNNER_START_TIME) / 1000000 ))
    local runner_total_sec=$(echo "scale=2; $runner_total_ms / 1000" | bc)
    local runner_total_min=$(echo "scale=2; $runner_total_ms / 60000" | bc)
    
    log "⏱️  Total Runner Execution Time: ${runner_total_sec}s (${runner_total_min}min)"
    log ""
    log "═══════════════════════════════════════════════════════════════"
    
    if [ "$INTERRUPTED" = true ]; then
        log "⚠️  Batch runner interrupted at $(date +'%Y-%m-%d %H:%M:%S')"
    else
        log "✅ Batch runner completed at $(date +'%Y-%m-%d %H:%M:%S')"
    fi
    
    log "📁 Results directory: $SCRIPT_DIR/results/"
    log "📝 Runner log: $RUNNER_LOG_FILE"
    log "═══════════════════════════════════════════════════════════════"
}

handle_interrupt() {
    log ""
    log "🛑 Received interrupt signal (Ctrl+C)"
    INTERRUPTED=true
    print_summary
    exit 130  # 128 + SIGINT(2) = 130
}

# ============================================================================
# System Management Functions
# ============================================================================

reload_gtp5g_module() {
    log "🔄 Reloading gtp5g kernel module..."
    if lsmod | grep -q "^gtp5g "; then
        sudo rmmod gtp5g 2>/dev/null || { log "⚠️  Failed to unload gtp5g"; return 1; }
        sleep 1
        sudo modprobe gtp5g 2>/dev/null || { log "⚠️  Failed to load gtp5g"; return 1; }
        log "✅ gtp5g module reloaded successfully"
        return 0
    else
        log "ℹ️  gtp5g module not loaded, skipping reload"
        return 0
    fi
}

restart_iperf_server() {
    log "🔄 Restarting iPerf3 server on $PERF_SERVER_USER@$PERF_SERVER_IP..."
    local ssh_cmd="ssh -o ConnectTimeout=$PERF_SSH_CONNECT_TIMEOUT -o BatchMode=$PERF_SSH_BATCH_MODE $PERF_SERVER_USER@$PERF_SERVER_IP"
    # Try systemd service first, then fall back to kill + daemon restart
    local restart_script
    restart_script='if systemctl is-active --quiet iperf3 2>/dev/null; then sudo systemctl restart iperf3; elif systemctl is-active --quiet iperf 2>/dev/null; then sudo systemctl restart iperf; else pkill -x iperf3 2>/dev/null || true; sleep 2; iperf3 -s --daemon; fi'
    if ! $ssh_cmd "$restart_script" 2>&1; then
        log "⚠️  Failed to restart iPerf3 server at $PERF_SERVER_IP"
        return 1
    fi
    sleep 2
    log "✅ iPerf3 server restarted successfully"
    return 0
}

restart_download_server() {
    log "🔄 Restarting download server on $PERF_SERVER_USER@$PERF_SERVER_IP..."
    # Use SSH with heredoc to avoid issues with backgrounding processes
    local output
    output=$(ssh -T -o ConnectTimeout="$PERF_SSH_CONNECT_TIMEOUT" -o BatchMode="$PERF_SSH_BATCH_MODE" "$PERF_SERVER_USER@$PERF_SERVER_IP" 2>&1 << 'RESTART_EOF'
restarted=false
for svc in caddy nginx apache2 httpd http-server; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        sudo systemctl restart "$svc" && restarted=true && break
    fi
done
if [ "$restarted" = false ]; then
    # Kill any existing instance (may already be dead)
    pkill -f "file_download_server.py" 2>/dev/null || true
    sleep 1
    # Relaunch from the known server directory - check multiple possible locations
    for server_dir in ~/download_server ~/performance-server-main; do
        if [ -f "$server_dir/file_download_server.py" ]; then
            break
        fi
    done
    if [ ! -f "$server_dir/file_download_server.py" ]; then
        echo "ERROR: file_download_server.py not found in ~/download_server or ~/performance-server-main"
        exit 1
    fi
    cd "$server_dir" || exit 1
    python3 file_download_server.py --port 9000 --host 0.0.0.0 --downloads-dir downloads >> server.log 2>&1 &
    sleep 2
    # Verify it is actually listening
    if ss -tlnp 2>/dev/null | grep -q ":9000"; then
        echo "SUCCESS"
    else
        echo "ERROR: Download server failed to start (port 9000 not listening)"
        exit 1
    fi
fi
RESTART_EOF
)
    if echo "$output" | grep -q "SUCCESS"; then
        log "✅ Download server restarted successfully"
        return 0
    else
        log "⚠️  Failed to restart download server at $PERF_SERVER_IP"
        [ -n "$output" ] && log "Error: $output"
        return 1
    fi
}

# ============================================================================
# Config Loading Functions
# ============================================================================

get_all_configs() {
    local -a all_configs
    
    if [ ! -d "$CONFIG_DIR" ]; then
        error_exit "Config directory not found: $CONFIG_DIR"
    fi
    
    while IFS= read -r -d '' config_file; do
        all_configs+=("$(basename "$config_file")")
    done < <(find "$CONFIG_DIR" -maxdepth 1 -name "*.conf" -type f -print0 | sort -z)
    
    if [ ${#all_configs[@]} -eq 0 ]; then
        error_exit "No configuration files found in: $CONFIG_DIR"
    fi
    
    printf '%s\n' "${all_configs[@]}"
}

# ============================================================================
# Runner Logic
# ============================================================================

run_all_tests() {
    local -a config_files=("$@")
    local num_configs=${#config_files[@]}
    
    if [ "$num_configs" -eq 0 ]; then
        error_exit "No configuration files provided"
    fi
    
    log "╔════════════════════════════════════════════════════════════╗"
    log "║         Open5GS Batch Runner v2.0                          ║"
    log "║   Running multiple configurations sequentially             ║"
    log "║   Started at: $(date +'%Y-%m-%d %H:%M:%S')                 ║"
    log "╚════════════════════════════════════════════════════════════╝"
    log ""
    
    log "📋 Test Plan:"
    log "   Total configs: $num_configs"
    log "   Runner iterations per config: $RUNNER_ITERATIONS"
    log "   Total test runs: $((num_configs * RUNNER_ITERATIONS))"
    if [ "$IPERF_SERVER_RESTART_INTERVAL" -gt 0 ]; then
        log "   iPerf server restart: every $IPERF_SERVER_RESTART_INTERVAL runs (server: $PERF_SERVER_USER@$PERF_SERVER_IP)"
    fi
    if [ "$DOWNLOAD_SERVER_RESTART_INTERVAL" -gt 0 ]; then
        log "   Download server restart: every $DOWNLOAD_SERVER_RESTART_INTERVAL runs (server: $PERF_SERVER_USER@$PERF_SERVER_IP)"
    fi
    log ""
    
    # # Display all configs to be run
    # log "Configurations to run:"
    # for i in "${!config_files[@]}"; do
    #     log "  $((i+1)). ${config_files[$i]}"
    # done
    # log ""
    
    # Confirm before starting
    read -rp "Proceed with testing? [Y/n]: " confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && { log "Aborted by user"; exit 0; }
    
    log ""
    log "🚀 Starting batch test execution..."
    log ""
    
    # Initial server restarts (if restart intervals are configured)
    if [ "$IPERF_SERVER_RESTART_INTERVAL" -gt 0 ]; then
        log "📋 Initial iPerf server restart before first run..."
        restart_iperf_server || log "⚠️  Continuing despite iPerf server restart failure"
        log ""
    fi
    if [ "$DOWNLOAD_SERVER_RESTART_INTERVAL" -gt 0 ]; then
        log "📋 Initial download server restart before first run..."
        restart_download_server || log "⚠️  Continuing despite download server restart failure"
        log ""
    fi

    # Reset global counters
    TOTAL_SUCCESSFUL=0
    TOTAL_FAILED=0
    TEST_RESULTS=()
    
    local completed_runs=0
    local total_run_time_ms=0
    local total_runs=$((num_configs * RUNNER_ITERATIONS))
    for iter in $(seq 1 "$RUNNER_ITERATIONS"); do 
        for config_idx in "${!config_files[@]}"; do
            local config_file="${config_files[$config_idx]}"
            local config_num=$((config_idx + 1))
            # Resolve full path to config file
            local full_config_path="$config_file"
            if [[ ! "$config_file" =~ ^/ ]]; then
                full_config_path="$CONFIG_DIR/$config_file"
            fi
            if [ ! -f "$full_config_path" ]; then
                log "⚠️  Config file not found: $full_config_path (skipping)"
                continue
            fi
            # Extract ITERATIONS from config file (default to RUNNER_ITERATIONS if not set)
            local config_iterations=$(grep -E '^ITERATIONS=' "$full_config_path" | head -1 | cut -d= -f2 | tr -d ' ')
            if [[ -z "$config_iterations" ]]; then
                config_iterations="$RUNNER_ITERATIONS"
            fi
            local config_basename=$(basename "$config_file" .conf)
            # (No config summary printout here; handled by testbed_automation.sh)
            # ------------------------------------------------------------------------------
            local run_num=$((completed_runs + 1))
            log ""
            log "════════════════════════════════════════════════════════════"
            log " Config $config_num/$num_configs: $config_basename (Iteration $iter/$RUNNER_ITERATIONS)"
            log "════════════════════════════════════════════════════════════"
            local config_start_time=$(date +%s%N)
            if "$SCRIPT_DIR/testbed_automation.sh" --config "$full_config_path"; then
                local config_end_time=$(date +%s%N)
                local config_duration_ms=$(( (config_end_time - config_start_time) / 1000000 ))
                local config_duration_sec=$(echo "scale=2; $config_duration_ms / 1000" | bc)
                log "✅ Configuration $config_num Iteration $iter completed in ${config_duration_sec}s"
                TEST_RESULTS+=("✅ $config_basename [Iteration $iter/$RUNNER_ITERATIONS]: SUCCESS (${config_duration_sec}s)")
                TOTAL_SUCCESSFUL=$((TOTAL_SUCCESSFUL + 1))
            else
                local config_end_time=$(date +%s%N)
                local config_duration_ms=$(( (config_end_time - config_start_time) / 1000000 ))
                local config_duration_sec=$(echo "scale=2; $config_duration_ms / 1000" | bc)
                log "❌ Configuration $config_num Iteration $iter FAILED after ${config_duration_sec}s"
                TEST_RESULTS+=("❌ $config_basename [Iteration $iter/$RUNNER_ITERATIONS]: FAILED (${config_duration_sec}s)")
                TOTAL_FAILED=$((TOTAL_FAILED + 1))
            fi
            completed_runs=$((completed_runs + 1))
            total_run_time_ms=$((total_run_time_ms + config_duration_ms))
            # Reload gtp5g module every x iterations if configured
            if [ "$GTP5G_RELOAD_INTERVAL" -gt 0 ] && [ $((completed_runs % GTP5G_RELOAD_INTERVAL)) -eq 0 ] && [ "$completed_runs" -lt "$total_runs" ]; then
                log ""
                log "📋 gtp5g reload interval reached (every $GTP5G_RELOAD_INTERVAL iterations)"
                reload_gtp5g_module
                log ""
            fi
            # Restart iPerf server at configured interval
            if [ "$IPERF_SERVER_RESTART_INTERVAL" -gt 0 ] && [ $((completed_runs % IPERF_SERVER_RESTART_INTERVAL)) -eq 0 ] && [ "$completed_runs" -lt "$total_runs" ]; then
                log ""
                log "📋 iPerf server restart interval reached (every $IPERF_SERVER_RESTART_INTERVAL runs)"
                restart_iperf_server || log "⚠️  Continuing despite iPerf server restart failure"
                log ""
            fi
            # Restart download server at configured interval
            if [ "$DOWNLOAD_SERVER_RESTART_INTERVAL" -gt 0 ] && [ $((completed_runs % DOWNLOAD_SERVER_RESTART_INTERVAL)) -eq 0 ] && [ "$completed_runs" -lt "$total_runs" ]; then
                log ""
                log "📋 Download server restart interval reached (every $DOWNLOAD_SERVER_RESTART_INTERVAL runs)"
                restart_download_server || log "⚠️  Continuing despite download server restart failure"
                log ""
            fi
            # Output progress status
            local avg_run_time_ms=0
            if [ "$completed_runs" -gt 0 ]; then
                avg_run_time_ms=$((total_run_time_ms / completed_runs))
            fi
            local avg_run_time_sec=$(echo "scale=2; $avg_run_time_ms / 1000" | bc)
            local remaining_runs=$((total_runs - completed_runs))
            local est_remaining_ms=$((remaining_runs * avg_run_time_ms))
            local est_remaining_min=$(echo "scale=2; $est_remaining_ms / 60000" | bc)
            local est_remaining_sec=$(echo "scale=2; $est_remaining_ms / 1000" | bc)
            log "--- Progress: $completed_runs/$total_runs completed ---"
            log "    Successful: $TOTAL_SUCCESSFUL | Failed: $TOTAL_FAILED"
            log "    Average run time: ${avg_run_time_sec}s"
            log "    Estimated time remaining: ${est_remaining_min}min (${est_remaining_sec}s)"
            # Add delay between configs/iterations
            if [ "$config_idx" -lt "$((num_configs - 1))" ] || [ "$iter" -lt "$RUNNER_ITERATIONS" ]; then
                log "⏳ Waiting before next test..."
                sleep 5
            fi
        done
    done
    
    # Print summary
    print_summary
    
    return 0
}

# ============================================================================
# Main
# ============================================================================

main() {
    # Set up trap handler for Ctrl+C
    trap handle_interrupt SIGINT
    
    # Parse arguments
    local -a configs
    local run_all=false
    RUNNER_ITERATIONS=1
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -i|--iterations)
                RUNNER_ITERATIONS="$2"
                shift 2
                ;;
            -r|--reload-interval)
                GTP5G_RELOAD_INTERVAL="$2"
                shift 2
                ;;
            -ris|--restart-iperf-server)
                IPERF_SERVER_RESTART_INTERVAL="$2"
                shift 2
                ;;
            -rds|--restart-download-server)
                DOWNLOAD_SERVER_RESTART_INTERVAL="$2"
                shift 2
                ;;
            -a|--all)
                run_all=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -*)
                error_exit "Unknown option: $1"
                ;;
            *)
                configs+=("$1")
                shift
                ;;
        esac
    done
    
    # Validate iterations
    if [[ ! "$RUNNER_ITERATIONS" =~ ^[0-9]+$ ]] || [ "$RUNNER_ITERATIONS" -lt 1 ]; then
        error_exit "Invalid runner iterations count: $RUNNER_ITERATIONS (must be positive integer)"
    fi
    
    # Validate server restart intervals
    if [[ ! "$IPERF_SERVER_RESTART_INTERVAL" =~ ^[0-9]+$ ]]; then
        error_exit "Invalid iPerf server restart interval: $IPERF_SERVER_RESTART_INTERVAL (must be non-negative integer, 0 to disable)"
    fi
    if [[ ! "$DOWNLOAD_SERVER_RESTART_INTERVAL" =~ ^[0-9]+$ ]]; then
        error_exit "Invalid download server restart interval: $DOWNLOAD_SERVER_RESTART_INTERVAL (must be non-negative integer, 0 to disable)"
    fi
    
    # Check if we're in the right directory
    if [[ ! "$(pwd)" =~ VPLMN ]]; then
        log "⚠️  Warning: Not in VPLMN directory"
        read -rp "Continue anyway? [y/N]: " c
        [[ ! "$c" =~ ^[Yy]$ ]] && exit 0
    fi
    
    # Check if testbed_automation.sh exists
    if [ ! -f "$SCRIPT_DIR/testbed_automation.sh" ]; then
        error_exit "testbed_automation.sh not found in $SCRIPT_DIR"
    fi
    
    # If --all flag is set, generate configs on the fly from main.conf
    if [ "$run_all" = true ]; then
        MAIN_CONF="$CONFIG_DIR/main.conf"
        if [ ! -f "$MAIN_CONF" ]; then
            error_exit "main.conf not found in $CONFIG_DIR"
        fi
        # shellcheck source=/dev/null
        source "$MAIN_CONF"
        
        # Ensure N6_SERVER_INTERFACE is set (default to ens18 if not in main.conf)
        if [[ -z "${N6_SERVER_INTERFACE:-}" ]]; then
            N6_SERVER_INTERFACE="ens18"
            log "ℹ️  N6_SERVER_INTERFACE not set in main.conf, using default: $N6_SERVER_INTERFACE"
        else
            log "✓ Using N6_SERVER_INTERFACE from main.conf: $N6_SERVER_INTERFACE"
        fi
        
        # Override performance server IP/user from main.conf if defined there
        [[ -n "${IPERF_SERVER_IP:-}" ]] && PERF_SERVER_IP="$IPERF_SERVER_IP"
        [[ -n "${SERVER_IP:-}" ]] && PERF_SERVER_IP="$SERVER_IP"
        [[ -n "${SERVER_USER:-}" ]] && PERF_SERVER_USER="$SERVER_USER"
        
        # Create mapping of LATENCIES indices to vPLMN names for naming conventions (NEW)
        declare -A VPLMN_INDEX_MAP
        for idx in "${!LATENCIES[@]}"; do
            # Map index to vPLMN name (index 0 is first vPLMN, etc.)
            VPLMN_INDEX_MAP[$idx]="${vPLMNs[$idx]:-vplmn$idx}"
        done
        
        # Build all combinations using MODE_NAMES and MODES
        declare -a dynamic_configs
        num_modes=${#MODE_NAMES[@]}
        # Create generated configs subfolder
        GENERATED_CONFIG_DIR="$CONFIG_DIR/generated"
        mkdir -p "$GENERATED_CONFIG_DIR"
        # Check if DN_LATENCIES is set and non-empty
        dn_latencies_defined=false
        if declare -p DN_LATENCIES &>/dev/null && [ "${#DN_LATENCIES[@]}" -gt 0 ]; then
            dn_latencies_defined=true
        fi
        for ((mode_idx=0; mode_idx<num_modes; mode_idx++)); do
            mode_name="${MODE_NAMES[$mode_idx]}"
            # Map mode names to valid roaming modes for testbed_automation.sh
            case "$mode_name" in
                non-roaming) actual_roaming_mode="non_roaming" ;;
                lbo) actual_roaming_mode="lbo" ;;
                hr) actual_roaming_mode="hr" ;;
                hr-ipsec) actual_roaming_mode="hr" ;;
                hr-remote-upf) actual_roaming_mode="hr" ;;  # HR mode with remote UPF selection
                *) actual_roaming_mode="$mode_name" ;;
            esac
            # Use ITERATIONS from main.conf if set, else fallback to RUNNER_ITERATIONS
            config_iterations="$ITERATIONS"
            if [[ -z "$config_iterations" ]]; then # does this make sense?
                config_iterations="$RUNNER_ITERATIONS"
            fi
            if [ "$mode_name" = "non-roaming" ]; then
                # Generate configs for non-roaming with DN server locations and both payload sizes
                for dn_loc_idx in "${!DN_LOCATIONS[@]}"; do
                    dn_location="${DN_LOCATIONS[$dn_loc_idx]}"
                    # Get DN latency and jitter arrays for this location
                    dn_lat_array_name="DN_LATENCIES_${dn_loc_idx}[@]"
                    dn_jit_array_name="DN_JITTERS_${dn_loc_idx}[@]"
                    dn_latencies_for_loc=("${!dn_lat_array_name}")
                    dn_jitters_for_loc=("${!dn_jit_array_name}")
                    
                    # Use the first latency from the DN latencies array
                    dn_latency="${dn_latencies_for_loc[0]}"
                    dn_jitter="${dn_jitters_for_loc[0]}"
                    [[ -z "$dn_jitter" ]] && dn_jitter=0
                    
                    # Now test with both payload sizes
                    for payload in "${PING_PAYLOADS[@]}"; do
                        printf "%-20s %-12s %10s\n" "$mode_name" "$dn_location" "$payload"
                        
                        conf_file="non_roaming_dn_${dn_location,,}_pld${payload}.conf"
                        {
                            echo "# Auto-generated config for $mode_name with DN server: $dn_location"
                            echo "ROAMING_MODE=non_roaming"
                            echo "IPSEC_ENABLED=false"
                            # Store metadata for JSON output (NEW)
                            echo "DN_LOCATION=$dn_location"
                            echo "DN_LATENCY=$dn_latency"
                            echo "DN_JITTER=$dn_jitter"
                            
                            echo "VPLMN_SECURITY=$VPLMN_SECURITY"
                            echo "HPLMN_SECURITY=$HPLMN_SECURITY"
                            echo "ITERATIONS=$config_iterations"
                            echo "PING_COUNT=$PING_COUNT"
                            echo "PING_TARGET=$PING_TARGET"
                            echo "ITERATION_DELAY=$ITERATION_DELAY"
                            echo "TESTBED_RESTART_INTERVAL=$TESTBED_RESTART_INTERVAL"
                            echo "PING_INTERVAL=$PING_INTERVAL"
                            echo "NETWORK_READY_TIMEOUT=$NETWORK_READY_TIMEOUT"
                            echo "SERVICE_CHECK_INTERVAL=$SERVICE_CHECK_INTERVAL"
                            echo "IPSEC_ESTABLISH_TIMEOUT=$IPSEC_ESTABLISH_TIMEOUT"
                            echo "MIN_NETWORK_STABILIZE_TIME=$MIN_NETWORK_STABILIZE_TIME"
                            echo "DELAY_ENABLED=false"
                            echo "PING_PAYLOAD_SIZE=$payload"
                            # N6 delay configuration for DN server location (symmetrical)
                            echo "N6_DELAY_ENABLED=true"
                            echo "N6_DELAY_VALUE=${dn_latency}ms"
                            echo "N6_DELAY_JITTER=${dn_jitter}ms"
                            [[ -n "${N6_SERVER_INTERFACE:-}" ]] && echo "N6_SERVER_INTERFACE=$N6_SERVER_INTERFACE"
                            # Test configuration parameters
                            [[ -n "${PING_TEST_ENABLED:-}" ]] && echo "PING_TEST_ENABLED=$PING_TEST_ENABLED"
                            [[ -n "${DOWNLOAD_TEST_ENABLED:-}" ]] && echo "DOWNLOAD_TEST_ENABLED=$DOWNLOAD_TEST_ENABLED"
                            [[ -n "${DOWNLOAD_TEST_URL:-}" ]] && echo "DOWNLOAD_TEST_URL=$DOWNLOAD_TEST_URL"
                            [[ -n "${DOWNLOAD_TEST_SIZE_LABEL:-}" ]] && echo "DOWNLOAD_TEST_SIZE_LABEL=$DOWNLOAD_TEST_SIZE_LABEL"
                            [[ -n "${VIDEO_TEST_ENABLED:-}" ]] && echo "VIDEO_TEST_ENABLED=$VIDEO_TEST_ENABLED"
                            [[ -n "${VIDEO_TEST_URL:-}" ]] && echo "VIDEO_TEST_URL=$VIDEO_TEST_URL"
                            [[ -n "${VIDEO_TEST_SIZE_LABEL:-}" ]] && echo "VIDEO_TEST_SIZE_LABEL=$VIDEO_TEST_SIZE_LABEL"
                            [[ -n "${IPERF_TEST_ENABLED:-}" ]] && echo "IPERF_TEST_ENABLED=$IPERF_TEST_ENABLED"
                            [[ -n "${IPERF_SERVER_IP:-}" ]] && echo "IPERF_SERVER_IP=$IPERF_SERVER_IP"
                            [[ -n "${IPERF_SERVER_PORT:-}" ]] && echo "IPERF_SERVER_PORT=$IPERF_SERVER_PORT"
                            [[ -n "${IPERF_DURATION:-}" ]] && echo "IPERF_DURATION=$IPERF_DURATION"
                            [[ -n "${IPERF_PARALLEL:-}" ]] && echo "IPERF_PARALLEL=$IPERF_PARALLEL"
                            [[ -n "${IPERF_REVERSE:-}" ]] && echo "IPERF_REVERSE=$IPERF_REVERSE"
                            [[ -n "${IPERF_UDP:-}" ]] && echo "IPERF_UDP=$IPERF_UDP"
                            [[ -n "${IPERF_BANDWIDTH:-}" ]] && echo "IPERF_BANDWIDTH=$IPERF_BANDWIDTH"
                            [[ -n "${WEBPAGE_TEST_ENABLED:-}" ]] && echo "WEBPAGE_TEST_ENABLED=$WEBPAGE_TEST_ENABLED"
                            [[ -n "${WEBPAGE_BROWSER:-}" ]] && echo "WEBPAGE_BROWSER=$WEBPAGE_BROWSER"
                            [[ -n "${WEBPAGE_ITERATIONS:-}" ]] && echo "WEBPAGE_ITERATIONS=$WEBPAGE_ITERATIONS"
                            [[ -n "${WEBPAGE_TIMEOUT:-}" ]] && echo "WEBPAGE_TIMEOUT=$WEBPAGE_TIMEOUT"
                            for wvar in ${!WEBPAGE_URL_@}; do echo "$wvar=${!wvar}"; done
                        } > "$GENERATED_CONFIG_DIR/$conf_file"
                        dynamic_configs+=("generated/$conf_file")
                    done
                done
            else
                for latency_idx in "${!LATENCIES[@]}"; do
                    latency="${LATENCIES[$latency_idx]}"
                    # Get corresponding jitter from parallel array
                    jitter="${JITTERS[$latency_idx]}"
                    if [[ -z "$jitter" ]]; then
                        jitter=0
                    fi
                    
                    # Determine DN location index based on roaming mode:
                    if [ "$mode_name" = "hr" ] || [ "$mode_name" = "hr-ipsec" ]; then
                        # HR modes: only use Frankfurt (index 0) - home network is always Germany
                        dn_locs_to_process=(0)
                    else
                        # LBO and HR-Remote-UPF: map each vPLMN to its corresponding DN origin location
                        # France (0) → Paris (1), USA (1) → Boston (2), Australia (2) → Sydney (3)
                        case "$latency_idx" in
                            0) dn_locs_to_process=(1) ;;  # France → Paris
                            1) dn_locs_to_process=(2) ;;  # USA → Boston
                            2) dn_locs_to_process=(3) ;;  # Australia → Sydney
                            *) dn_locs_to_process=() ;;   # Unknown vPLMN, skip
                        esac
                    fi
                    
                    # Loop through each DN server location determined above
                    for dn_loc_idx in "${dn_locs_to_process[@]}"; do
                        
                        dn_location="${DN_LOCATIONS[$dn_loc_idx]}"
                        # Get DN latency and jitter arrays for this location
                        dn_lat_array_name="DN_LATENCIES_${dn_loc_idx}[@]"
                        dn_jit_array_name="DN_JITTERS_${dn_loc_idx}[@]"
                        dn_latencies_for_loc=("${!dn_lat_array_name}")
                        dn_jitters_for_loc=("${!dn_jit_array_name}")
                        
                        for payload in "${PING_PAYLOADS[@]}"; do
                            # Iterate through all DN target locations for this source location
                            for dn_target_idx in "${!dn_latencies_for_loc[@]}"; do
                                dn_latency="${dn_latencies_for_loc[$dn_target_idx]}"
                                dn_jitter="${dn_jitters_for_loc[$dn_target_idx]}"
                                [[ -z "$dn_jitter" ]] && dn_jitter=0
                                
                                # Determine target DN location name
                                dn_target_location="${DN_LOCATIONS[$dn_target_idx]}"
                                
                                # Compose config name using vPLMN name and DN destination only
                                case $mode_name in
                                    hr) conf_base="hr" ;;
                                    lbo) conf_base="lbo" ;;
                                    hr-ipsec) conf_base="hr-ipsec" ;;
                                    hr-remote-upf) conf_base="hr-remote-upf" ;;
                                    *) conf_base="custom" ;;
                                esac
                                
                                # Get vPLMN name from mapping (if non-roaming, use vPLMN name, otherwise use latency index)
                                if [ "$mode_name" = "non-roaming" ]; then
                                    # For non-roaming, no vPLMN involved, but we still use DN location info
                                    conf_file="${conf_base}_dn_${dn_target_location,,}_pld${payload}.conf"
                                else
                                    # For roaming modes, use vPLMN name from the latency index
                                    vplmn_name="${VPLMN_INDEX_MAP[$latency_idx]:-vplmn$latency_idx}"
                                    # Use vPLMN name and DN destination (target) location only
                                    conf_file="${conf_base}_${vplmn_name,,}_dn_${dn_target_location,,}_pld${payload}.conf"
                                fi
                                
                                # Print run info
                                printf "%-15s %6sms %6sms %-12s → %-12s %10s\n" "$mode_name" "$latency" "$jitter" "$dn_location" "$dn_target_location" "$payload"
                                
                                # Write config file
                                {
                                    echo "# Auto-generated config for $mode_name"
                                    echo "# IXP latency: ${latency}ms (jitter: ${jitter}ms) | DN: $dn_location → $dn_target_location (${dn_latency}ms, jitter: ${dn_jitter}ms)"
                                    echo "ROAMING_MODE=$actual_roaming_mode"
                                    
                                    # Store metadata for JSON output (NEW)
                                    if [ "$mode_name" != "non-roaming" ]; then
                                        vplmn_name="${VPLMN_INDEX_MAP[$latency_idx]:-vplmn$latency_idx}"
                                        echo "VPLMN_NAME=$vplmn_name"
                                    fi
                                    echo "DN_LOCATION=$dn_target_location"
                                    echo "DN_LATENCY=$dn_latency"
                                    echo "DN_JITTER=$dn_jitter"
                                    
                                    echo "IPSEC_ENABLED=$( [[ "$mode_name" == "hr-ipsec" ]] && echo true || echo false )"
                                    echo "VPLMN_SECURITY=$VPLMN_SECURITY"
                                    echo "HPLMN_SECURITY=$HPLMN_SECURITY"
                                    echo "ITERATIONS=$config_iterations"
                                    echo "PING_COUNT=$PING_COUNT"
                                    echo "PING_TARGET=$PING_TARGET"
                                    echo "ITERATION_DELAY=$ITERATION_DELAY"
                                    echo "TESTBED_RESTART_INTERVAL=$TESTBED_RESTART_INTERVAL"
                                    echo "PING_INTERVAL=$PING_INTERVAL"
                                    echo "NETWORK_READY_TIMEOUT=$NETWORK_READY_TIMEOUT"
                                    echo "SERVICE_CHECK_INTERVAL=$SERVICE_CHECK_INTERVAL"
                                    echo "IPSEC_ESTABLISH_TIMEOUT=$IPSEC_ESTABLISH_TIMEOUT"
                                    echo "MIN_NETWORK_STABILIZE_TIME=$MIN_NETWORK_STABILIZE_TIME"
                                    echo "DELAY_ENABLED=true"
                                    
                                    # Signaling delays (IXP latency)
                                    if [ "$mode_name" = "hr-ipsec" ]; then
                                        echo "DELAY_RULE_1=local:open5gs-upf:ipsec=${latency}ms:${jitter}ms"
                                        echo "DELAY_RULE_2=remote:open5gs-upf:ipsec=${latency}ms:${jitter}ms"
                                    elif [ "$mode_name" = "hr-remote-upf" ]; then
                                        echo "DELAY_RULE_1=remote:open5gs-upf:pfcp=${latency}ms:${jitter}ms"
                                        echo "DELAY_RULE_2=remote:open5gs-smf:pfcp=${latency}ms:${jitter}ms"
                                    else
                                        echo "DELAY_RULE_1=local:open5gs-upf:gtpu=${latency}ms:${jitter}ms"
                                        echo "DELAY_RULE_2=remote:open5gs-upf:gtpu=${latency}ms:${jitter}ms"
                                    fi
                                    echo "DELAY_RULE_3=local:open5gs-sepp:n32=${latency}ms:${jitter}ms"
                                    echo "DELAY_RULE_4=remote:open5gs-sepp:n32=${latency}ms:${jitter}ms"
                                    
                                    # N6/DN delays (Data Network latency)
                                    echo "N6_DELAY_ENABLED=true"
                                    echo "N6_DELAY_VALUE=${dn_latency}ms"
                                    echo "N6_DELAY_JITTER=${dn_jitter}ms"
                                    # Apply N6 delay based on roaming mode:
                                    # - LBO/non-roaming: delay on local UPF (VPLMN)
                                    # - HR modes: delay on remote UPF (HPLMN)
                                    
                                    # Server-side delay for bidirectional symmetry
                                    [[ -n "${N6_SERVER_INTERFACE:-}" ]] && echo "N6_SERVER_INTERFACE=$N6_SERVER_INTERFACE"
                                    
                                    echo "PING_PAYLOAD_SIZE=$payload"
                                    
                                    # Test configuration parameters
                                    [[ -n "${PING_TEST_ENABLED:-}" ]] && echo "PING_TEST_ENABLED=$PING_TEST_ENABLED"
                                    [[ -n "${DOWNLOAD_TEST_ENABLED:-}" ]] && echo "DOWNLOAD_TEST_ENABLED=$DOWNLOAD_TEST_ENABLED"
                                    [[ -n "${DOWNLOAD_TEST_URL:-}" ]] && echo "DOWNLOAD_TEST_URL=$DOWNLOAD_TEST_URL"
                                    [[ -n "${DOWNLOAD_TEST_SIZE_LABEL:-}" ]] && echo "DOWNLOAD_TEST_SIZE_LABEL=$DOWNLOAD_TEST_SIZE_LABEL"
                                    [[ -n "${VIDEO_TEST_ENABLED:-}" ]] && echo "VIDEO_TEST_ENABLED=$VIDEO_TEST_ENABLED"
                                    [[ -n "${VIDEO_TEST_URL:-}" ]] && echo "VIDEO_TEST_URL=$VIDEO_TEST_URL"
                                    [[ -n "${VIDEO_TEST_SIZE_LABEL:-}" ]] && echo "VIDEO_TEST_SIZE_LABEL=$VIDEO_TEST_SIZE_LABEL"
                                    [[ -n "${IPERF_TEST_ENABLED:-}" ]] && echo "IPERF_TEST_ENABLED=$IPERF_TEST_ENABLED"
                                    [[ -n "${IPERF_SERVER_IP:-}" ]] && echo "IPERF_SERVER_IP=$IPERF_SERVER_IP"
                                    [[ -n "${IPERF_SERVER_PORT:-}" ]] && echo "IPERF_SERVER_PORT=$IPERF_SERVER_PORT"
                                    [[ -n "${IPERF_DURATION:-}" ]] && echo "IPERF_DURATION=$IPERF_DURATION"
                                    [[ -n "${IPERF_PARALLEL:-}" ]] && echo "IPERF_PARALLEL=$IPERF_PARALLEL"
                                    [[ -n "${IPERF_REVERSE:-}" ]] && echo "IPERF_REVERSE=$IPERF_REVERSE"
                                    [[ -n "${IPERF_UDP:-}" ]] && echo "IPERF_UDP=$IPERF_UDP"
                                    [[ -n "${IPERF_BANDWIDTH:-}" ]] && echo "IPERF_BANDWIDTH=$IPERF_BANDWIDTH"
                                    [[ -n "${WEBPAGE_TEST_ENABLED:-}" ]] && echo "WEBPAGE_TEST_ENABLED=$WEBPAGE_TEST_ENABLED"
                                    [[ -n "${WEBPAGE_BROWSER:-}" ]] && echo "WEBPAGE_BROWSER=$WEBPAGE_BROWSER"
                                    [[ -n "${WEBPAGE_ITERATIONS:-}" ]] && echo "WEBPAGE_ITERATIONS=$WEBPAGE_ITERATIONS"
                                    [[ -n "${WEBPAGE_TIMEOUT:-}" ]] && echo "WEBPAGE_TIMEOUT=$WEBPAGE_TIMEOUT"
                                    for wvar in ${!WEBPAGE_URL_@}; do echo "$wvar=${!wvar}"; done
                                } > "$GENERATED_CONFIG_DIR/$conf_file"
                                dynamic_configs+=("generated/$conf_file")
                            done
                        done
                    done
                done
            fi
        done
        log "📂 Dynamically generated ${#dynamic_configs[@]} config runs from main.conf"
        configs=("${dynamic_configs[@]}")
    fi

    # If no configs provided, show help and exit
    if [ ${#configs[@]} -eq 0 ]; then
        show_help
        exit 1
    fi

    # Run all tests
    run_all_tests "${configs[@]}"
}

# ============================================================================
# Help
# ============================================================================

show_help() {
    cat << 'EOF'
Batch Runner Script for Open5GS Testbed Automation

Usage: ./batch_runner.sh [OPTIONS] [<config_file> ...]

Options:
  -a, --all                          Run all configuration files from configs/ directory
  -i, --iterations NUM               Number of times to run each config (default: 1)
  -r, --reload-interval NUM          Reload gtp5g every NUM iterations (default: 10, use 0 to disable)
  -ris, --restart-iperf-server NUM   Restart iPerf3 server via SSH every NUM runs (0 to disable)
  -rds, --restart-download-server NUM Restart download server via SSH every NUM runs (0 to disable)
  -h, --help                         Show this help message

Examples:
  # Run single config once
  ./batch_runner.sh hr.conf

  # Run multiple configs once each
  ./batch_runner.sh hr.conf lbo.conf non_roaming.conf

  # Run all configs in configs/ directory once
  ./batch_runner.sh --all

  # Run each config 3 times with gtp5g reload every 5 iterations
  ./batch_runner.sh -i 3 -r 5 hr.conf lbo.conf

  # Run all configs 5 times each, reload every 10 iterations
  ./batch_runner.sh --all --iterations 5 --reload-interval 10

  # Run 5 iterations with gtp5g reload disabled
  ./batch_runner.sh -i 5 -r 0 hr.conf

  # Restart iPerf server every 20 runs
  ./batch_runner.sh --all -ris 20

  # Restart both servers every 15 runs
  ./batch_runner.sh --all -i 3 -ris 15 -rds 15

Features:
  - Runs multiple configuration files sequentially
  - Customizable iterations per configuration
  - Automatic discovery of configs from configs/ directory (--all option)
  - Automatic gtp5g kernel module reload at configurable intervals
  - Periodic iPerf3 and download server restarts via SSH at configurable intervals
  - Initial server restart at batch start when restart interval is set
  - Detailed logging and timing information
  - Summary statistics for all test runs
  - Results saved in results/ directory with config-based naming
  - Total execution time tracking

Server Restart:
  The -ris and -rds flags trigger a server restart via SSH at the configured
  interval AND once at the start of the batch run. The performance server IP
  and SSH user default to the same values used by testbed_automation.sh
  (10.162.149.210, user: roaming) and can be overridden in main.conf via
  IPERF_SERVER_IP / SERVER_IP / SERVER_USER.

Config Directory:
  configs/

Log File:
  logs/batch_runner_TIMESTAMP.log

Results:
  results/batch_results_TIMESTAMP.json

EOF
}

# Check dependencies
for cmd in bc; do
    command -v "$cmd" &>/dev/null || { echo "❌ Missing: $cmd"; exit 1; }
done

# Run main
main "$@"
