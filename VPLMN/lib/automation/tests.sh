#!/bin/bash
# lib/automation/tests.sh
# PacketRusher container lifecycle (start with timing, cleanup, DNS config)
# and all test types: ping, download, video streaming, iperf3 throughput,
# and webpage loading time (YouTube, Instagram).

strip_ansi() { sed 's/\x1b\[[0-9;]*m//g' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g'; }

docker_timestamp_to_ms() {
    local ts="$1"
    local datetime="${ts%%.*}"
    local nanos="${ts#*.}"; nanos="${nanos%Z}"
    nanos=$(printf "%-9s" "$nanos" | tr ' ' '0'); nanos="${nanos:0:9}"
    local epoch_sec=$(date -d "${datetime}" +%s 2>/dev/null || echo "0")
    local millis="${nanos:0:3}"
    echo "$((epoch_sec * 1000 + 10#$millis))"
}

cleanup_packetrusher_fast() {
    # Fast cleanup without waiting
    sudo docker rm -f "$PR_CONTAINER" &>/dev/null &
    local docker_pid=$!
    
    # Clean interfaces in parallel
    for iface in $(ip link show 2>/dev/null | grep -oP 'val\d+' | sort -u); do
        sudo ip link set "$iface" down 2>/dev/null &
        sudo ip link delete "$iface" 2>/dev/null &
    done
    
    wait $docker_pid 2>/dev/null || true
}

start_packetrusher_with_timing() {
    local iteration=$1
    
    # Determine which config file to use based on iteration
    local pr_config_file
    if [ -n "${PR_CONFIG_FOLDER:-}" ]; then
        pr_config_file="$PR_CONFIG_FOLDER/config_${iteration}.yml"
        if [ ! -f "$CONFIG_DIR/$pr_config_file" ]; then
            log "⚠️  Config file not found: $pr_config_file, falling back to config_1.yml"
            pr_config_file="$PR_CONFIG_FOLDER/config_1.yml"
        fi
    else
        # Legacy mode: use single config file
        pr_config_file="$PR_CONFIG"
    fi
    
    log ""; log "---------------------------------------"
    log " Iteration $iteration: Starting PacketRusher with $pr_config_file"
    log "---------------------------------------"
    
    PR_SUCCESS="" PR_ERROR="" PR_UE_IP="" PR_VRF=""
    PR_CONTAINER_START_TS="" PR_REG_INIT_TS="" PR_PDU_INIT_TS="" PR_PDU_COMPLETE_TS=""
    PR_TOTAL_MS="" PR_STARTUP_TO_REG_MS="" PR_REG_TO_PDU_INIT_MS="" PR_PDU_SETUP_MS=""
    
    # Fast cleanup
    cleanup_packetrusher_fast
    sleep 0.5  # Brief pause for cleanup
    
    PR_CONTAINER_START_TS=$(get_timestamp_ms)
    log "⏱️  [T0] Container starting"
    
    sudo docker run --privileged --cap-add=ALL --net "$PR_NETWORK" --ip "$PR_IP" --name "$PR_CONTAINER" \
        -v "$CONFIG_DIR/$pr_config_file:/PacketRusher/config/config.yml" \
        -d "$PR_IMAGE" --config /PacketRusher/config/config.yml ue &>/dev/null || { PR_SUCCESS="false"; PR_ERROR="container_start_failed"; return 1; }
    
    log "✅ Container started, monitoring..."
    local max_wait=120 waited=0 pdu_complete=false
    while [ $waited -lt $max_wait ]; do
        local logs=$(sudo docker logs "$PR_CONTAINER" 2>&1 | strip_ansi)
        echo "$logs" | grep -q "Unable to create Kernel GTP interface\|cannot allocate memory" && { PR_SUCCESS="false"; PR_ERROR="gtp_kernel_error"; return 1; }
        echo "$logs" | grep -q "PDU address received:" && echo "$logs" | grep -q "using VRF vrf" && { pdu_complete=true; break; }
        sleep 0.5; waited=$((waited + 1))
    done
    [ "$pdu_complete" = false ] && { PR_SUCCESS="false"; PR_ERROR="timeout"; return 1; }
    
    log "   📊 Extracting timestamps..."
    local timestamped_logs=$(sudo docker logs -t "$PR_CONTAINER" 2>&1 | strip_ansi)
    echo "$timestamped_logs" > "$LOG_DIR/packetrusher_iter${iteration}_${TIMESTAMP}.log"
    local plain_logs=$(sudo docker logs "$PR_CONTAINER" 2>&1 | strip_ansi)
    
    PR_UE_IP=$(echo "$plain_logs" | grep -oP 'PDU address received: \K\d+\.\d+\.\d+\.\d+' | tail -1)
    PR_VRF=$(echo "$plain_logs" | grep -oP 'using VRF \K(vrf\d+)' | tail -1)
    [ -z "$PR_UE_IP" ] || [ -z "$PR_VRF" ] && { PR_SUCCESS="false"; PR_ERROR="parse_error"; return 1; }
    
    local t1_line=$(echo "$timestamped_logs" | grep "\[UE\] Initiating Registration" | head -1)
    [ -n "$t1_line" ] && PR_REG_INIT_TS=$(docker_timestamp_to_ms "$(echo "$t1_line" | awk '{print $1}')")
    local t2_line=$(echo "$timestamped_logs" | grep "\[UE\] Initiating New PDU Session" | head -1)
    [ -n "$t2_line" ] && PR_PDU_INIT_TS=$(docker_timestamp_to_ms "$(echo "$t2_line" | awk '{print $1}')")
    local t3_line=$(echo "$timestamped_logs" | grep "PDU address received" | head -1)
    [ -n "$t3_line" ] && PR_PDU_COMPLETE_TS=$(docker_timestamp_to_ms "$(echo "$t3_line" | awk '{print $1}')")
    
    [ -n "$PR_REG_INIT_TS" ] && [ "$PR_REG_INIT_TS" -gt 0 ] && PR_STARTUP_TO_REG_MS=$((PR_REG_INIT_TS - PR_CONTAINER_START_TS)) || PR_STARTUP_TO_REG_MS=0
    [ "$PR_STARTUP_TO_REG_MS" -lt 0 ] && PR_STARTUP_TO_REG_MS=0
    [ -n "$PR_REG_INIT_TS" ] && [ -n "$PR_PDU_INIT_TS" ] && PR_REG_TO_PDU_INIT_MS=$((PR_PDU_INIT_TS - PR_REG_INIT_TS)) || PR_REG_TO_PDU_INIT_MS=0
    [ "$PR_REG_TO_PDU_INIT_MS" -lt 0 ] && PR_REG_TO_PDU_INIT_MS=0
    [ -n "$PR_PDU_INIT_TS" ] && [ -n "$PR_PDU_COMPLETE_TS" ] && PR_PDU_SETUP_MS=$((PR_PDU_COMPLETE_TS - PR_PDU_INIT_TS)) || PR_PDU_SETUP_MS=0
    [ "$PR_PDU_SETUP_MS" -lt 0 ] && PR_PDU_SETUP_MS=0
    [ -n "$PR_PDU_COMPLETE_TS" ] && PR_TOTAL_MS=$((PR_PDU_COMPLETE_TS - PR_CONTAINER_START_TS)) || PR_TOTAL_MS=$((PR_STARTUP_TO_REG_MS + PR_REG_TO_PDU_INIT_MS + PR_PDU_SETUP_MS))
    [ "$PR_TOTAL_MS" -lt 0 ] && PR_TOTAL_MS=0
    
    PR_SUCCESS="true"
    log "   ✅ Registration complete! UE IP: $PR_UE_IP, VRF: $PR_VRF"
    log "   ⏱️  Timing: T0→T1: ${PR_STARTUP_TO_REG_MS}ms, T1→T2: ${PR_REG_TO_PDU_INIT_MS}ms, T2→T3: ${PR_PDU_SETUP_MS}ms, TOTAL: ${PR_TOTAL_MS}ms"
    
    # Configure DNS inside container for external domain resolution
    configure_container_dns
    
    return 0
}

# Configure DNS inside PacketRusher container for external domain resolution
configure_container_dns() {
    log "   🌐 Configuring DNS (8.8.8.8) inside container..."
    sudo docker exec "$PR_CONTAINER" sh -c 'echo "nameserver 8.8.8.8" > /etc/resolv.conf' 2>/dev/null && \
        log "   ✅ DNS configured" || \
        log "   ⚠️  DNS configuration failed (external domains may not resolve)"
}

PING_SUCCESS=0 PING_FAIL=0 PING_MIN=0 PING_MAX=0 PING_AVG=0 PING_LOSS=0

perform_ping_tests() {
    local ue_ip=$1 vrf=$2
    log "   📡 Running ping tests to $PING_TARGET..."
    
    # Show ping configuration
    local ping_config_info="interval=${PING_INTERVAL}s"
    [ -n "$PING_PAYLOAD_SIZE" ] && ping_config_info+=", payload=${PING_PAYLOAD_SIZE}B"
    log "   📋 Ping config: $ping_config_info"
    
    PING_SUCCESS=0 PING_FAIL=0 PING_MIN=999999 PING_MAX=0
    local total_time=0
    
    # Build ping command options
    local ping_opts="-c 1 -W 2 -I $ue_ip"
    ping_opts+=" -i $PING_INTERVAL"
    [ -n "$PING_PAYLOAD_SIZE" ] && ping_opts+=" -s $PING_PAYLOAD_SIZE"
    
    # Print header for live ping display
    printf "   ┌─────┬────────────┬─────────────────────────────────────────┐\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │ %3s │ %10s │ %-39s │\n" "#" "RTT (ms)" "Status" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   ├─────┼────────────┼─────────────────────────────────────────┤\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    
    for i in $(seq 1 "$PING_COUNT"); do
        local output=$(sudo docker exec "$PR_CONTAINER" ip vrf exec "$vrf" ping $ping_opts "$PING_TARGET" 2>&1)
        local exit_code=$?
        
        if [ $exit_code -eq 0 ]; then
            local time=$(echo "$output" | grep -oP 'time=\K[\d.]+' | head -1)
            if [ -n "$time" ]; then
                PING_SUCCESS=$((PING_SUCCESS + 1))
                total_time=$(echo "$total_time + $time" | bc)
                (( $(echo "$time < $PING_MIN" | bc -l) )) && PING_MIN=$time
                (( $(echo "$time > $PING_MAX" | bc -l) )) && PING_MAX=$time
                
                # Color code based on RTT value
                local status_icon="✓"
                local status_text="OK"
                if (( $(echo "$time > 100" | bc -l) )); then
                    status_text="OK (high latency)"
                elif (( $(echo "$time > 50" | bc -l) )); then
                    status_text="OK (moderate)"
                fi
                
                printf "   │ %3d │ %10.2f │ %s %-37s │\n" "$i" "$time" "$status_icon" "$status_text" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
            else 
                PING_FAIL=$((PING_FAIL + 1))
                printf "   │ %3d │ %10s │ ⚠ %-37s │\n" "$i" "---" "Parse error" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
            fi
        else
            PING_FAIL=$((PING_FAIL + 1))
            local fail_reason="Timeout/Unreachable"
            echo "$output" | grep -q "Network is unreachable" && fail_reason="Network unreachable"
            echo "$output" | grep -q "Destination Host Unreachable" && fail_reason="Host unreachable"
            printf "   │ %3d │ %10s │ ✗ %-37s │\n" "$i" "---" "$fail_reason" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
        fi
        
        # Respect ping interval between pings
        [ "$i" -lt "$PING_COUNT" ] && sleep 0.05
    done
    
    # Calculate statistics
    [ $PING_SUCCESS -gt 0 ] && PING_AVG=$(echo "scale=2; $total_time / $PING_SUCCESS" | bc) || { PING_MIN=0; PING_MAX=0; PING_AVG=0; }
    (( $(echo "$PING_MIN == 999999" | bc -l) )) && PING_MIN=0
    PING_LOSS=$(echo "scale=2; ($PING_FAIL / $PING_COUNT) * 100" | bc)
    
    # Print summary footer
    printf "   ├─────┴────────────┴─────────────────────────────────────────┤\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │ 📊 Summary: %d/%d OK | Loss: %.1f%% | Min: %.2f | Max: %.2f | Avg: %.2f ms │\n" \
        "$PING_SUCCESS" "$PING_COUNT" "$PING_LOSS" "$PING_MIN" "$PING_MAX" "$PING_AVG" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   └────────────────────────────────────────────────────────────┘\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
}

# ============================================================================
# Download Test Functions (NEW in v3.2.0)
# ============================================================================

perform_download_test() {
    local ue_ip=$1
    local vrf=$2
    
    # Check if download test is enabled
    if [ "$DOWNLOAD_TEST_ENABLED" != "true" ]; then
        return 0
    fi
    
    # Validate URL is configured
    if [ -z "$DOWNLOAD_TEST_URL" ]; then
        log "   ⚠️  Download test enabled but DOWNLOAD_TEST_URL not set, skipping"
        DL_SUCCESS="false"
        return 0
    fi
    
    local size_label="${DOWNLOAD_TEST_SIZE_LABEL:-file}"
    log "   📥 Running download test ($size_label)..."
    log "   📋 URL: $DOWNLOAD_TEST_URL"
    
    # Reset download test results
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
    
    # Build curl output format for JSON parsing
    local curl_format='{"size_download":%{size_download},"speed_download":%{speed_download},"time_namelookup":%{time_namelookup},"time_connect":%{time_connect},"time_appconnect":%{time_appconnect},"time_starttransfer":%{time_starttransfer},"time_total":%{time_total},"remote_ip":"%{remote_ip}","remote_port":%{remote_port},"local_ip":"%{local_ip}","http_code":%{http_code},"num_redirects":%{num_redirects}}'
    
    # Execute curl inside the container with VRF and interface binding
    local curl_output
    curl_output=$(sudo docker exec "$PR_CONTAINER" ip vrf exec "$vrf" \
        curl --interface "$ue_ip" \
             --silent \
             --output /dev/null \
             --write-out "$curl_format" \
             --max-time 300 \
             --connect-timeout 30 \
             "$DOWNLOAD_TEST_URL" 2>&1) || {
        log "   ❌ Download test failed: curl command error"
        DL_SUCCESS="false"
        return 1
    }
    
    # Parse JSON output
    if ! echo "$curl_output" | jq -e . >/dev/null 2>&1; then
        log "   ❌ Download test failed: Invalid curl output"
        log "   curl output: $curl_output"
        DL_SUCCESS="false"
        return 1
    fi
    
    # Extract values from JSON
    DL_SIZE_BYTES=$(echo "$curl_output" | jq -r '.size_download // 0')
    DL_SPEED_BPS=$(echo "$curl_output" | jq -r '.speed_download // 0')
    DL_TIME_DNS=$(echo "$curl_output" | jq -r '.time_namelookup // 0')
    DL_TIME_CONNECT=$(echo "$curl_output" | jq -r '.time_connect // 0')
    DL_TIME_TLS=$(echo "$curl_output" | jq -r '.time_appconnect // 0')
    DL_TIME_TTFB=$(echo "$curl_output" | jq -r '.time_starttransfer // 0')
    DL_TIME_TOTAL=$(echo "$curl_output" | jq -r '.time_total // 0')
    DL_REMOTE_IP=$(echo "$curl_output" | jq -r '.remote_ip // ""')
    DL_HTTP_CODE=$(echo "$curl_output" | jq -r '.http_code // 0')
    
    # Check HTTP code
    if [ "$DL_HTTP_CODE" -ne 200 ]; then
        log "   ❌ Download test failed: HTTP $DL_HTTP_CODE"
        DL_SUCCESS="false"
        return 1
    fi
    
    # Convert speed to human readable format
    local speed_mbps=$(echo "scale=2; $DL_SPEED_BPS / 1048576" | bc | sed 's/^\./0./')
    local speed_kbps=$(echo "scale=2; $DL_SPEED_BPS / 1024" | bc | sed 's/^\./0./')
    local size_mb=$(echo "scale=2; $DL_SIZE_BYTES / 1048576" | bc | sed 's/^\./0./')
    
    DL_SUCCESS="true"
    
    # Print results in nice format
    printf "   ┌────────────────────────────────────────────────────────────┐\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │         DOWNLOAD TEST RESULTS (%s)                    │\n" "$size_label" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   ├────────────────────────────────────────────────────────────┤\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │ FILE METRICS:                                              │\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │   Size Downloaded:    %12d bytes (%s MB)       │\n" "$DL_SIZE_BYTES" "$size_mb" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │   Speed:              %12.0f bytes/sec (%s MB/s) │\n" "$DL_SPEED_BPS" "$speed_mbps" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   ├────────────────────────────────────────────────────────────┤\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │ TIME BREAKDOWN:                                            │\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │   DNS Lookup:         %12.6f sec                   │\n" "$DL_TIME_DNS" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │   TCP Connect:        %12.6f sec                   │\n" "$DL_TIME_CONNECT" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │   TLS Handshake:      %12.6f sec                   │\n" "$DL_TIME_TLS" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │   Time to First Byte: %12.6f sec                   │\n" "$DL_TIME_TTFB" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │   Total Time:         %12.6f sec                   │\n" "$DL_TIME_TOTAL" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   ├────────────────────────────────────────────────────────────┤\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │ CONNECTION INFO:                                           │\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │   Remote IP:          %-20s               │\n" "$DL_REMOTE_IP" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │   Local IP:           %-20s               │\n" "$ue_ip" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │   HTTP Code:          %-20d               │\n" "$DL_HTTP_CODE" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   └────────────────────────────────────────────────────────────┘\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    
    log "   ✅ Download test complete: ${size_mb}MB @ ${speed_mbps}MB/s in ${DL_TIME_TOTAL}s"
    return 0
}

perform_video_test() {
    local ue_ip=$1
    local vrf=$2
    
    # Check if video test is enabled
    if [ "$VIDEO_TEST_ENABLED" != "true" ]; then
        return 0
    fi
    
    # Validate URL is configured
    if [ -z "$VIDEO_TEST_URL" ]; then
        log "   ⚠️  Video test enabled but VIDEO_TEST_URL not set, skipping"
        VID_SUCCESS="false"
        return 0
    fi
    
    local size_label="${VIDEO_TEST_SIZE_LABEL:-video}"
    log "   🎬 Running video streaming test ($size_label)..."
    log "   📋 URL: $VIDEO_TEST_URL"
    
    # Reset video test results
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
    
    # Build curl command with JSON output format
    local curl_format='{"size_download":%{size_download},"speed_download":%{speed_download},"time_namelookup":%{time_namelookup},"time_connect":%{time_connect},"time_starttransfer":%{time_starttransfer},"time_total":%{time_total},"remote_ip":"%{remote_ip}","http_code":%{http_code}}'
    
    # Execute curl inside PacketRusher container
    local curl_output
    curl_output=$(sudo docker exec "$PR_CONTAINER" ip vrf exec "$vrf" \
        curl --interface "$ue_ip" \
        -o /dev/null \
        -s \
        --max-time 600 \
        --connect-timeout 30 \
        -w "$curl_format" \
        "$VIDEO_TEST_URL" 2>&1)
    
    # Parse JSON output
    if ! echo "$curl_output" | jq -e . >/dev/null 2>&1; then
        log "   ❌ Video test failed: Invalid curl output"
        log "   curl output: $curl_output"
        VID_SUCCESS="false"
        return 1
    fi
    
    # Extract values from JSON
    VID_SIZE_BYTES=$(echo "$curl_output" | jq -r '.size_download // 0')
    VID_SPEED_BPS=$(echo "$curl_output" | jq -r '.speed_download // 0')
    VID_TIME_DNS=$(echo "$curl_output" | jq -r '.time_namelookup // 0')
    VID_TIME_CONNECT=$(echo "$curl_output" | jq -r '.time_connect // 0')
    VID_TIME_TTFB=$(echo "$curl_output" | jq -r '.time_starttransfer // 0')
    VID_TIME_TOTAL=$(echo "$curl_output" | jq -r '.time_total // 0')
    VID_REMOTE_IP=$(echo "$curl_output" | jq -r '.remote_ip // ""')
    VID_HTTP_CODE=$(echo "$curl_output" | jq -r '.http_code // 0')
    
    # Check if connection was established
    if [ "$VID_HTTP_CODE" -eq 0 ]; then
        log "   ❌ Video test failed: Could not connect to server"
        log "   (DNS lookup: ${VID_TIME_DNS}s, possible DNS or network issue)"
        VID_SUCCESS="false"
        return 1
    fi
    
    # Check HTTP code for success
    if [ "$VID_HTTP_CODE" -ne 200 ]; then
        log "   ❌ Video test failed: HTTP $VID_HTTP_CODE"
        VID_SUCCESS="false"
        return 1
    fi
    
    # Calculate streaming quality in Mbps
    VID_STREAMING_MBPS=$(echo "scale=2; $VID_SPEED_BPS / 125000" | bc | sed 's/^\./0./')
    
    # Convert to human readable format
    local speed_mbps=$(echo "scale=2; $VID_SPEED_BPS / 1048576" | bc | sed 's/^\./0./')
    local size_mb=$(echo "scale=2; $VID_SIZE_BYTES / 1048576" | bc | sed 's/^\./0./')
    
    VID_SUCCESS="true"
    
    # Print results in nice format
    printf "   ┌────────────────────────────────────────────────────────────┐\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │       VIDEO STREAMING TEST (%s)                     │\n" "$size_label" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   ├────────────────────────────────────────────────────────────┤\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │ FILE METRICS:                                              │\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │   Size Downloaded:    %12d bytes (%s MB)       │\n" "$VID_SIZE_BYTES" "$size_mb" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │   Speed:              %12.0f bytes/sec (%s MB/s) │\n" "$VID_SPEED_BPS" "$speed_mbps" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   ├────────────────────────────────────────────────────────────┤\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │ TIME BREAKDOWN:                                            │\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │   DNS Lookup:         %12.6f sec                   │\n" "$VID_TIME_DNS" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │   TCP Connect:        %12.6f sec                   │\n" "$VID_TIME_CONNECT" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │   Time to First Byte: %12.6f sec                   │\n" "$VID_TIME_TTFB" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │   Total Time:         %12.6f sec                   │\n" "$VID_TIME_TOTAL" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   ├────────────────────────────────────────────────────────────┤\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │ STREAMING QUALITY:                                         │\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │   Bitrate:            %12s Mbps                   │\n" "$VID_STREAMING_MBPS" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │   Quality:            %-35s │\n" "$(get_streaming_quality "$VID_STREAMING_MBPS")" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   ├────────────────────────────────────────────────────────────┤\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │ CONNECTION INFO:                                           │\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │   Remote IP:          %-20s               │\n" "$VID_REMOTE_IP" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │   Local IP:           %-20s               │\n" "$ue_ip" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │   HTTP Code:          %-20d               │\n" "$VID_HTTP_CODE" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   └────────────────────────────────────────────────────────────┘\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    
    log "   ✅ Video test complete: ${size_mb}MB @ ${speed_mbps}MB/s (${VID_STREAMING_MBPS} Mbps) in ${VID_TIME_TOTAL}s"
    return 0
}

# Helper function to determine streaming quality based on Mbps
get_streaming_quality() {
    local mbps=$1
    local mbps_int=$(echo "$mbps * 100" | bc | cut -d. -f1)
    
    if [ "$mbps_int" -ge 2500 ]; then
        echo "4K Ultra HD (25+ Mbps) ✓"
    elif [ "$mbps_int" -ge 1500 ]; then
        echo "4K HD (15-25 Mbps) ✓"
    elif [ "$mbps_int" -ge 500 ]; then
        echo "1080p Full HD (5-15 Mbps) ✓"
    elif [ "$mbps_int" -ge 300 ]; then
        echo "720p HD (3-5 Mbps) ✓"
    elif [ "$mbps_int" -ge 150 ]; then
        echo "480p SD (1.5-3 Mbps)"
    elif [ "$mbps_int" -ge 50 ]; then
        echo "360p Low (0.5-1.5 Mbps)"
    else
        echo "Poor (<0.5 Mbps) ✗"
    fi
}

# ============================================================================
# iperf3 Test Functions (NEW in v3.2.1)
# ============================================================================

perform_iperf_test() {
    local ue_ip=$1
    local vrf=$2
    
    # Check if iperf3 test is enabled
    if [ "$IPERF_TEST_ENABLED" != "true" ]; then
        return 0
    fi
    
    # Validate server IP is configured
    if [ -z "$IPERF_SERVER_IP" ]; then
        log "   ⚠️  iperf3 test enabled but IPERF_SERVER_IP not set, skipping"
        IPERF_SUCCESS="false"
        return 0
    fi
    
    local mode_desc="TCP"
    [ "$IPERF_UDP" = "true" ] && mode_desc="UDP"
    [ "$IPERF_REVERSE" = "true" ] && mode_desc="$mode_desc (reverse/download)"
    
    log "   📊 Running iperf3 test ($mode_desc, ${IPERF_DURATION}s)..."
    log "   📋 Server: $IPERF_SERVER_IP:$IPERF_SERVER_PORT"
    log "   📋 Binding to UE IP: $ue_ip via VRF: $vrf"
    
    # Reset iperf3 client-side results
    IPERF_SUCCESS=""
    IPERF_BITS_PER_SEC=0
    IPERF_BYTES_TRANSFERRED=0
    IPERF_RETRANSMITS=0
    IPERF_JITTER_MS=0
    IPERF_LOST_PACKETS=0
    IPERF_LOST_PERCENT=0
    
    # Reset iperf3 server-side results
    IPERF_SRV_BITS_PER_SEC=0
    IPERF_SRV_BYTES_TRANSFERRED=0
    IPERF_SRV_RETRANSMITS=0
    IPERF_SRV_JITTER_MS=0
    IPERF_SRV_LOST_PACKETS=0
    IPERF_SRV_LOST_PERCENT=0
    IPERF_SRV_OUTPUT_AVAILABLE="false"
    
    # Build iperf3 command (--get-server-output captures server perspective)
    local iperf_cmd="iperf3 -B $ue_ip -c $IPERF_SERVER_IP -p $IPERF_SERVER_PORT -t $IPERF_DURATION -J --get-server-output"
    [ "$IPERF_PARALLEL" -gt 1 ] 2>/dev/null && iperf_cmd+=" -P $IPERF_PARALLEL"
    [ "$IPERF_REVERSE" = "true" ] && iperf_cmd+=" -R"
    [ "$IPERF_UDP" = "true" ] && iperf_cmd+=" -u"
    [ "$IPERF_UDP" = "true" ] && [ -n "$IPERF_BANDWIDTH" ] && iperf_cmd+=" -b $IPERF_BANDWIDTH"
    
    log "   📋 Command: ip vrf exec $vrf $iperf_cmd"
    
    # Execute iperf3 inside the container with VRF
    local iperf_output exit_code
    set +e
    iperf_output=$(sudo docker exec "$PR_CONTAINER" ip vrf exec "$vrf" $iperf_cmd 2>&1)
    exit_code=$?
    set -e
    
    # Check for iperf3 not installed
    if echo "$iperf_output" | grep -q "not found\|No such file"; then
        log "   ❌ iperf3 not installed in PacketRusher container"
        log "   💡 Install with: sudo docker exec $PR_CONTAINER apt install -y iperf3"
        IPERF_SUCCESS="false"
        return 0
    fi
    
    # Check for connection errors
    if echo "$iperf_output" | grep -q "unable to connect\|Connection refused\|Cannot assign"; then
        log "   ❌ iperf3 connection failed"
        log "   Error: $(echo "$iperf_output" | grep -i "unable to connect\|Connection refused\|Cannot assign" | head -1)"
        log "   💡 Make sure iperf3 server is running: iperf3 -s -p $IPERF_SERVER_PORT"
        IPERF_SUCCESS="false"
        return 0
    fi
    
    # Check for other errors or non-zero exit
    if [ $exit_code -ne 0 ]; then
        log "   ❌ iperf3 test failed (exit code: $exit_code)"
        log "   Output: $(echo "$iperf_output" | head -3)"
        IPERF_SUCCESS="false"
        return 0
    fi
    
    # Parse JSON output
    if ! echo "$iperf_output" | jq -e '.end' >/dev/null 2>&1; then
        log "   ❌ iperf3 test failed: Invalid JSON output"
        IPERF_SUCCESS="false"
        return 1
    fi
    
    # ── Extract CLIENT-SIDE results ──
    if [ "$IPERF_UDP" = "true" ]; then
        # UDP results
        IPERF_BITS_PER_SEC=$(echo "$iperf_output" | jq -r '.end.sum.bits_per_second // 0')
        IPERF_BYTES_TRANSFERRED=$(echo "$iperf_output" | jq -r '.end.sum.bytes // 0')
        IPERF_JITTER_MS=$(echo "$iperf_output" | jq -r '.end.sum.jitter_ms // 0')
        IPERF_LOST_PACKETS=$(echo "$iperf_output" | jq -r '.end.sum.lost_packets // 0')
        IPERF_LOST_PERCENT=$(echo "$iperf_output" | jq -r '.end.sum.lost_percent // 0')
        IPERF_RETRANSMITS=0
    else
        # TCP results
        if [ "$IPERF_REVERSE" = "true" ]; then
            IPERF_BITS_PER_SEC=$(echo "$iperf_output" | jq -r '.end.sum_received.bits_per_second // 0')
            IPERF_BYTES_TRANSFERRED=$(echo "$iperf_output" | jq -r '.end.sum_received.bytes // 0')
        else
            IPERF_BITS_PER_SEC=$(echo "$iperf_output" | jq -r '.end.sum_sent.bits_per_second // 0')
            IPERF_BYTES_TRANSFERRED=$(echo "$iperf_output" | jq -r '.end.sum_sent.bytes // 0')
            IPERF_RETRANSMITS=$(echo "$iperf_output" | jq -r '.end.sum_sent.retransmits // 0')
        fi
        IPERF_JITTER_MS=0
        IPERF_LOST_PACKETS=0
        IPERF_LOST_PERCENT=0
    fi
    
    # ── Extract SERVER-SIDE results (--get-server-output) ──
    local srv_json=""
    if echo "$iperf_output" | jq -e '.server_output_json' >/dev/null 2>&1; then
        srv_json=$(echo "$iperf_output" | jq -r '.server_output_json')
        
        if echo "$srv_json" | jq -e '.end' >/dev/null 2>&1; then
            IPERF_SRV_OUTPUT_AVAILABLE="true"
            
            if [ "$IPERF_UDP" = "true" ]; then
                IPERF_SRV_BITS_PER_SEC=$(echo "$srv_json" | jq -r '.end.sum.bits_per_second // 0')
                IPERF_SRV_BYTES_TRANSFERRED=$(echo "$srv_json" | jq -r '.end.sum.bytes // 0')
                IPERF_SRV_JITTER_MS=$(echo "$srv_json" | jq -r '.end.sum.jitter_ms // 0')
                IPERF_SRV_LOST_PACKETS=$(echo "$srv_json" | jq -r '.end.sum.lost_packets // 0')
                IPERF_SRV_LOST_PERCENT=$(echo "$srv_json" | jq -r '.end.sum.lost_percent // 0')
                IPERF_SRV_RETRANSMITS=0
            else
                if [ "$IPERF_REVERSE" = "true" ]; then
                    # Reverse mode: server is the sender
                    IPERF_SRV_BITS_PER_SEC=$(echo "$srv_json" | jq -r '.end.sum_sent.bits_per_second // 0')
                    IPERF_SRV_BYTES_TRANSFERRED=$(echo "$srv_json" | jq -r '.end.sum_sent.bytes // 0')
                    IPERF_SRV_RETRANSMITS=$(echo "$srv_json" | jq -r '.end.sum_sent.retransmits // 0')
                else
                    # Normal mode: server is the receiver
                    IPERF_SRV_BITS_PER_SEC=$(echo "$srv_json" | jq -r '.end.sum_received.bits_per_second // 0')
                    IPERF_SRV_BYTES_TRANSFERRED=$(echo "$srv_json" | jq -r '.end.sum_received.bytes // 0')
                    IPERF_SRV_RETRANSMITS=0
                fi
                IPERF_SRV_JITTER_MS=0
                IPERF_SRV_LOST_PACKETS=0
                IPERF_SRV_LOST_PERCENT=0
            fi
            
            log "   ✅ Server output captured successfully"
        else
            log "   ⚠️  Server output JSON present but could not parse .end"
        fi
    else
        # Fallback: parse text server output (older iperf3 client versions)
        if echo "$iperf_output" | jq -e '.server_output_text' >/dev/null 2>&1; then
            local srv_text=$(echo "$iperf_output" | jq -r '.server_output_text')
            
            # Extract the summary line (ends with "sender" or "receiver")
            # Format: [  5]   0.00-2.00   sec  23.8 MBytes  99.9 Mbits/sec  0.016 ms  0/19254 (0%)  receiver
            local summary_line=$(echo "$srv_text" | grep -E "(sender|receiver)\s*$" | tail -1)
            
            if [ -n "$summary_line" ]; then
                IPERF_SRV_OUTPUT_AVAILABLE="true"
                
                # Extract bitrate (e.g., "99.9 Mbits/sec" or "1.23 Gbits/sec")
                local srv_bitrate=$(echo "$summary_line" | grep -oP '[\d.]+\s+(Mbits|Gbits|Kbits)/sec' | head -1)
                local srv_bitrate_val=$(echo "$srv_bitrate" | awk '{print $1}')
                local srv_bitrate_unit=$(echo "$srv_bitrate" | awk '{print $2}')
                case "$srv_bitrate_unit" in
                    Gbits/sec) IPERF_SRV_BITS_PER_SEC=$(echo "$srv_bitrate_val * 1000000000" | bc) ;;
                    Mbits/sec) IPERF_SRV_BITS_PER_SEC=$(echo "$srv_bitrate_val * 1000000" | bc) ;;
                    Kbits/sec) IPERF_SRV_BITS_PER_SEC=$(echo "$srv_bitrate_val * 1000" | bc) ;;
                    *) IPERF_SRV_BITS_PER_SEC=0 ;;
                esac
                
                # Extract transfer bytes (e.g., "23.8 MBytes")
                local srv_transfer=$(echo "$summary_line" | grep -oP '[\d.]+\s+(MBytes|GBytes|KBytes)' | head -1)
                local srv_transfer_val=$(echo "$srv_transfer" | awk '{print $1}')
                local srv_transfer_unit=$(echo "$srv_transfer" | awk '{print $2}')
                case "$srv_transfer_unit" in
                    GBytes) IPERF_SRV_BYTES_TRANSFERRED=$(echo "$srv_transfer_val * 1073741824" | bc | cut -d. -f1) ;;
                    MBytes) IPERF_SRV_BYTES_TRANSFERRED=$(echo "$srv_transfer_val * 1048576" | bc | cut -d. -f1) ;;
                    KBytes) IPERF_SRV_BYTES_TRANSFERRED=$(echo "$srv_transfer_val * 1024" | bc | cut -d. -f1) ;;
                    *) IPERF_SRV_BYTES_TRANSFERRED=0 ;;
                esac
                
                if [ "$IPERF_UDP" = "true" ]; then
                    # Extract jitter (e.g., "0.016 ms")
                    IPERF_SRV_JITTER_MS=$(echo "$summary_line" | grep -oP '[\d.]+\s+ms' | head -1 | awk '{print $1}')
                    IPERF_SRV_JITTER_MS="${IPERF_SRV_JITTER_MS:-0}"
                    
                    # Extract lost/total (e.g., "0/19254")
                    local lost_total=$(echo "$summary_line" | grep -oP '\d+/\d+' | head -1)
                    IPERF_SRV_LOST_PACKETS=$(echo "$lost_total" | cut -d/ -f1)
                    IPERF_SRV_LOST_PACKETS="${IPERF_SRV_LOST_PACKETS:-0}"
                    
                    # Extract loss percent (e.g., "(0%)" or "(0.27%)")
                    IPERF_SRV_LOST_PERCENT=$(echo "$summary_line" | grep -oP '\([\d.]+%\)' | tr -d '()%')
                    IPERF_SRV_LOST_PERCENT="${IPERF_SRV_LOST_PERCENT:-0}"
                    
                    IPERF_SRV_RETRANSMITS=0
                else
                    # TCP: extract retransmits if present
                    IPERF_SRV_RETRANSMITS=$(echo "$summary_line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/ && $(i+1) ~ /sender/) print $i}')
                    IPERF_SRV_RETRANSMITS="${IPERF_SRV_RETRANSMITS:-0}"
                    IPERF_SRV_JITTER_MS=0
                    IPERF_SRV_LOST_PACKETS=0
                    IPERF_SRV_LOST_PERCENT=0
                fi
                
                log "   ✅ Server output parsed from text (iperf3 client < 3.9 fallback)"
            else
                log "   ⚠️  Server output text received but could not parse summary line"
            fi
        else
            log "   ⚠️  No server output received (server may not support --get-server-output)"
        fi
    fi
    
    IPERF_SUCCESS="true"
    
    # Convert to human readable (client)
    local speed_mbps=$(echo "scale=2; $IPERF_BITS_PER_SEC / 1000000" | bc | sed 's/^\./0./')
    local speed_gbps=$(echo "scale=3; $IPERF_BITS_PER_SEC / 1000000000" | bc | sed 's/^\./0./')
    local bytes_mb=$(echo "scale=2; $IPERF_BYTES_TRANSFERRED / 1048576" | bc | sed 's/^\./0./')
    
    # Convert to human readable (server)
    local srv_speed_mbps="N/A"
    local srv_bytes_mb="N/A"
    if [ "$IPERF_SRV_OUTPUT_AVAILABLE" = "true" ]; then
        srv_speed_mbps=$(echo "scale=2; $IPERF_SRV_BITS_PER_SEC / 1000000" | bc | sed 's/^\./0./')
        srv_bytes_mb=$(echo "scale=2; $IPERF_SRV_BYTES_TRANSFERRED / 1048576" | bc | sed 's/^\./0./')
    fi
    
    # Print results
    printf "   ┌────────────────────────────────────────────────────────────┐\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │         iperf3 TEST RESULTS (%s, %ss)                 │\n" "$mode_desc" "$IPERF_DURATION" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   ├────────────────────────────────────────────────────────────┤\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │ CLIENT-SIDE THROUGHPUT:                                     │\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │   Bitrate:          %12s Mbps                   │\n" "$speed_mbps" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    if (( $(echo "$speed_gbps >= 1" | bc -l) )); then
        printf "   │                     %12s Gbps                   │\n" "$speed_gbps" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    fi
    printf "   │   Data Transferred: %12s MB                     │\n" "$bytes_mb" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   ├────────────────────────────────────────────────────────────┤\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    
    # Server-side throughput (if available)
    if [ "$IPERF_SRV_OUTPUT_AVAILABLE" = "true" ]; then
        printf "   │ SERVER-SIDE THROUGHPUT:                                     │\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
        printf "   │   Bitrate:          %12s Mbps                   │\n" "$srv_speed_mbps" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
        printf "   │   Data Transferred: %12s MB                     │\n" "$srv_bytes_mb" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
        printf "   ├────────────────────────────────────────────────────────────┤\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    fi
    
    if [ "$IPERF_UDP" = "true" ]; then
        printf "   │ UDP METRICS (client):                                      │\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
        printf "   │   Jitter:           %12s ms                    │\n" "$IPERF_JITTER_MS" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
        printf "   │   Lost Packets:     %12d (%.2f%%)               │\n" "$IPERF_LOST_PACKETS" "$IPERF_LOST_PERCENT" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
        if [ "$IPERF_SRV_OUTPUT_AVAILABLE" = "true" ]; then
            printf "   │ UDP METRICS (server):                                      │\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
            printf "   │   Jitter:           %12s ms                    │\n" "$IPERF_SRV_JITTER_MS" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
            printf "   │   Lost Packets:     %12d (%.2f%%)               │\n" "$IPERF_SRV_LOST_PACKETS" "$IPERF_SRV_LOST_PERCENT" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
        fi
    else
        printf "   │ TCP METRICS (client):                                      │\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
        printf "   │   Retransmits:      %12d                       │\n" "$IPERF_RETRANSMITS" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
        if [ "$IPERF_SRV_OUTPUT_AVAILABLE" = "true" ] && [ "$IPERF_REVERSE" = "true" ]; then
            printf "   │ TCP METRICS (server/sender):                               │\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
            printf "   │   Retransmits:      %12d                       │\n" "$IPERF_SRV_RETRANSMITS" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
        fi
    fi
    
    printf "   ├────────────────────────────────────────────────────────────┤\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │ STREAMING QUALITY ESTIMATE:                                │\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │   Quality:          %-35s │\n" "$(get_streaming_quality "$speed_mbps")" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   └────────────────────────────────────────────────────────────┘\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    
    log "   ✅ iperf3 test complete: client=${speed_mbps} Mbps, server=${srv_speed_mbps} Mbps, ${bytes_mb} MB transferred"
    return 0
}

