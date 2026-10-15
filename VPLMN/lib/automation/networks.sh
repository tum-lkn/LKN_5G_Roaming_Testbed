#!/bin/bash
# lib/automation/networks.sh
# Container and interface lookup helpers, Docker network creation,
# IPsec management (start/stop/configure), parallel VPLMN+HPLMN startup,
# and testbed restart with clean state.

get_host_default_interface() {
    local location=$1
    if [ "$location" = "local" ]; then
        ip route | grep default | awk '{print $5}' | head -1
    else
        ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE "$REMOTE_PC_USER@$HPLMN_IP" \
            "ip route | grep default | awk '{print \$5}' | head -1" 2>/dev/null
    fi
}

get_docker_bridge_for_network() {
    local network_name=$1
    local location=$2
    local cmd="docker network inspect '$network_name' -f '{{.Id}}' 2>/dev/null | cut -c1-12"
    local network_id
    if [ "$location" = "local" ]; then
        network_id=$(eval "$cmd")
    else
        network_id=$(ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE \
            "$REMOTE_PC_USER@$HPLMN_IP" "$cmd" 2>/dev/null)
    fi
    [ -n "$network_id" ] && echo "br-$network_id"
}

get_control_plane_bridge_interface() {
    local location=$1
    if [ "$location" = "local" ]; then
        get_docker_bridge_for_network "$VPLMN_CONTROL_PLANE_NETWORK" "$location"
    else
        get_docker_bridge_for_network "$HPLMN_CONTROL_PLANE_NETWORK" "$location"
    fi
}

get_n3_bridge_interface() {
    local location=$1
    [ "$location" = "local" ] && get_docker_bridge_for_network "$VPLMN_USER_PLANE_NETWORK" "$location"
}

get_container_name_for_service() {
    local service=$1
    local location=$2
    local path="."
    [ "$location" != "local" ] && path="$REMOTE_PC_PATH"
    local short_name="${service#open5gs-}"
    local cmd="cd $path && docker compose ps --format '{{.Name}}:{{.Service}}' 2>/dev/null | grep -E ':(${short_name}|${service})\$' | cut -d: -f1 | head -1"
    if [ "$location" = "local" ]; then
        eval "$cmd"
    else
        ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE \
            "$REMOTE_PC_USER@$HPLMN_IP" "$cmd" 2>/dev/null
    fi
}

# ============================================================================
# IPsec Functions (FIXED - Sequential status check to avoid subshell variable issues)
# ============================================================================

check_local_ipsec_status() {
    if sudo ipsec status &>/dev/null; then
        # grep -c already prints 0 when nothing matches (and exits 1), so a
        # `|| echo 0` here appended a SECOND 0 and made $status the two-line
        # string "0\n0", which then broke every numeric test below.
        local status=$(sudo ipsec statusall 2>/dev/null | grep -c "ESTABLISHED" || true)
        if [ "${status:-0}" -gt 0 ]; then
            LOCAL_IPSEC_STATUS="running"
            return 0
        fi
    fi
    LOCAL_IPSEC_STATUS="stopped"
    return 0  # Always return success - this is a status check, not an error condition
}

check_remote_ipsec_status() {
    local status=$(ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE \
        "$REMOTE_PC_USER@$HPLMN_IP" \
        "sudo ipsec statusall 2>/dev/null | grep -c ESTABLISHED || true" 2>/dev/null | tail -1)
    if [ "${status:-0}" -gt 0 ]; then
        REMOTE_IPSEC_STATUS="running"
        return 0
    fi
    REMOTE_IPSEC_STATUS="stopped"
    return 0  # Always return success - this is a status check, not an error condition
}

check_ipsec_status() {
    log "🔍 Checking N9 IPsec status..."
    # Run sequentially to avoid subshell variable scoping issues
    check_local_ipsec_status
    check_remote_ipsec_status
    log "   Local: $LOCAL_IPSEC_STATUS"
    log "   Remote: $REMOTE_IPSEC_STATUS"
}

