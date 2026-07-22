#!/bin/bash
# lib/automation/preflight.sh
# Pre-run validation (Docker, SSH, image, config folder), container health
# checks, and service-readiness waiting before starting a test run.

preflight_check() {
    record_timing preflight_start
    log "🔍 Running preflight checks..."
    
    local failed=0
    local failed_checks=""
    
    # Check 1: Local Docker
    log "   Checking local Docker..."
    if ! docker info &>/dev/null; then
        log "   ❌ Local Docker check failed"
        failed=$((failed + 1))
        failed_checks="${failed_checks}docker "
    else
        log "   ✅ Local Docker OK"
    fi
    
    # Check 2: SSH connectivity (for roaming modes)
    if [ "$ROAMING_MODE" != "non-roaming" ]; then
        log "   Checking SSH to $REMOTE_PC_USER@$HPLMN_IP..."
        if ! ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE \
            "$REMOTE_PC_USER@$HPLMN_IP" "echo ok" &>/dev/null; then
            log "   ❌ SSH connectivity check failed"
            failed=$((failed + 1))
            failed_checks="${failed_checks}ssh "
        else
            log "   ✅ SSH connectivity OK"
        fi
    fi
    
    # Check 3: SSH to performance server (if N6 delay or tests need it)
    if [ "$N6_DELAY_ENABLED" = "true" ] || [ "$DOWNLOAD_TEST_ENABLED" = "true" ] || [ "$IPERF_TEST_ENABLED" = "true" ] || [ "$VIDEO_TEST_ENABLED" = "true" ]; then
        log "   Checking SSH to $SERVER_USER@$SERVER_IP (perf-server)..."
        if ! ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE \
            "$SERVER_USER@$SERVER_IP" "echo ok" &>/dev/null; then
            if [ "$N6_DELAY_ENABLED" = "true" ]; then
                log "   ❌ Performance server SSH check failed (required for N6 delay)"
                failed=$((failed + 1))
                failed_checks="${failed_checks}server_ssh "
            else
                log "   ⚠️  Performance server SSH check failed (server delay won't be applied)"
            fi
        else
            log "   ✅ Performance server SSH OK"
        fi
    fi
    
    # Check 4: PacketRusher image (warning only, not fatal)
    log "   Checking PacketRusher image..."
    if ! docker image inspect "$PR_IMAGE" &>/dev/null; then
        log "   ⚠️  PacketRusher image not found locally (will try to pull)"
    else
        log "   ✅ PacketRusher image OK"
    fi
    
    # Check 5: Config folder and files
    if [ -n "${PR_CONFIG_FOLDER:-}" ]; then
        log "   Checking config folder: $CONFIG_DIR/$PR_CONFIG_FOLDER..."
        if [ ! -d "$CONFIG_DIR/$PR_CONFIG_FOLDER" ]; then
            log "   ❌ Config folder not found: $CONFIG_DIR/$PR_CONFIG_FOLDER"
            failed=$((failed + 1))
            failed_checks="${failed_checks}config_folder "
        elif [ ! -f "$CONFIG_DIR/$PR_CONFIG_FOLDER/config_1.yml" ]; then
            log "   ❌ No config files found in: $CONFIG_DIR/$PR_CONFIG_FOLDER"
            failed=$((failed + 1))
            failed_checks="${failed_checks}config_files "
        else
            log "   ✅ Config folder OK"
        fi
    fi
    
    # Final result
    if [ $failed -gt 0 ]; then
        log "   ❌ Preflight failed: $failed check(s) failed [$failed_checks]"
        error_exit "Preflight failed - check: $failed_checks"
    fi
    
    record_timing preflight_end
    log "✅ Preflight checks passed ($(get_elapsed_ms preflight_start preflight_end)ms)"
}

# ============================================================================
# Health Check Functions (OPTIMIZED)
# ============================================================================

check_service_health_local() {
    # Quick check: are critical containers running?
    local running=$(docker compose ps --format '{{.Service}}:{{.State}}' 2>/dev/null | grep -c ":running" || true)
    local total=${#CRITICAL_SERVICES_LOCAL[@]}
    [ "${running:-0}" -ge "$total" ] && return 0
    return 1
}

check_service_health_remote() {
    local result=$(ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE \
        "$REMOTE_PC_USER@$HPLMN_IP" \
        "cd $REMOTE_PC_PATH && docker compose ps --format '{{.Service}}:{{.State}}' 2>/dev/null | grep -c ':running'" 2>/dev/null || true)
    local total=${#CRITICAL_SERVICES_REMOTE[@]}
    [ "${result:-0}" -ge "$total" ] && return 0
    return 1
}

wait_for_services_ready() {
    local location=$1
    local max_wait=$NETWORK_READY_TIMEOUT
    local waited=0
    local check_func="check_service_health_local"
    [ "$location" = "remote" ] && check_func="check_service_health_remote"
    
    log "   ⏳ Waiting for $location services..."
    
    while [ $waited -lt $max_wait ]; do
        if $check_func; then
            log "   ✅ $location services ready (${waited}s)"
            return 0
        fi
        sleep $SERVICE_CHECK_INTERVAL
        waited=$((waited + SERVICE_CHECK_INTERVAL))
    done
    
    log "   ⚠️ $location services timeout after ${waited}s (proceeding anyway)"
    return 0  # Don't fail, just warn
}