# ============================================================================
# Web Page Loading Test Functions (Browsertime-based, updated in v3.3.0)
# ============================================================================

# Run Browsertime for a single URL inside PacketRusher's network namespace.
# Policy routing rules forward all non-infrastructure traffic through the GTP VRF.
# Results (TTFB, FCP, LCP, DCL, page load in ms) are stored in the nameref array.
test_single_webpage() {
    local url=$1
    local site_name=$2
    local pr_pid=$3
    local vrf_name=$4
    local bt_output_dir=$5
    local -n _wp_result=$6   # nameref to caller's associative array

    # Reset results
    _wp_result[success]="false"
    _wp_result[ttfb_ms]=0
    _wp_result[fcp_ms]=0
    _wp_result[lcp_ms]=0
    _wp_result[dcl_ms]=0
    _wp_result[page_load_ms]=0

    local site_output_dir="$bt_output_dir/$(echo "$site_name" | tr '/:' '_')"
    mkdir -p "$site_output_dir"

    # Browser-specific extra arguments.
    #   Firefox: disable IPv6 DNS (may not traverse the GTP tunnel).
    #   Chrome/Edge (Chromium): need --no-sandbox to run inside the container,
    #   and we disable IPv6 at the browser level via host-resolver rules.
    local extra_args=""
    case "$WEBPAGE_BROWSER" in
        firefox) extra_args="--firefox.preference network.dns.disableIPv6:true" ;;
        chrome)  extra_args="--chrome.args no-sandbox --chrome.args disable-ipv6" ;;
        edge)    extra_args="--edge.args no-sandbox --edge.args disable-ipv6" ;;
    esac

    log "      Launching Browsertime for $site_name ($url)..."
    log "      Browser: $WEBPAGE_BROWSER  Iterations: $WEBPAGE_ITERATIONS  VRF: $vrf_name"

    local bt_exit_code
    set +e
    sudo docker run --rm \
        --name "$BT_CONTAINER" \
        --net container:"$PR_CONTAINER" \
        --cap-add NET_ADMIN \
        -v "$site_output_dir":/browsertime \
        --entrypoint /bin/sh \
        "$BT_IMAGE" \
        -c "
            VRF_TABLE=\$(ip -d link show $vrf_name 2>/dev/null | grep -oP 'table \K[0-9]+')
            if [ -z \"\$VRF_TABLE\" ]; then
                echo 'ERROR: could not determine VRF table for $vrf_name' >&2
                exit 1
            fi
            # Point the browser at a resolver reachable through the tunnel. The
            # container otherwise inherits the host's resolvers, which are
            # typically site-local and get routed into the tunnel by the
            # priority-50 rule below, where they do not exist — every lookup then
            # hangs until browsertime's page timeout and no page ever loads.
            : > /etc/resolv.conf
            for ns in $BT_DNS_SERVERS; do
                echo \"nameserver \$ns\" >> /etc/resolv.conf
            done
            # Drop anything left at our priorities by an interrupted run. Deleting
            # by priority also clears the hardcoded-subnet rules written by older
            # versions. Priorities 5, 6 and 50 are used only here; the kernel
            # defaults are 0/32766/32767. Runs before the lookup below so that
            # lookup sees the unmodified main-table routing.
            for p in 5 6 50; do
                while ip rule del priority \$p 2>/dev/null; do :; done
            done
            _cleanup() {
                for p in 5 6 50; do
                    while ip rule del priority \$p 2>/dev/null; do :; done
                done
            }
            trap _cleanup EXIT

            # The gNB's GTP-U source address, read from the live socket bind (we
            # share PacketRusher's netns, so its sockets are visible here). Never
            # hardcoded: every deployment addresses its gNB differently.
            PR_SRC=\$(ss -unaH 2>/dev/null | awk '\$4 ~ /:2152\$/ {sub(/:2152\$/,\"\",\$4); print \$4; exit}')
            case \"\$PR_SRC\" in
                \"\"|0.0.0.0|*[!0-9.]*) PR_SRC=\"\" ;;
            esac
            if [ -z \"\$PR_SRC\" ]; then
                PR_IFACE=\$(ip -o route show table main default | grep -oP 'dev \K\S+' | head -1)
                PR_SRC=\$(ip -4 -o addr show dev \"\$PR_IFACE\" 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -1)
            fi
            if [ -z \"\$PR_SRC\" ]; then
                echo 'ERROR: could not determine the gNB GTP-U source address.' >&2
                echo 'Without it the tunnel encapsulation would be routed into' >&2
                echo 'the tunnel itself. Refusing to continue.' >&2
                exit 1
            fi

            # Split routing, deriving every value at runtime:
            #   priority 5   PacketRusher's own traffic (GTP-U to the UPF, NGAP to
            #                the AMF) is sourced from \$PR_SRC and must keep using
            #                the host network. The UPF's N3 endpoint is typically
            #                reachable only via this namespace's default route, so
            #                without this the next rule would route the tunnel's own
            #                encapsulation back into the tunnel: a loop that shows
            #                up as TX errors on the val interface and passes no
            #                traffic.
            #   priority 6   anything with a specific route (link subnets, docker
            #                bridges) stays local; main's default route is
            #                suppressed so it cannot swallow internet traffic.
            #   priority 50  everything else — the internet — goes to the VRF table
            #                and out through the tunnel. The browser's sockets are
            #                unbound, so they have no source address at lookup time,
            #                miss the priority 5 rule, and land here as intended.
            ip rule add from \$PR_SRC lookup main priority 5
            ip rule add from all lookup main suppress_prefixlength 0 priority 6
            ip rule add from all lookup \$VRF_TABLE priority 50
            /start.sh \
                --browser $WEBPAGE_BROWSER \
                $extra_args \
                --iterations $WEBPAGE_ITERATIONS \
                --video false \
                --visualMetrics false \
                '$url'
        " 2>&1
    bt_exit_code=$?
    set -e

    if [ $bt_exit_code -ne 0 ]; then
        log "      ❌ Browsertime exited with code $bt_exit_code for $site_name"
        return 1
    fi

    # Locate the browsertime.json written by the container
    local bt_json
    bt_json=$(find "$site_output_dir" -name "browsertime.json" 2>/dev/null | head -1)
    if [ -z "$bt_json" ] || [ ! -f "$bt_json" ]; then
        log "      ❌ No browsertime.json found for $site_name"
        return 1
    fi

    # Parse median timings from Browsertime JSON (all values in ms)
    local ttfb fcp lcp dcl page_load total
    ttfb=$(jq -r '.[0].statistics.timings.ttfb.median // 0' "$bt_json" 2>/dev/null || echo 0)
    fcp=$(jq -r '.[0].statistics.timings.paintTiming."first-contentful-paint".median // .[0].statistics.timings.timeToContentfulPaint.median // 0' "$bt_json" 2>/dev/null || echo 0)
    lcp=$(jq -r '.[0].statistics.timings.largestContentfulPaint.renderTime.median // .[0].statistics.timings.largestContentfulPaint.loadTime.median // 0' "$bt_json" 2>/dev/null || echo 0)
    dcl=$(jq -r '.[0].statistics.timings.pageTimings.domContentLoadedTime.median // 0' "$bt_json" 2>/dev/null || echo 0)
    # Page Load = standard loadEventEnd (pageLoadTime), the value Browsertime
    # prints in its own "Load:" summary line. fullyLoaded (network-idle) is only
    # a fallback — it inflates to 10s+ on pages with background traffic.
    page_load=$(jq -r '
        .[0].statistics.timings.pageTimings.pageLoadTime.median //
        .[0].statistics.timings.fullyLoaded.median //
        0' "$bt_json" 2>/dev/null || echo 0)
    # Total Time = fullyLoaded (navigation start → network fully idle): the whole
    # page-load span from first step to last. Falls back to pageLoadTime.
    total=$(jq -r '
        .[0].statistics.timings.fullyLoaded.median //
        .[0].statistics.timings.pageTimings.pageLoadTime.median //
        0' "$bt_json" 2>/dev/null || echo 0)

    _wp_result[success]="true"
    _wp_result[ttfb_ms]="${ttfb:-0}"
    _wp_result[fcp_ms]="${fcp:-0}"
    _wp_result[lcp_ms]="${lcp:-0}"
    _wp_result[dcl_ms]="${dcl:-0}"
    _wp_result[page_load_ms]="${page_load:-0}"
    _wp_result[total_ms]="${total:-0}"

    log "      ✅ $site_name: TTFB=${ttfb}ms  FCP=${fcp}ms  LCP=${lcp}ms  DCL=${dcl}ms  Load=${page_load}ms  Total=${total}ms"
    return 0
}

perform_webpage_test() {
    local ue_ip=$1
    local vrf=$2

    if [ "$WEBPAGE_TEST_ENABLED" != "true" ]; then
        return 0
    fi

    if [ ${#WEBPAGE_URLS[@]} -eq 0 ]; then
        log "   ⚠️  Webpage test enabled but WEBPAGE_URLS is empty, skipping"
        return 0
    fi

    log ""
    log "   🌐 Running Browsertime Web Page Loading Tests..."
    log "   📋 Browser: $WEBPAGE_BROWSER | Iterations per URL: $WEBPAGE_ITERATIONS | URLs: ${#WEBPAGE_URLS[@]}"

    # Obtain PacketRusher container PID for nsenter
    local pr_pid
    pr_pid=$(sudo docker inspect -f '{{.State.Pid}}' "$PR_CONTAINER" 2>/dev/null || echo "")
    if [ -z "$pr_pid" ] || [ "$pr_pid" = "0" ]; then
        log "   ❌ Cannot get PacketRusher container PID, skipping webpage tests"
        return 1
    fi

    # ── Enable VRF l3mdev socket acceptance ──────────────────────────────────
    # Without this, unbound sockets (Firefox/Chrome) cannot match TCP/UDP
    # replies arriving on the VRF slave interface, causing immediate RST.
    local orig_tcp orig_udp
    orig_tcp=$(sudo nsenter --net=/proc/"$pr_pid"/ns/net -- \
        sysctl -n net.ipv4.tcp_l3mdev_accept 2>/dev/null || echo 0)
    orig_udp=$(sudo nsenter --net=/proc/"$pr_pid"/ns/net -- \
        sysctl -n net.ipv4.udp_l3mdev_accept 2>/dev/null || echo 0)
    sudo nsenter --net=/proc/"$pr_pid"/ns/net -- \
        sysctl -w net.ipv4.tcp_l3mdev_accept=1 >/dev/null
    sudo nsenter --net=/proc/"$pr_pid"/ns/net -- \
        sysctl -w net.ipv4.udp_l3mdev_accept=1 >/dev/null
    log "   ✅ VRF l3mdev accept: enabled (was tcp=$orig_tcp udp=$orig_udp)"

    # ── Detect VRF name inside the PacketRusher container ────────────────────
    # $vrf (= $PR_VRF) is already the VRF name; verify it's visible inside container
    local vrf_name="$vrf"

    # ── Browsertime output directory ─────────────────────────────────────────
    local bt_output_dir="$LOG_DIR/browsertime_${TIMESTAMP}"
    mkdir -p "$bt_output_dir"

    WEBPAGE_TEST_RESULTS=()

    local total=${#WEBPAGE_URLS[@]}
    local count=0

    for url in "${WEBPAGE_URLS[@]}"; do
        count=$((count + 1))
        # Derive a short display name from the hostname
        local site_name
        site_name=$(echo "$url" | grep -oP '(?<=[a-z]://)([^/?]+)' | head -1)
        site_name="${site_name:-url_$count}"

        log ""
        log "   [$count/$total] $site_name"

        declare -A _wpt_res
        _wpt_res[success]="false"
        _wpt_res[ttfb_ms]=0
        _wpt_res[fcp_ms]=0
        _wpt_res[lcp_ms]=0
        _wpt_res[dcl_ms]=0
        _wpt_res[page_load_ms]=0
        _wpt_res[total_ms]=0

        test_single_webpage "$url" "$site_name" "$pr_pid" "$vrf_name" "$bt_output_dir" _wpt_res

        # Escape URL for JSON (basic: replace " with \")
        local url_esc="${url//\"/\\\"}"
        local sn_esc="${site_name//\"/\\\"}"
        WEBPAGE_TEST_RESULTS+=("{\"url\":\"${url_esc}\",\"site_name\":\"${sn_esc}\",\"success\":${_wpt_res[success]},\"ttfb_ms\":${_wpt_res[ttfb_ms]},\"fcp_ms\":${_wpt_res[fcp_ms]},\"lcp_ms\":${_wpt_res[lcp_ms]},\"dcl_ms\":${_wpt_res[dcl_ms]},\"page_load_ms\":${_wpt_res[page_load_ms]},\"total_ms\":${_wpt_res[total_ms]}}")
        unset _wpt_res

        # Brief pause between URLs to avoid overloading the connection
        [ "$count" -lt "$total" ] && sleep 2
    done

    # ── Restore l3mdev ────────────────────────────────────────────────────────
    sudo nsenter --net=/proc/"$pr_pid"/ns/net -- \
        sysctl -w net.ipv4.tcp_l3mdev_accept="$orig_tcp" >/dev/null 2>&1 || true
    sudo nsenter --net=/proc/"$pr_pid"/ns/net -- \
        sysctl -w net.ipv4.udp_l3mdev_accept="$orig_udp" >/dev/null 2>&1 || true
    log "   ✅ VRF l3mdev accept: restored (tcp=$orig_tcp udp=$orig_udp)"

    # ── Print summary table ───────────────────────────────────────────────────
    log ""
    printf "   ┌──────────────────────────────────────┬──────┬──────┬──────┬──────┬──────────┬──────────┐\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │  %-36s │ TTFB │ FCP  │ LCP  │ DCL  │ PageLoad │  Total   │\n" "URL / Hostname" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   │  %-36s │ (ms) │ (ms) │ (ms) │ (ms) │ (ms)     │ (ms)     │\n" "" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    printf "   ├──────────────────────────────────────┼──────┼──────┼──────┼──────┼──────────┼──────────┤\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"

    for r_json in "${WEBPAGE_TEST_RESULTS[@]}"; do
        local _sn _suc _ttfb _fcp _lcp _dcl _load _total _icon
        _sn=$(echo "$r_json"   | jq -r '.site_name')
        _suc=$(echo "$r_json"  | jq -r '.success')
        _ttfb=$(echo "$r_json" | jq -r '.ttfb_ms')
        _fcp=$(echo "$r_json"  | jq -r '.fcp_ms')
        _lcp=$(echo "$r_json"  | jq -r '.lcp_ms')
        _dcl=$(echo "$r_json"  | jq -r '.dcl_ms')
        _load=$(echo "$r_json" | jq -r '.page_load_ms')
        _total=$(echo "$r_json" | jq -r '.total_ms // 0')
        [ "$_suc" = "true" ] && _icon="✓" || _icon="✗"
        printf "   │ %s %-35s │ %4s │ %4s │ %4s │ %4s │ %8s │ %8s │\n" \
            "$_icon" "$_sn" "$_ttfb" "$_fcp" "$_lcp" "$_dcl" "$_load" "$_total" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    done

    printf "   └──────────────────────────────────────┴──────┴──────┴──────┴──────┴──────────┴──────────┘\n" | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    log ""
    log "   ✅ Webpage tests done. Raw Browsertime results: $bt_output_dir"
    return 0
}

stop_packetrusher() {
    cleanup_packetrusher_fast
}