# N4 (SMF<->UPF) status, per PLMN — scoped to the n4-smf-upf conn so it never
# confuses N4 with N9. VPLMN is local; HPLMN is over SSH (roaming modes only).
check_n4_ipsec_status() {
    log "🔍 Checking N4 IPsec status..."
    local lstat
    lstat=$(sudo ipsec statusall 2>/dev/null | grep 'n4-smf-upf' | grep -cE 'ESTABLISHED|INSTALLED' || true)
    LOCAL_N4_STATUS=$([ "${lstat:-0}" -gt 0 ] && echo "running" || echo "stopped")
    log "   VPLMN: $LOCAL_N4_STATUS"
    if [ "$ROAMING_MODE" != "non-roaming" ]; then
        local rstat
        rstat=$(ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE \
            "$REMOTE_PC_USER@$HPLMN_IP" \
            "sudo ipsec statusall 2>/dev/null | grep 'n4-smf-upf' | grep -cE 'ESTABLISHED|INSTALLED' || true" 2>/dev/null | tail -1)
        REMOTE_N4_STATUS=$([ "${rstat:-0}" -gt 0 ] && echo "running" || echo "stopped")
        log "   HPLMN: $REMOTE_N4_STATUS"
    fi
}

stop_all_ipsec() {
    log "🛑 Stopping N9 IPsec on both PCs..."

    # Stop local IPsec
    log "   Stopping local N9 IPsec..."
    sudo ipsec stop &>/dev/null || true
    sudo ip xfrm state flush &>/dev/null || true
    sudo ip xfrm policy flush &>/dev/null || true

    # Stop remote IPsec
    log "   Stopping remote N9 IPsec..."
    ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE \
        "$REMOTE_PC_USER@$HPLMN_IP" \
        "sudo ipsec stop 2>/dev/null || true; sudo ip xfrm state flush 2>/dev/null || true; sudo ip xfrm policy flush 2>/dev/null || true" 2>/dev/null || true

    # Clear status variables
    LOCAL_IPSEC_STATUS="stopped"
    REMOTE_IPSEC_STATUS="stopped"

    log "✅ N9 IPsec stopped on both PCs"
}

# Full N4 (SMF<->UPF) teardown. The N9 `stop_all_ipsec` above does NOT cover N4:
# N4 runs a SEPARATE charon inside the SMF container, so only n4_ipsec.sh stop
# (which downs the SMF-container side AND the host N4 conn, leaving N9 alone)
# fully tears it down. Quiet + non-fatal; used by the end-of-run cleanup so N4
# does not linger after a run.
stop_n4_ipsec() {
    local n4_script="docker/n4-ipsec/n4_ipsec.sh"
    [ -f "$SCRIPT_DIR/$n4_script" ] || return 0
    sudo bash "$SCRIPT_DIR/$n4_script" stop >/dev/null 2>&1 || true
    if [ "$ROAMING_MODE" != "non-roaming" ]; then
        ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE \
            "$REMOTE_PC_USER@$HPLMN_IP" "cd $REMOTE_PC_PATH && sudo -n bash $n4_script stop" >/dev/null 2>&1 || true
    fi
    log "🛑 N4 IPsec stopped"
}

