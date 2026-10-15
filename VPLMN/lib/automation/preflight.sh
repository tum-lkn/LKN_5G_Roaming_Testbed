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
            # The DN server's half of the N6 delay is `sudo tc` on its interface.
            # Check both here: found only when the delay is applied, each config
            # fails after the cores have already been restarted.
            if [ "$N6_DELAY_ENABLED" = "true" ]; then
                local srv_check
                srv_check=$(ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE \
                    "$SERVER_USER@$SERVER_IP" \
                    "ip link show '$SERVER_INTERFACE' >/dev/null 2>&1 || echo NO_IFACE; sudo -n tc qdisc show dev '$SERVER_INTERFACE' >/dev/null 2>&1 || echo NO_SUDO_TC" 2>/dev/null) || true
                if [[ "$srv_check" == *NO_IFACE* ]]; then
                    log "   ❌ Performance server has no interface '$SERVER_INTERFACE' — set SERVER_INTERFACE to its real one (on the server: ip -br addr)"
                    failed=$((failed + 1)); failed_checks="${failed_checks}server_interface "
                elif [[ "$srv_check" == *NO_SUDO_TC* ]]; then
                    log "   ❌ Performance server: 'sudo tc' needs a password for $SERVER_USER (required for the N6 delay)."
                    log "      On the server, once: echo '$SERVER_USER ALL=(root) NOPASSWD: /usr/sbin/tc' | sudo tee /etc/sudoers.d/roamingtb-tc && sudo chmod 440 /etc/sudoers.d/roamingtb-tc"
                    failed=$((failed + 1)); failed_checks="${failed_checks}server_sudo_tc "
                else
                    log "   ✅ Performance server: interface $SERVER_INTERFACE and passwordless 'sudo tc' OK"
                fi
            fi
        fi
    fi
    
    # Check 3b: link speed of the testbed interfaces. On 2026-10-07 the VPLMN NIC
    # had silently fallen back to 100 Mb/s (gigabit link flaps, bad cable): the
    # 100 Mbps iperf plus GTP/ESP overhead overflowed it, adding 1.4-7.5% loss and
    # capping downloads in every mode. Each host is checked on the interface it
    # uses to reach the other. MIN_LINK_SPEED_MBPS=0 disables the check.
    if [ "${MIN_LINK_SPEED_MBPS:-1000}" -gt 0 ]; then
        local min=${MIN_LINK_SPEED_MBPS:-1000} slow="" probe
        probe='i=$(ip -o route get %s 2>/dev/null | grep -oP "dev \K\S+"); echo "$i $(cat /sys/class/net/$i/speed 2>/dev/null || echo ?)"'
        local -a link_checks=("VPLMN|local|$HPLMN_IP")
        [ "$ROAMING_MODE" != "non-roaming" ] && link_checks+=("HPLMN|remote|")
        local entry name where target res iface speed
        for entry in "${link_checks[@]}"; do
            IFS='|' read -r name where target <<<"$entry"
            if [ "$where" = "local" ]; then
                res=$(bash -c "$(printf "$probe" "$target")")
            else
                # The HPLMN reaches this PC through the source address it sees for us.
                target=$(ip -o route get "$HPLMN_IP" 2>/dev/null | grep -oP 'src \K[0-9.]+')
                res=$(ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE \
                    "$REMOTE_PC_USER@$HPLMN_IP" "$(printf "$probe" "$target")" 2>/dev/null)
            fi
            read -r iface speed <<<"$res"
            if [[ "$speed" =~ ^[0-9]+$ ]] && [ "$speed" -ge "$min" ]; then
                log "   ✅ $name link $iface: ${speed} Mb/s"
            elif [[ "$speed" =~ ^[0-9]+$ ]] && [ "$speed" -gt 0 ]; then
                log "   ❌ $name link $iface is ${speed} Mb/s (expected >= ${min}) — check the cable/port; it caps throughput and adds loss"
                slow="${slow}${name} "
            else
                log "   ⚠️  $name link speed unknown (${iface:-no interface}) — not checked"
            fi
        done
        if [ -n "${SERVER_IP:-}" ] && { [ "$N6_DELAY_ENABLED" = "true" ] || [ "$DOWNLOAD_TEST_ENABLED" = "true" ] || [ "$IPERF_TEST_ENABLED" = "true" ]; }; then
            speed=$(ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE \
                "$SERVER_USER@$SERVER_IP" "cat /sys/class/net/$SERVER_INTERFACE/speed" 2>/dev/null)
            if [[ "$speed" =~ ^[0-9]+$ ]] && [ "$speed" -ge "$min" ]; then
                log "   ✅ Performance server link $SERVER_INTERFACE: ${speed} Mb/s"
            elif [[ "$speed" =~ ^[0-9]+$ ]] && [ "$speed" -gt 0 ]; then
                log "   ❌ Performance server link $SERVER_INTERFACE is ${speed} Mb/s (expected >= ${min})"
                slow="${slow}perf-server "
            fi
        fi
        if [ -n "$slow" ]; then
            failed=$((failed + 1)); failed_checks="${failed_checks}link_speed(${slow% }) "
        fi
    fi

    # Check 4: the UE. A commercial RAN (UE_TYPE=dsk) is checked by dsk.sh:
    # control host, dongle scripts, gNB host, and the SIM against the mode.
    if is_dsk; then
        dsk_preflight
    else
        # PacketRusher image (build from source if missing; not fatal)
        log "   Checking PacketRusher image..."
        if ! docker image inspect "$PR_IMAGE" &>/dev/null; then
            log "   ⚠️  '$PR_IMAGE' not found — building from source (docker/packetrusher-docker)..."
            if "$SCRIPT_DIR/docker/packetrusher-docker/build_packetrusher.sh" >>"$LOG_FILE" 2>&1; then
                log "   ✅ PacketRusher image built"
            else
                log "   ⚠️  Failed to build PacketRusher image (see $LOG_FILE)"
            fi
        else
            log "   ✅ PacketRusher image OK"
        fi
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

