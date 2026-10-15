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
PERF_SERVER_IP="10.0.0.30"    # Performance test server IP
PERF_SERVER_USER="roaming"         # SSH user for performance server
PERF_SSH_CONNECT_TIMEOUT=10        # SSH connection timeout
PERF_SSH_BATCH_MODE="yes"          # Use batch mode for SSH

# Global variables for tracking results (accessible to trap handler)
declare -a TEST_RESULTS=()
TOTAL_SUCCESSFUL=0
TOTAL_FAILED=0
INTERRUPTED=false

# ── Stop and resume ──────────────────────────────────────────────────────────
# Every config that finishes is recorded in the state file, so a batch that was
# interrupted (Ctrl+C, a crash, or a SIM that has to be swapped by hand) can be
# continued with --resume instead of started over. An interrupted config is
# repeated from its first iteration, so a result file is never half a config.
STATE_FILE="$SCRIPT_DIR/logs/batch_runner.state"
RESUME=false
# The command of the last batch started (its arguments, NUL-separated), so a
# bare --resume can continue it without the user repeating configs and options.
LAST_BATCH_FILE="$SCRIPT_DIR/logs/batch_runner.last"
# Exit status of testbed_automation.sh when the dongle's SIM does not fit the
# config's roaming mode (UE_TYPE=dsk; see lib/automation/dsk.sh).
EXIT_WRONG_SIM=42
declare -A NEED_SIM=()          # SIM classes (hr / lbo / non-roaming) that are not in the dongle
declare -a PENDING_SIM_RUNS=()  # runs skipped because of that
# Stop the batch after this many failed DSK runs in a row (0 = never): when the
# dongle stops attaching, every further run only burns ~6 min on the RAN wait.
DSK_MAX_CONSECUTIVE_FAILURES=3
DSK_CONSECUTIVE_FAILURES=0
# ── RAN recovery (UE_TYPE=dsk) ───────────────────────────────────────────────
# The O-RU's timing drifts after some hours: first the uplink degrades, then
# the dongle cannot attach at all (2026-10-08 and -09). testbed_automation.sh
# stops a run as soon as an iteration shows it and exits EXIT_RAN_DEGRADED.
# The batch then discards that run and the DSK_ROLLBACK_RUNS runs before it
# (the drift shows in the data before it trips the check), recovers the RAN
# (testbed_automation.sh --recover-ran: RU reboot, wait, gNB restart, dongle
# reboot) and measures them again. As a safety net the RU is also rebooted
# that way at the start of the batch and after every DSK_RU_REBOOT_EVERY DSK
# runs, well before the drift was ever seen (≥ 4.5 h after an RU boot).
EXIT_RAN_DEGRADED=43
DSK_ROLLBACK_RUNS=3            # runs before the degraded one that are discarded too
DSK_MAX_RECOVERIES=5           # recoveries after a degraded run, per batch; then stop
DSK_RU_REBOOT_EVERY=10         # scheduled RU reboot after this many DSK runs (0 = never)
DSK_RU_REBOOT_AT_START=true    # reboot the RU before the first DSK run
DSK_DEGRADED_RECOVERIES=0
DSK_RUNS_SINCE_RU_REBOOT=0     # DSK runs completed since the RU was last rebooted by the batch
DSK_ROLLBACK_LIMIT=$DSK_ROLLBACK_RUNS   # never discard runs from before the last RU reboot
DSK_RECOVERED_FROM_DEGRADED=false
DSK_DISCARDED=0
RUN_RESULT_NOTE="$SCRIPT_DIR/logs/.batch_run_result"   # testbed_automation.sh writes its result file's path here

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
# RAN recovery (UE_TYPE=dsk)
# ============================================================================

is_dsk_config() { grep -qiE '^UE_TYPE=dsk' "$1" 2>/dev/null; }

# Reboot the RU, wait, restart the gNB, reboot the dongle. Returns non-zero if
# the RAN did not come back — the caller stops the batch then.
dsk_recover_ran() {   # dsk_recover_ran <config path> <why>
    log ""
    log "🔧 RAN recovery ($2) — RU reboot, wait, gNB restart, dongle reboot..."
    if "$SCRIPT_DIR/testbed_automation.sh" --recover-ran "$1"; then
        log "✅ RAN recovered"
        DSK_RUNS_SINCE_RU_REBOOT=0
        DSK_ROLLBACK_LIMIT=0
        DSK_CONSECUTIVE_FAILURES=0
        return 0
    fi
    log "🛑 RAN recovery failed — see the testbed_automation output above"
    return 1
}