start_all_ipsec() {
    log "🔐 Starting N9 IPsec (parallel)..."

    # Start remote first (it's the responder typically)
    ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE \
        "$REMOTE_PC_USER@$HPLMN_IP" "sudo ipsec start" &>/dev/null &
    local remote_pid=$!

    # Brief pause then start local
    sleep 1
    sudo ipsec start &>/dev/null &
    local local_pid=$!

    # Wait for both charons to start
    wait $remote_pid $local_pid 2>/dev/null || true

    # The N9 conn is auto=add (loaded but NOT auto-initiated), so `ipsec start`
    # alone never brings the tunnel up. The VPLMN is the initiator — bring the
    # conn up explicitly; the HPLMN side is the responder, already loaded and
    # waiting. (Without this the tunnel stays down: "not established".)
    sleep 1
    sudo ipsec up "$N9_CONN" &>/dev/null &

    # Wait for establishment with timeout
    local waited=0
    while [ $waited -lt $IPSEC_ESTABLISH_TIMEOUT ]; do
        local status=$(sudo ipsec statusall 2>/dev/null | grep -c "ESTABLISHED" || true)
        [ "${status:-0}" -gt 0 ] && { log "✅ N9 IPsec ESTABLISHED (${waited}s)"; return 0; }
        sleep 1
        waited=$((waited + 1))
    done

    log "⚠️  N9 IPsec not established after ${waited}s"
    return 1
}

# N4 (SMF<->UPF PFCP) IPsec — PER PLMN. Each side is an independent tunnel on its
# own host, driven by N4_IPSEC_{VPLMN,HPLMN}_ENABLED, each with an optional
# N4_IPSEC_{VPLMN,HPLMN}_MODE (1-6; empty = keep that side's current/last cipher).
# Applied via docker/n4-ipsec/n4_ipsec.sh: `cipher N` (set+restart) when a mode is
# given, else `start` (current cipher) when enabled, else `stop`. VPLMN runs
# locally; HPLMN over SSH (roaming modes only). Non-fatal on error.
configure_n4_ipsec() {
    record_timing n4_ipsec_start
    local n4_script="docker/n4-ipsec/n4_ipsec.sh"
    local logfile="$LOG_DIR/batch_${TIMESTAMP}.log"
    local out rc cmd
    log "======================================="
    log " Configuring N4 IPsec (SMF<->UPF, per PLMN)"
    log "======================================="

    # ---- VPLMN (local) ----
    if [ -f "$SCRIPT_DIR/$n4_script" ]; then
        if [ "$N4_IPSEC_VPLMN_ENABLED" = "true" ]; then
            if [ -n "$N4_IPSEC_VPLMN_MODE" ]; then
                cmd="cipher $N4_IPSEC_VPLMN_MODE"
                log "   VPLMN: N4 IPsec ENABLED — mode $N4_IPSEC_VPLMN_MODE (${IPSEC_MODE_NAMES[$N4_IPSEC_VPLMN_MODE]})"
            else
                cmd="start"
                log "   VPLMN: N4 IPsec ENABLED — current/last cipher"
            fi
            out=$(sudo bash "$SCRIPT_DIR/$n4_script" $cmd 2>&1)
            printf '%s\n' "$out" | sed 's/^/[n4:local] /' >> "$logfile" 2>/dev/null || true
            if grep -q 'ESTABLISHED\|INSTALLED' <<<"$out"; then
                log "   ✅ N4 IPsec established (VPLMN, SMF<->UPF)"
            else
                log "   ⚠️  N4 IPsec did not establish (VPLMN) — see batch log"
            fi
        else
            out=$(sudo bash "$SCRIPT_DIR/$n4_script" stop 2>&1)
            printf '%s\n' "$out" | sed 's/^/[n4:local] /' >> "$logfile" 2>/dev/null || true
            log "   ✅ N4 IPsec stopped (VPLMN)"
        fi
    else
        log "   ⚠️  local N4 script not found ($n4_script) — skipping VPLMN N4 IPsec"
    fi

    # ---- HPLMN (remote) — only for roaming modes (a home network must exist) ----
    if [ "$ROAMING_MODE" != "non-roaming" ]; then
        if [ "$N4_IPSEC_HPLMN_ENABLED" = "true" ]; then
            if [ -n "$N4_IPSEC_HPLMN_MODE" ]; then
                cmd="cipher $N4_IPSEC_HPLMN_MODE"
                log "   HPLMN: N4 IPsec ENABLED — mode $N4_IPSEC_HPLMN_MODE (${IPSEC_MODE_NAMES[$N4_IPSEC_HPLMN_MODE]})"
            else
                cmd="start"
                log "   HPLMN: N4 IPsec ENABLED — current/last cipher"
            fi
        else
            cmd="stop"
            log "   HPLMN: N4 IPsec DISABLED"
        fi
        out=$(ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE \
            "$REMOTE_PC_USER@$HPLMN_IP" "cd $REMOTE_PC_PATH && sudo -n bash $n4_script $cmd" 2>&1); rc=$?
        printf '%s\n' "$out" | sed 's/^/[n4:remote] /' >> "$logfile" 2>/dev/null || true
        if [ "$rc" -ne 0 ]; then
            log "   ⚠️  remote N4 IPsec '$cmd' did not complete (is N4 deployed/updated on HPLMN?)"
        elif [ "$N4_IPSEC_HPLMN_ENABLED" != "true" ]; then
            log "   ✅ N4 IPsec stopped (HPLMN)"
        elif grep -q 'ESTABLISHED\|INSTALLED' <<<"$out"; then
            log "   ✅ N4 IPsec established (HPLMN, SMF<->UPF)"
        else
            log "   ⚠️  N4 IPsec did not establish (HPLMN) — see batch log"
        fi
    fi
    record_timing n4_ipsec_end
    check_cancel
}

configure_ipsec() {
    [ "$ROAMING_MODE" != "hr" ] && return 0
    record_timing ipsec_start
    log "======================================="
    log " Configuring N9 IPsec"
    log "======================================="
    
    # ALWAYS stop N9 IPsec first to ensure clean state
    log "   Stopping any existing N9 IPsec tunnels (clean state)..."
    stop_all_ipsec

    # Now start N9 IPsec only if enabled
    if [ "$IPSEC_ENABLED" = "true" ]; then
        if [ -n "$IPSEC_MODE" ]; then
            # Use esp_config.sh to set the IPsec mode and start tunnels
            log "   N9 IPsec ENABLED with Mode $IPSEC_MODE (${IPSEC_MODE_NAMES[$IPSEC_MODE]})"

            if [ ! -f "$IPSEC_CONFIG_SCRIPT" ]; then
                log "   ❌ N9 IPsec config script not found: $IPSEC_CONFIG_SCRIPT"
                log "   ⚠️  Falling back to default N9 IPsec start..."
                sleep 1
                start_all_ipsec || true
            else
                # Run via `sudo -n bash <script>`, NEVER `sudo <script>`: only
                # bash/ipsec/docker/ip/... are in the host's passwordless sudoers,
                # so `sudo <script.sh>` prompts for a password and fails under the
                # non-tty WebUI/batch runner (which is why N9 silently never came
                # up while the N4 path — already `sudo bash` — worked).
                #
                # esp_config.sh is very chatty (banners + a full IKE handshake
                # trace). Mirror the N4 side: capture its output, keep the full
                # detail in the batch log file, and print ONE concise line here.
                local logfile="$LOG_DIR/batch_${TIMESTAMP}.log"
                log "   Running esp_config.sh (mode $IPSEC_MODE) — details in batch log..."
                local esp_out esp_rc
                esp_out=$(sudo -n bash "$IPSEC_CONFIG_SCRIPT" "$IPSEC_MODE" 2>&1); esp_rc=$?
                printf '%s\n' "$esp_out" | sed 's/^/[esp_config] /' >> "$logfile" 2>/dev/null || true
                # Decide success by the tunnel actually being up (never report ✅ on
                # a no-op). Give the SA a moment to come up first.
                sleep 2
                if sudo -n ipsec status 2>/dev/null | grep -q "ESTABLISHED"; then
                    log "   ✅ N9 IPsec ESTABLISHED with mode $IPSEC_MODE"
                else
                    log "   ❌ N9 IPsec NOT established (esp_config.sh rc=$esp_rc) — see batch log"
                fi
            fi
        else
            # No specific mode, use default N9 IPsec start
            log "   N9 IPsec ENABLED - establishing tunnels with current config..."
            sleep 1
            start_all_ipsec || true
        fi
    else
        log "   N9 IPsec DISABLED - tunnels will remain stopped"
    fi

    record_timing ipsec_end
    log "✅ N9 IPsec configuration complete ($(get_elapsed_ms ipsec_start ipsec_end)ms)"
    check_cancel
}