# Move a result file into results_dsk/discarded_<date>/ (nothing is deleted).
dsk_discard_file() {   # dsk_discard_file <result file>
    local f="$1" dir
    [ -n "$f" ] || return 0
    dir="$(dirname "$f")/discarded_$(date +%Y%m%d)"
    mkdir -p "$dir"
    local g moved=false
    for g in "$f" "$f.failed"; do
        [ -e "$g" ] && { mv -f "$g" "$dir/"; log "   🗑️  $(basename "$g") → $(basename "$dir")/"; moved=true; }
    done
    [ "$moved" = true ] || log "   ⚠️  Result file not found: $f"
}

# Discard the degraded run and up to DSK_ROLLBACK_LIMIT DSK runs before it: set
# their result files aside and drop them from the state file, so the batch
# measures them again.
dsk_rollback() {   # dsk_rollback <degraded run's result file>
    log "🗑️  Discarding the degraded run and up to $DSK_ROLLBACK_LIMIT DSK run(s) before it"
    dsk_discard_file "$1"
    local -a done_lines=() keep=()
    local line key cfg f n=0
    mapfile -t done_lines < <(grep '^DONE ' "$STATE_FILE" 2>/dev/null || true)
    local i
    for (( i=${#done_lines[@]}-1; i>=0 && n<DSK_ROLLBACK_LIMIT; i-- )); do
        key="${done_lines[$i]#DONE }"
        cfg="${key#*|}"; [[ "$cfg" =~ ^/ ]] || cfg="$CONFIG_DIR/$cfg"
        is_dsk_config "$cfg" || continue
        f=$(awk -F'\t' -v k="RESULT $key" '$1==k {p=$2} END {print p}' "$STATE_FILE")
        log "   ↩️  Run $key"
        if [ -n "$f" ]; then dsk_discard_file "$f"; else log "   ⚠️  No result file recorded for it — set it aside by hand"; fi
        awk -F'\t' -v d="DONE $key" -v r="RESULT $key" '$0!=d && $1!=r' "$STATE_FILE" > "$STATE_FILE.tmp" && mv -f "$STATE_FILE.tmp" "$STATE_FILE"
        TEST_RESULTS+=("🗑️  ${key}: discarded (just before a RAN degradation), measured again")
        DSK_DISCARDED=$((DSK_DISCARDED + 1)); n=$((n + 1))
    done
}

# Read the DONE lines of the state file into the caller's done_runs.
load_done_runs() {
    done_runs=()
    local line
    while IFS= read -r line; do
        [[ "$line" == DONE\ * ]] && done_runs["${line#DONE }"]=1
    done < "$STATE_FILE"
    return 0
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
    if [ "$DSK_DISCARDED" -gt 0 ]; then log "   Discarded (RAN degraded, measured again): $DSK_DISCARDED"; fi
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
    
    log "📁 Results directory: $SCRIPT_DIR/results/ (PacketRusher) or results_dsk/ (UE_TYPE=dsk)"
    log "📝 Runner log: $RUNNER_LOG_FILE"
    log "═══════════════════════════════════════════════════════════════"
}

handle_interrupt() {
    log ""
    log "🛑 Received interrupt signal (Ctrl+C)"
    INTERRUPTED=true
    print_summary
    [ -f "$STATE_FILE" ] && log "💾 Progress is saved. Continue later with: ./batch_runner.sh --resume"
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

    local c first_dsk=""
    for c in "${config_files[@]}"; do
        [[ "$c" =~ ^/ ]] || c="$CONFIG_DIR/$c"
        is_dsk_config "$c" && { first_dsk="$c"; break; }
    done
    # Dongle configs need commercial RAN support (same flag as the WebUI);
    # without it every one of them would fail on its own, so stop before
    # anything (including the resume state) is touched.
    if [ -n "$first_dsk" ] && ! grep -qiE '^DONGLE_ENABLED="?(1|true|yes|on)"?$' "$SCRIPT_DIR/webui/dongle.env" 2>/dev/null; then
        error_exit "$(basename "$first_dsk") uses the dongle (UE_TYPE=dsk), but commercial RAN support is disabled. Enable it with lib/features/set-dongle-mode.sh on."
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

    # The state belongs to one batch: same configs, in the same order, with the
    # same number of runner iterations. Anything else starts a new one.
    local batch_sig
    batch_sig=$(printf '%s\n' "$RUNNER_ITERATIONS" "${config_files[@]}" | sha256sum | cut -c1-16)
    local -A done_runs=()
    if [ "$RESUME" = true ] && [ -f "$STATE_FILE" ] && [ "$(sed -n '1s/^BATCH //p' "$STATE_FILE")" = "$batch_sig" ]; then
        load_done_runs
        log "♻️  Resuming: ${#done_runs[@]} of $total_runs runs are already done and will be skipped"
    else
        [ "$RESUME" = true ] && log "ℹ️  --resume: no saved progress for this set of configs — starting from the beginning"
        echo "BATCH $batch_sig" > "$STATE_FILE"
    fi
    # Safety net: start the batch on a freshly rebooted RU.
    if [ "$DSK_RU_REBOOT_AT_START" = true ] && [ -n "$first_dsk" ]; then
        dsk_recover_ran "$first_dsk" "scheduled: start of the batch" || { print_summary; exit 1; }
    fi

    # The loop over all runs starts over (skipping the runs already done) after
    # a RAN recovery discarded runs, so they are measured again in order.
    local restart_batch=true
    while [ "$restart_batch" = true ]; do
    restart_batch=false
    completed_runs=0
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
            local run_key="$iter|$config_file"
            if [ -n "${done_runs[$run_key]:-}" ]; then
                log "⏭️  Already completed in an earlier session — skipping"
                completed_runs=$((completed_runs + 1))
                continue
            fi
            # Which SIM a dongle run needs follows from the roaming mode.
            local sim_class=""
            if grep -qiE '^UE_TYPE=dsk' "$full_config_path"; then
                sim_class=$(grep -E '^ROAMING_MODE=' "$full_config_path" | head -1 | cut -d= -f2 | tr -d ' ' | tr 'A-Z_' 'a-z-')
            fi
            if [ -n "$sim_class" ] && [ -n "${NEED_SIM[$sim_class]:-}" ]; then
                log "⏭️  Needs the $sim_class SIM, which is not in the dongle — left for a later --resume"
                PENDING_SIM_RUNS+=("$config_basename [Iteration $iter/$RUNNER_ITERATIONS] ($sim_class SIM)")
                completed_runs=$((completed_runs + 1))
                continue
            fi
            local config_start_time=$(date +%s%N)
            local run_rc=0 run_result=""
            rm -f "$RUN_RESULT_NOTE"
            BATCH_RUN_RESULT_NOTE="$RUN_RESULT_NOTE" "$SCRIPT_DIR/testbed_automation.sh" --config "$full_config_path" || run_rc=$?
            [ -f "$RUN_RESULT_NOTE" ] && run_result="$(cat "$RUN_RESULT_NOTE")"
            if [ "$run_rc" -eq "$EXIT_RAN_DEGRADED" ]; then
                log "⚠️  $config_basename [Iteration $iter/$RUNNER_ITERATIONS]: the RAN degraded — run stopped"
                if [ "$DSK_RECOVERED_FROM_DEGRADED" = true ]; then
                    log "🛑 The RAN degraded again in the first run after a recovery — stopping the batch."
                    dsk_discard_file "$run_result"
                    print_summary; exit 1
                fi
                if [ "$DSK_DEGRADED_RECOVERIES" -ge "$DSK_MAX_RECOVERIES" ]; then
                    log "🛑 Already $DSK_DEGRADED_RECOVERIES RAN recoveries in this batch — stopping it."
                    dsk_discard_file "$run_result"
                    print_summary; exit 1
                fi
                dsk_rollback "$run_result"
                DSK_DEGRADED_RECOVERIES=$((DSK_DEGRADED_RECOVERIES + 1))
                dsk_recover_ran "$full_config_path" "the RAN degraded, recovery $DSK_DEGRADED_RECOVERIES/$DSK_MAX_RECOVERIES" \
                    || { print_summary; log "💾 Discarded runs are not marked done — fix the RAN, then run: ./batch_runner.sh --resume"; exit 1; }
                DSK_RECOVERED_FROM_DEGRADED=true
                load_done_runs
                log "🔁 Starting over from the first run that is not done"
                restart_batch=true
                break 2
            fi
            if [ "$run_rc" -eq "$EXIT_WRONG_SIM" ]; then
                local config_duration_ms=0
                log "🔁 $config_basename needs the ${sim_class:-other} SIM — skipping it and the other configs that need the same SIM"
                [ -n "$sim_class" ] && NEED_SIM[$sim_class]=1
                PENDING_SIM_RUNS+=("$config_basename [Iteration $iter/$RUNNER_ITERATIONS] (${sim_class:-other} SIM)")
                completed_runs=$((completed_runs + 1))
                continue
            fi
            if [ "$run_rc" -eq 0 ]; then
                echo "DONE $run_key" >> "$STATE_FILE"
                if [ -n "$run_result" ]; then printf 'RESULT %s\t%s\n' "$run_key" "$run_result" >> "$STATE_FILE"; fi
                if [ -n "$sim_class" ]; then
                    DSK_RECOVERED_FROM_DEGRADED=false
                    DSK_RUNS_SINCE_RU_REBOOT=$((DSK_RUNS_SINCE_RU_REBOOT + 1))
                    if [ "$DSK_ROLLBACK_LIMIT" -lt "$DSK_ROLLBACK_RUNS" ]; then DSK_ROLLBACK_LIMIT=$((DSK_ROLLBACK_LIMIT + 1)); fi
                fi
                local config_end_time=$(date +%s%N)
                local config_duration_ms=$(( (config_end_time - config_start_time) / 1000000 ))
                local config_duration_sec=$(echo "scale=2; $config_duration_ms / 1000" | bc)
                log "✅ Configuration $config_num Iteration $iter completed in ${config_duration_sec}s"
                TEST_RESULTS+=("✅ $config_basename [Iteration $iter/$RUNNER_ITERATIONS]: SUCCESS (${config_duration_sec}s)")
                TOTAL_SUCCESSFUL=$((TOTAL_SUCCESSFUL + 1))
                DSK_CONSECUTIVE_FAILURES=0
            else
                local config_end_time=$(date +%s%N)
                local config_duration_ms=$(( (config_end_time - config_start_time) / 1000000 ))
                local config_duration_sec=$(echo "scale=2; $config_duration_ms / 1000" | bc)
                log "❌ Configuration $config_num Iteration $iter FAILED after ${config_duration_sec}s"
                TEST_RESULTS+=("❌ $config_basename [Iteration $iter/$RUNNER_ITERATIONS]: FAILED (${config_duration_sec}s)")
                TOTAL_FAILED=$((TOTAL_FAILED + 1))
                if [ -n "$sim_class" ]; then
                    DSK_CONSECUTIVE_FAILURES=$((DSK_CONSECUTIVE_FAILURES + 1))
                    if [ "$DSK_MAX_CONSECUTIVE_FAILURES" -gt 0 ] && [ "$DSK_CONSECUTIVE_FAILURES" -ge "$DSK_MAX_CONSECUTIVE_FAILURES" ]; then
                        log ""
                        log "🛑 $DSK_CONSECUTIVE_FAILURES DSK runs failed in a row — the gNB or the dongle is likely down. Stopping the batch."
                        print_summary
                        log "💾 Failed runs are not marked done — fix the RAN, then run: ./batch_runner.sh --resume"
                        exit 1
                    fi
                fi
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
            # Safety net: reboot the RU on a schedule, before its timing drifts.
            if [ -n "$sim_class" ] && [ "$DSK_RU_REBOOT_EVERY" -gt 0 ] && [ "$DSK_RUNS_SINCE_RU_REBOOT" -ge "$DSK_RU_REBOOT_EVERY" ] && [ "$completed_runs" -lt "$total_runs" ]; then
                dsk_recover_ran "$full_config_path" "scheduled: $DSK_RUNS_SINCE_RU_REBOOT DSK runs since the last RU reboot" \
                    || { print_summary; exit 1; }
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
    done   # restart_batch
    
    # Print summary
    print_summary

    if [ "${#PENDING_SIM_RUNS[@]}" -gt 0 ]; then
        log ""
        log "🔁 ${#PENDING_SIM_RUNS[@]} run(s) are waiting for another SIM (needed: ${!NEED_SIM[*]}):"
        local pr
        for pr in "${PENDING_SIM_RUNS[@]}"; do log "     - $pr"; done
        log "   Insert that SIM, wait for the dongle to come back, then run: ./batch_runner.sh --resume"
        exit "$EXIT_WRONG_SIM"
    fi
    if [ "$TOTAL_FAILED" -gt 0 ]; then
        log "💾 Failed runs are not marked done — ./batch_runner.sh --resume repeats only those."
    else
        rm -f "$STATE_FILE" "$LAST_BATCH_FILE"
    fi

    return 0
}

# ============================================================================
# Main
# ============================================================================

main() {
    # Set up trap handler for Ctrl+C
    trap handle_interrupt SIGINT
    
    # A bare --resume continues the last batch started: take its command.
    if [ "$#" -eq 1 ] && [ "$1" = "--resume" ]; then
        [ -s "$LAST_BATCH_FILE" ] || error_exit "No unfinished batch to resume (the last one finished, or none was started yet)"
        local -a last_args=()
        mapfile -d '' -t last_args < "$LAST_BATCH_FILE"
        log "♻️  Resuming the last batch: ./batch_runner.sh ${last_args[*]}"
        set -- "${last_args[@]}" --resume
    fi
    # Remember this batch's command (without --resume) for a later bare --resume.
    case " $* " in
        "  "|*" -h "*|*" --help "*) ;;
        *)  local a
            for a in "$@"; do [ "$a" = "--resume" ] || printf '%s\0' "$a"; done > "$LAST_BATCH_FILE.tmp"
            mv -f "$LAST_BATCH_FILE.tmp" "$LAST_BATCH_FILE" ;;
    esac

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
            --resume)
                RESUME=true
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
    
    # A single matrix file given instead of configs (e.g. configs/main_DSK_lbo.conf,
    # picked in the WebUI's batch list) runs that matrix the way --all runs
    # main.conf. Its configs go to their own generated_<name>/ folder and its
    # progress to its own state file: the DSK matrices produce the same config
    # names as main.conf, and sharing the folder or the state file would let a
    # DSK run overwrite a PacketRusher batch's configs or its --resume progress.
    MAIN_CONF="$CONFIG_DIR/main.conf"
    GENERATED_SUBDIR="generated"
    if [ "$run_all" != true ] && [ "${#configs[@]}" -eq 1 ]; then
        local matrix_path="${configs[0]}"; [[ "$matrix_path" =~ ^/ ]] || matrix_path="$CONFIG_DIR/$matrix_path"
        if [ -f "$matrix_path" ] && grep -qE '^[[:space:]]*MODE_NAMES=' "$matrix_path"; then
            run_all=true
            configs=()
            MAIN_CONF="$matrix_path"
            if [ "$(realpath "$MAIN_CONF")" != "$(realpath "$CONFIG_DIR/main.conf")" ]; then
                local matrix_name; matrix_name="$(basename "$MAIN_CONF" .conf)"
                GENERATED_SUBDIR="generated_${matrix_name}"
                STATE_FILE="$SCRIPT_DIR/logs/batch_runner_${matrix_name}.state"
            fi
            log "📋 Running the matrix $(basename "$MAIN_CONF") (resume state: $(basename "$STATE_FILE"))"
        fi
    fi

    # If --all flag is set (or a matrix file was given), generate configs on the fly from it
    if [ "$run_all" = true ]; then
        if [ ! -f "$MAIN_CONF" ]; then
            error_exit "$(basename "$MAIN_CONF") not found in $CONFIG_DIR"
        fi
        # shellcheck source=/dev/null
        source "$MAIN_CONF"
        
        # Interface of the performance server that carries the DN server's half
        # of the N6 delay. SERVER_INTERFACE is the name testbed_automation.sh
        # uses; N6_SERVER_INTERFACE is its old name, still accepted in main.conf.
        SERVER_INTERFACE="${SERVER_INTERFACE:-${N6_SERVER_INTERFACE:-}}"
        if [[ -z "$SERVER_INTERFACE" ]]; then
            SERVER_INTERFACE="ens18"
            log "ℹ️  SERVER_INTERFACE not set in main.conf, using default: $SERVER_INTERFACE"
        else
            log "✓ Using SERVER_INTERFACE from main.conf: $SERVER_INTERFACE"
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
        GENERATED_CONFIG_DIR="$CONFIG_DIR/$GENERATED_SUBDIR"
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
                hr-remote-upf-ipsec) actual_roaming_mode="hr" ;;  # ...with the N4 (SMF<->UPF) path under IPsec
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
                            [[ -n "${SERVER_INTERFACE:-}" ]] && echo "SERVER_INTERFACE=$SERVER_INTERFACE"
                            [[ -n "${MIN_LINK_SPEED_MBPS:-}" ]] && echo "MIN_LINK_SPEED_MBPS=$MIN_LINK_SPEED_MBPS"
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
                            [[ -n "${IPERF_TCP_BANDWIDTH:-}" ]] && echo "IPERF_TCP_BANDWIDTH=$IPERF_TCP_BANDWIDTH"
                            [[ -n "${WEBPAGE_TEST_ENABLED:-}" ]] && echo "WEBPAGE_TEST_ENABLED=$WEBPAGE_TEST_ENABLED"
                            [[ -n "${WEBPAGE_BROWSER:-}" ]] && echo "WEBPAGE_BROWSER=$WEBPAGE_BROWSER"
                            [[ -n "${WEBPAGE_ITERATIONS:-}" ]] && echo "WEBPAGE_ITERATIONS=$WEBPAGE_ITERATIONS"
                            [[ -n "${WEBPAGE_TIMEOUT:-}" ]] && echo "WEBPAGE_TIMEOUT=$WEBPAGE_TIMEOUT"
                            # Which UE runs the tests (packetrusher, or dsk = commercial gNB + dongle)
                            for uvar in UE_TYPE DSK_DONGLE DSK_CYCLE DSK_DONGLE_HOST; do [[ -n "${!uvar:-}" ]] && echo "$uvar=${!uvar}"; done || true
                            for wvar in ${!WEBPAGE_URL_@}; do echo "$wvar=${!wvar}"; done
                        } > "$GENERATED_CONFIG_DIR/$conf_file"
                        dynamic_configs+=("$GENERATED_SUBDIR/$conf_file")
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
                        # LBO and HR-Remote-UPF: the DN origin is the vPLMN's own city.
                        # Looked up by name, not position, so a main.conf with fewer
                        # vPLMNs or DN locations (e.g. main_DSK.conf) still matches.
                        case "${vPLMNs[$latency_idx]:-}" in
                            France)    vplmn_city="Paris" ;;
                            USA)       vplmn_city="Boston" ;;
                            Australia) vplmn_city="Sydney" ;;
                            *)         vplmn_city="" ;;
                        esac
                        dn_locs_to_process=()
                        for i in "${!DN_LOCATIONS[@]}"; do
                            [ "${DN_LOCATIONS[$i]}" = "$vplmn_city" ] && dn_locs_to_process=("$i")
                        done
                        if [ "${#dn_locs_to_process[@]}" -eq 0 ]; then
                            log "⚠️  No DN location for vPLMN '${vPLMNs[$latency_idx]:-index $latency_idx}' in DN_LOCATIONS — skipping its $mode_name configs"
                        fi
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
                                    hr-remote-upf-ipsec) conf_base="hr-remote-upf-ipsec" ;;
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
                                    # hr-remote-upf-ipsec: the remote UPF is reached over N4, so the
                                    # path that crosses the distance is SMF<->UPF (PFCP). Protect it
                                    # with IPsec in BOTH PLMNs (N9 IPsec stays off in this mode). The
                                    # ESP cipher of each side can be pinned from main.conf with
                                    # N4_IPSEC_VPLMN_MODE / N4_IPSEC_HPLMN_MODE (1-6); otherwise each
                                    # side keeps its current cipher.
                                    if [ "$mode_name" = "hr-remote-upf-ipsec" ]; then
                                        echo "N4_IPSEC_VPLMN_ENABLED=true"
                                        echo "N4_IPSEC_HPLMN_ENABLED=true"
                                        [[ -n "${N4_IPSEC_VPLMN_MODE:-}" ]] && echo "N4_IPSEC_VPLMN_MODE=$N4_IPSEC_VPLMN_MODE"
                                        [[ -n "${N4_IPSEC_HPLMN_MODE:-}" ]] && echo "N4_IPSEC_HPLMN_MODE=$N4_IPSEC_HPLMN_MODE"
                                    fi
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
                                    elif [ "$mode_name" = "hr-remote-upf" ] || [ "$mode_name" = "hr-remote-upf-ipsec" ]; then
                                        # The pfcp delay mode matches PFCP in the clear and inside
                                        # ESP alike, so the same rules hold with N4 IPsec on.
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
                                    [[ -n "${SERVER_INTERFACE:-}" ]] && echo "SERVER_INTERFACE=$SERVER_INTERFACE"
                                    [[ -n "${MIN_LINK_SPEED_MBPS:-}" ]] && echo "MIN_LINK_SPEED_MBPS=$MIN_LINK_SPEED_MBPS"
                                    
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
                                    [[ -n "${IPERF_TCP_BANDWIDTH:-}" ]] && echo "IPERF_TCP_BANDWIDTH=$IPERF_TCP_BANDWIDTH"
                                    [[ -n "${WEBPAGE_TEST_ENABLED:-}" ]] && echo "WEBPAGE_TEST_ENABLED=$WEBPAGE_TEST_ENABLED"
                                    [[ -n "${WEBPAGE_BROWSER:-}" ]] && echo "WEBPAGE_BROWSER=$WEBPAGE_BROWSER"
                                    [[ -n "${WEBPAGE_ITERATIONS:-}" ]] && echo "WEBPAGE_ITERATIONS=$WEBPAGE_ITERATIONS"
                                    [[ -n "${WEBPAGE_TIMEOUT:-}" ]] && echo "WEBPAGE_TIMEOUT=$WEBPAGE_TIMEOUT"
                                    # Which UE runs the tests (packetrusher, or dsk = commercial gNB + dongle)
                                    for uvar in UE_TYPE DSK_DONGLE DSK_CYCLE DSK_DONGLE_HOST; do [[ -n "${!uvar:-}" ]] && echo "$uvar=${!uvar}"; done || true
                                    for wvar in ${!WEBPAGE_URL_@}; do echo "$wvar=${!wvar}"; done
                                } > "$GENERATED_CONFIG_DIR/$conf_file"
                                dynamic_configs+=("$GENERATED_SUBDIR/$conf_file")
                            done
                        done
                    done
                done
            fi
        done
        log "📂 Dynamically generated ${#dynamic_configs[@]} config runs from $(basename "$MAIN_CONF")"
        configs=("${dynamic_configs[@]}")
    fi

    # If no configs provided, show help and exit
    if [ ${#configs[@]} -eq 0 ]; then
        show_help
        exit 1
    fi

    # main.conf (and copies of it such as main_DSK.conf) is not a test config:
    # it defines the matrix that --all turns into the real configs. Run as a
    # config it has no roaming mode and no per-config delays, and fails late
    # with a misleading "N6_DELAY_VALUE not set". Refuse it up front.
    local cfg cfg_path
    for cfg in "${configs[@]}"; do
        cfg_path="$cfg"; [[ "$cfg" =~ ^/ ]] || cfg_path="$CONFIG_DIR/$cfg"
        if [ -f "$cfg_path" ] && grep -qE '^[[:space:]]*MODE_NAMES=' "$cfg_path"; then
            error_exit "$(basename "$cfg_path") is the batch matrix definition, not a test config. Give a matrix file on its own to run it (WebUI: select only that file), or run main.conf with --all (WebUI: tick 'Run all configs')."
        fi
    done

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
  --resume                           Continue the last batch (interrupted, stopped or with failed
                                     runs): on its own it repeats that batch's command; the runs
                                     already done are skipped. With configs/options given, it
                                     continues the batch that has exactly those
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
  (10.0.0.30, user: roaming) and can be overridden in main.conf via
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