# ============================================================================
# Docker Network Management
# ============================================================================

# Ensure required VPLMN Docker networks exist (create if missing).
# Networks are defined externally so they persist across compose up/down cycles.
ensure_docker_networks() {
    local -A networks=(
        ["my_custom_network"]="192.168.50.0/24"
        ["my_second_network"]="192.168.70.0/24"
        ["my_isolated_network"]="192.168.80.0/24"
    )
    for name in "${!networks[@]}"; do
        local subnet="${networks[$name]}"
        if ! docker network inspect "$name" &>/dev/null; then
            log "   Creating Docker network: $name ($subnet)"
            docker network create --driver bridge --subnet "$subnet" "$name" \
                || { log "   ⚠️  Failed to create Docker network: $name"; return 1; }
        else
            log "   ✅ Docker network already exists: $name"
        fi
    done
}

# Ensure required HPLMN Docker network exists on the remote PC.
ensure_remote_docker_networks() {
    ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE \
        "$REMOTE_PC_USER@$HPLMN_IP" "
        if ! docker network inspect my_custom_network &>/dev/null; then
            echo '   Creating Docker network: my_custom_network (192.168.60.0/24)'
            docker network create --driver bridge --subnet 192.168.60.0/24 my_custom_network
        else
            echo '   Docker network already exists: my_custom_network'
        fi
    " || log "   ⚠️  Could not ensure HPLMN Docker networks"
}

# ============================================================================
# Network Start Functions (OPTIMIZED - Parallel)
# ============================================================================

start_home_network_internal() {
    local logfile="$LOG_DIR/hplmn_start_${TIMESTAMP}.tmp"

    # Read IP values to write into the HPLMN .env
    local _hplmn_ip="$HPLMN_IP"
    local _vplmn_ip
    _vplmn_ip=$(grep -oP '^VPLMN_IP\s*=\s*\K[0-9.]+' "$ENV_FILE" 2>/dev/null || true)

    {
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] Starting Home Network (HPLMN)..."
        
        ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE \
            "$REMOTE_PC_USER@$HPLMN_IP" "
            cd $REMOTE_PC_PATH || exit 1
            
            cat > .env << 'ENVEOF'
# Generated by testbed automation script v$SCRIPT_VERSION - $(date -Iseconds)
# Security: $REMOTE_SECURITY_MODE
# Roaming: $ROAMING_MODE

HPLMN_IP=$_hplmn_ip
VPLMN_IP=$_vplmn_ip

NRF_CONFIG=nrf$REMOTE_SUFFIX
SCP_CONFIG=scp$REMOTE_SUFFIX
AMF_CONFIG=amf$REMOTE_SUFFIX
SMF_CONFIG=smf$REMOTE_SUFFIX
UPF_CONFIG=upf$REMOTE_SUFFIX
AUSF_CONFIG=ausf$REMOTE_SUFFIX
UDM_CONFIG=udm$REMOTE_SUFFIX
PCF_CONFIG=pcf$REMOTE_SUFFIX
NSSF_CONFIG=nssf$REMOTE_SUFFIX
BSF_CONFIG=bsf$REMOTE_SUFFIX
UDR_CONFIG=udr$REMOTE_SUFFIX
SEPP_CONFIG=sepp$REMOTE_SUFFIX
ENVEOF
            
            if ! docker network inspect my_custom_network &>/dev/null; then
                echo 'Creating Docker network: my_custom_network (192.168.60.0/24)'
                docker network create --driver bridge --subnet 192.168.60.0/24 my_custom_network
            fi
            docker compose down 2>/dev/null || true
            docker compose up -d
        " 2>&1 || { echo "HPLMN start failed"; exit 1; }
        
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] ✅ Home network containers started"
    } > "$logfile" 2>&1
    
    return $?
}

start_visited_network_internal() {
    local logfile="$LOG_DIR/vplmn_start_${TIMESTAMP}.tmp"
    
    {
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] Starting Visited Network (VPLMN)..."
        
        [ ! -f "docker-compose.yml" ] && { echo "docker-compose.yml not found"; exit 1; }
        
        ensure_docker_networks
        docker compose down 2>/dev/null || true
        docker compose up -d 2>&1 || { echo "VPLMN start failed"; exit 1; }
        
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] ✅ Visited network containers started"
    } > "$logfile" 2>&1
    
    return $?
}

start_networks_parallel() {
    record_timing networks_start
    log "======================================="
    log " Starting Networks (Parallel Mode)"
    log "======================================="
    
    local pids=()
    local start_time=$(date +%s)
    
    if [ "$ROAMING_MODE" != "non-roaming" ]; then
        log "   🚀 Launching HPLMN startup (background)..."
        start_home_network_internal &
        pids+=($!)
    fi
    
    log "   🚀 Launching VPLMN startup (background)..."
    start_visited_network_internal &
    pids+=($!)
    
    # Wait for all startups to complete
    log "   ⏳ Waiting for network startups to complete..."
    local failed=0
    for pid in "${pids[@]}"; do
        wait "$pid" || failed=$((failed + 1))
    done
    
    # Collect and display logs
    [ -f "$LOG_DIR/hplmn_start_${TIMESTAMP}.tmp" ] && cat "$LOG_DIR/hplmn_start_${TIMESTAMP}.tmp" >> "$LOG_DIR/batch_${TIMESTAMP}.log"
    [ -f "$LOG_DIR/vplmn_start_${TIMESTAMP}.tmp" ] && cat "$LOG_DIR/vplmn_start_${TIMESTAMP}.tmp" >> "$LOG_DIR/batch_${TIMESTAMP}.log"
    rm -f "$LOG_DIR/hplmn_start_${TIMESTAMP}.tmp" "$LOG_DIR/vplmn_start_${TIMESTAMP}.tmp"
    
    local elapsed=$(($(date +%s) - start_time))
    
    [ $failed -gt 0 ] && error_exit "One or more networks failed to start"
    
    record_timing networks_end
    log "✅ All networks started in parallel (${elapsed}s)"
    check_cancel   # a cancel during the ~30s parallel startup is honored here
}

wait_for_all_services() {
    record_timing health_start
    log "======================================="
    log " Waiting for Services to be Ready"
    log "======================================="
    
    local pids=()
    
    # Start health checks in parallel
    wait_for_services_ready "local" &
    pids+=($!)
    
    if [ "$ROAMING_MODE" != "non-roaming" ]; then
        wait_for_services_ready "remote" &
        pids+=($!)
    fi
    
    # Wait for all health checks
    for pid in "${pids[@]}"; do
        wait "$pid" || true
    done
    
    # Minimum stabilization time (cancellable so a cancel here isn't ignored)
    [ $MIN_NETWORK_STABILIZE_TIME -gt 0 ] && {
        log "   ⏳ Network stabilization (${MIN_NETWORK_STABILIZE_TIME}s)..."
        cancellable_sleep $MIN_NETWORK_STABILIZE_TIME
    }

    check_cancel
    record_timing health_end
    log "✅ All services ready ($(get_elapsed_ms health_start health_end)ms)"
}

# Legacy functions for backward compatibility
start_home_network() {
    log "======================================="
    log " Starting Home Network (HPLMN)"
    log "======================================="
    ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE \
        "$REMOTE_PC_USER@$HPLMN_IP" "echo ok" &>/dev/null || error_exit "Cannot connect to remote PC"
    log "✅ SSH connection verified"

    # Read IP values to write into the HPLMN .env
    _hplmn_ip="$HPLMN_IP"
    _vplmn_ip=$(grep -oP '^VPLMN_IP\s*=\s*\K[0-9.]+' "$ENV_FILE" 2>/dev/null || true)

    ssh "$REMOTE_PC_USER@$HPLMN_IP" "cd $REMOTE_PC_PATH && cat > .env << EOF
# Generated by testbed automation script v$SCRIPT_VERSION - $(date -Iseconds)
# Security: $REMOTE_SECURITY_MODE
# Roaming: $ROAMING_MODE

HPLMN_IP=$_hplmn_ip
VPLMN_IP=$_vplmn_ip

NRF_CONFIG=nrf$REMOTE_SUFFIX
SCP_CONFIG=scp$REMOTE_SUFFIX
AMF_CONFIG=amf$REMOTE_SUFFIX
SMF_CONFIG=smf$REMOTE_SUFFIX
UPF_CONFIG=upf$REMOTE_SUFFIX
AUSF_CONFIG=ausf$REMOTE_SUFFIX
UDM_CONFIG=udm$REMOTE_SUFFIX
PCF_CONFIG=pcf$REMOTE_SUFFIX
NSSF_CONFIG=nssf$REMOTE_SUFFIX
BSF_CONFIG=bsf$REMOTE_SUFFIX
UDR_CONFIG=udr$REMOTE_SUFFIX
SEPP_CONFIG=sepp$REMOTE_SUFFIX
EOF"
    ensure_remote_docker_networks
    ssh "$REMOTE_PC_USER@$HPLMN_IP" "cd $REMOTE_PC_PATH && docker compose down 2>/dev/null; docker compose up -d" || true
    log "✅ Home network started"
}

start_visited_network() {
    log "======================================="
    log " Starting Visited Network (VPLMN)"
    log "======================================="
    [ ! -f "docker-compose.yml" ] && error_exit "docker-compose.yml not found"
    ensure_docker_networks
    docker compose down 2>/dev/null || true
    docker compose up -d
    log "✅ Visited network started"
}

restart_testbed() {
    log "🔄 =============================================="
    log "🔄  RESTARTING TESTBED"
    log "🔄 =============================================="
    [ ${#APPLIED_DELAYS[@]} -gt 0 ] && remove_all_delays
    
    # Cleanup PacketRusher and interfaces in parallel
    (
        sudo docker rm -f "$PR_CONTAINER" &>/dev/null || true
        for iface in $(ip link show 2>/dev/null | grep -oP 'val\d+' | sort -u); do
            sudo ip link set "$iface" down 2>/dev/null || true
            sudo ip link delete "$iface" 2>/dev/null || true
        done
    ) &
    local cleanup_pid=$!
    
    # Stop networks
    docker compose down &>/dev/null &
    local local_stop_pid=$!
    
    [ "$ROAMING_MODE" != "non-roaming" ] && {
        ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE \
            "$REMOTE_PC_USER@$HPLMN_IP" "cd $REMOTE_PC_PATH && docker compose down" 2>/dev/null &
    }
    
    wait $cleanup_pid $local_stop_pid 2>/dev/null || true
    
    # Reload gtp5g if needed
    if lsmod | grep -q "^gtp5g "; then
        sudo rmmod gtp5g 2>/dev/null || true
        sleep 1
        sudo modprobe gtp5g 2>/dev/null || true
    fi
    
    # Start networks in parallel
    start_networks_parallel
    wait_for_all_services
    
    [ "$IPSEC_ENABLED" = "true" ] && start_all_ipsec || true
    reapply_preconfigured_delays
    # The real gNB does not reconnect to a restarted AMF on its own.
    is_dsk && { dsk_bring_up_ran || log "⚠️  The RAN did not come back after the restart; the next iteration checks again"; }
    log "✅ Testbed restart complete"
}
