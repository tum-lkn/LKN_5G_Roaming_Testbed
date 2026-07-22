#!/bin/bash
# lib/automation/results.sh
# JSON results file management (init, per-iteration append, summary
# aggregation, formatted print), the main batch iteration loop, log/results
# file pruning, and the EXIT trap cleanup function.

init_results() {
    # Ensure all required variables have defaults
    PING_COUNT="${PING_COUNT:-10}"
    PING_TARGET="${PING_TARGET:-8.8.8.8}"
    PING_INTERVAL="${PING_INTERVAL:-1}"
    ITERATIONS="${ITERATIONS:-5}"
    TESTBED_RESTART_INTERVAL="${TESTBED_RESTART_INTERVAL:-0}"
    NETWORK_READY_TIMEOUT="${NETWORK_READY_TIMEOUT:-30}"
    SERVICE_CHECK_INTERVAL="${SERVICE_CHECK_INTERVAL:-1}"
    IPSEC_ESTABLISH_TIMEOUT="${IPSEC_ESTABLISH_TIMEOUT:-10}"
    MIN_NETWORK_STABILIZE_TIME="${MIN_NETWORK_STABILIZE_TIME:-10}"

    # Set results file if not already set (e.g. interactive mode bypasses load_config)
    if [ -z "$BATCH_RESULTS_FILE" ]; then
        mkdir -p "$RESULTS_DIR"
        BATCH_RESULTS_FILE="$RESULTS_DIR/batch_results_${TIMESTAMP}.json"
    fi
    
    local delay_json="{}"
    if [ ${#DELAY_CONFIGS[@]} -gt 0 ]; then
        delay_json='{'; local first=true
        for key in "${!DELAY_CONFIGS[@]}"; do
            [ "$first" = true ] && first=false || delay_json+=','
            delay_json+="\"$key\": \"${DELAY_CONFIGS[$key]}\""
        done
        delay_json+='}'
    fi
    
    local ping_payload_json="null"
    [ -n "$PING_PAYLOAD_SIZE" ] && ping_payload_json="$PING_PAYLOAD_SIZE"
    
    local ipsec_mode_json="null"
    [ -n "$IPSEC_MODE" ] && ipsec_mode_json="$IPSEC_MODE"
    
    local ipsec_mode_name_json="null"
    [ -n "$IPSEC_MODE" ] && ipsec_mode_name_json="\"${IPSEC_MODE_NAMES[$IPSEC_MODE]}\""
    
    local download_url_json="null"
    [ -n "$DOWNLOAD_TEST_URL" ] && download_url_json="\"$DOWNLOAD_TEST_URL\""
    
    local download_size_label_json="null"
    [ -n "$DOWNLOAD_TEST_SIZE_LABEL" ] && download_size_label_json="\"$DOWNLOAD_TEST_SIZE_LABEL\""
    
    local video_url_json="null"
    [ -n "$VIDEO_TEST_URL" ] && video_url_json="\"$VIDEO_TEST_URL\""
    
    local video_size_label_json="null"
    [ -n "$VIDEO_TEST_SIZE_LABEL" ] && video_size_label_json="\"$VIDEO_TEST_SIZE_LABEL\""
    
    local iperf_server_json="null"
    [ -n "$IPERF_SERVER_IP" ] && iperf_server_json="\"$IPERF_SERVER_IP:$IPERF_SERVER_PORT\""
    
    local iperf_bandwidth_json="null"
    [ -n "$IPERF_BANDWIDTH" ] && iperf_bandwidth_json="\"$IPERF_BANDWIDTH\""
    
    # Build webpage_test config JSON: list of URLs
    local webpage_urls_json="[]"
    if [ ${#WEBPAGE_URLS[@]} -gt 0 ]; then
        webpage_urls_json="["
        local _wu_first=true
        for _wu in "${WEBPAGE_URLS[@]}"; do
            $_wu_first && _wu_first=false || webpage_urls_json+=","
            webpage_urls_json+="\"${_wu//\"/\\\"}\""
        done
        webpage_urls_json+="]"
    fi
    local roaming_mode_name="${ROAMING_MODE_NAMES[$ROAMING_MODE]:-$ROAMING_MODE}"
    local vplmn_name_json="null"
    [ -n "$VPLMN_NAME" ] && vplmn_name_json="\"$VPLMN_NAME\""
    local dn_location_json="null"
    [ -n "$DN_LOCATION" ] && dn_location_json="\"$DN_LOCATION\""
    local dn_latency_json="null"
    [ -n "$DN_LATENCY" ] && dn_latency_json="\"$DN_LATENCY\""
    local dn_jitter_json="null"
    [ -n "$DN_JITTER" ] && dn_jitter_json="\"$DN_JITTER\""
    
    local n6_delay_value_json="null"
    [ -n "$N6_DELAY_VALUE" ] && n6_delay_value_json="\"$N6_DELAY_VALUE\""
    
    local n6_delay_jitter_json="null"
    [ -n "$N6_DELAY_JITTER" ] && n6_delay_jitter_json="\"$N6_DELAY_JITTER\""
    
    cat > "$BATCH_RESULTS_FILE" <<EOF
{
  "test_info": {
    "timestamp": "$TIMESTAMP",
    "script_version": "$SCRIPT_VERSION",
    "config_file_mode": $CONFIG_FILE_MODE,
    "config_file": "${CONFIG_FILE_PATH:-null}",
    "roaming_mode": "$ROAMING_MODE",
    "roaming_mode_name": "$roaming_mode_name",
    "vplmn_name": $vplmn_name_json,
    "dn_location": $dn_location_json,
    "dn_latency": $dn_latency_json,
    "dn_jitter": $dn_jitter_json,
    "n9_ipsec_enabled": $IPSEC_ENABLED,
    "n9_ipsec_mode": $ipsec_mode_json,
    "n9_ipsec_mode_name": $ipsec_mode_name_json,
    "local_security": "$SECURITY_MODE",
    "remote_security": "${REMOTE_SECURITY_MODE:-none}",
    "iterations": $ITERATIONS,
    "testbed_restart_interval": $TESTBED_RESTART_INTERVAL,
    "delay_enabled": $DELAY_ENABLED,
    "delay_configs": $delay_json,
    "n6_delay": {
      "enabled": $N6_DELAY_ENABLED,
      "value": $n6_delay_value_json,
      "jitter": $n6_delay_jitter_json,
      "ogstun_location": "$([ "$ROAMING_MODE" = "hr" ] && echo "remote" || echo "local")",
      "server_ip": "$SERVER_IP",
      "server_interface": "$SERVER_INTERFACE"
    },
    "server": {
      "ip": "$SERVER_IP",
      "user": "$SERVER_USER",
      "interface": "$SERVER_INTERFACE"
    },
    "ping_test": {
      "enabled": $PING_TEST_ENABLED,
      "count": $PING_COUNT,
      "target": "$PING_TARGET",
      "interval": $PING_INTERVAL,
      "payload_size": $ping_payload_json
    },
    "download_test": {
      "enabled": $DOWNLOAD_TEST_ENABLED,
      "url": $download_url_json,
      "size_label": $download_size_label_json
    },
    "video_test": {
      "enabled": $VIDEO_TEST_ENABLED,
      "url": $video_url_json,
      "size_label": $video_size_label_json
    },
    "iperf_test": {
      "enabled": $IPERF_TEST_ENABLED,
      "server": $iperf_server_json,
      "duration_sec": $IPERF_DURATION,
      "parallel_streams": $IPERF_PARALLEL,
      "reverse_mode": $IPERF_REVERSE,
      "udp_mode": $IPERF_UDP,
      "target_bandwidth": $iperf_bandwidth_json
    },
    "webpage_test": {
      "enabled": $WEBPAGE_TEST_ENABLED,
      "browser": "$WEBPAGE_BROWSER",
      "iterations_per_url": $WEBPAGE_ITERATIONS,
      "timeout_sec": $WEBPAGE_TIMEOUT,
      "urls": $webpage_urls_json
    },
    "performance_settings": {
      "network_ready_timeout": $NETWORK_READY_TIMEOUT,
      "service_check_interval": $SERVICE_CHECK_INTERVAL,
      "ipsec_establish_timeout": $IPSEC_ESTABLISH_TIMEOUT,
      "min_network_stabilize_time": $MIN_NETWORK_STABILIZE_TIME
    }
  },
  "iterations": [],
  "summary": {}
}
EOF
}

add_iteration_result() {
    local iteration=$1 status=$2
    local iter_json
    
    # Build ping results JSON if ping test was performed
    local ping_json="null"
    if [ "$PING_TEST_ENABLED" = "true" ] && [ "$status" = "success" ]; then
        ping_json="{\"total\":$PING_COUNT,\"successful\":$PING_SUCCESS,\"failed\":$PING_FAIL,\"packet_loss_percent\":$PING_LOSS,\"min_ms\":$PING_MIN,\"max_ms\":$PING_MAX,\"avg_ms\":$PING_AVG}"
    fi
    
    # Build download results JSON if download test was performed
    local download_json="null"
    if [ "$DOWNLOAD_TEST_ENABLED" = "true" ] && [ "$status" = "success" ]; then
        if [ "$DL_SUCCESS" = "true" ]; then
            download_json=$(cat <<DLJSON
{"success":true,"size_bytes":$DL_SIZE_BYTES,"speed_bytes_per_sec":$DL_SPEED_BPS,"time_dns_sec":$DL_TIME_DNS,"time_connect_sec":$DL_TIME_CONNECT,"time_tls_sec":$DL_TIME_TLS,"time_ttfb_sec":$DL_TIME_TTFB,"time_total_sec":$DL_TIME_TOTAL,"remote_ip":"$DL_REMOTE_IP","http_code":$DL_HTTP_CODE}
DLJSON
)
        else
            download_json='{"success":false,"error":"download_failed"}'
        fi
    fi
    
    # Build video test results JSON if video test was performed
    local video_json="null"
    if [ "$VIDEO_TEST_ENABLED" = "true" ] && [ "$status" = "success" ]; then
        if [ "$VID_SUCCESS" = "true" ]; then
            video_json=$(cat <<VIDJSON
{"success":true,"size_bytes":$VID_SIZE_BYTES,"speed_bytes_per_sec":$VID_SPEED_BPS,"streaming_mbps":$VID_STREAMING_MBPS,"time_dns_sec":$VID_TIME_DNS,"time_connect_sec":$VID_TIME_CONNECT,"time_ttfb_sec":$VID_TIME_TTFB,"time_total_sec":$VID_TIME_TOTAL,"remote_ip":"$VID_REMOTE_IP","http_code":$VID_HTTP_CODE}
VIDJSON
)
        else
            video_json='{"success":false,"error":"video_test_failed"}'
        fi
    fi
    
    # Build iperf3 test results JSON if iperf3 test was performed
    local iperf_json="null"
    if [ "$IPERF_TEST_ENABLED" = "true" ] && [ "$status" = "success" ]; then
        if [ "$IPERF_SUCCESS" = "true" ]; then
            # Build server output JSON block
            local srv_json_block="null"
            if [ "$IPERF_SRV_OUTPUT_AVAILABLE" = "true" ]; then
                srv_json_block=$(cat <<SRVJSON
{"bits_per_second":$IPERF_SRV_BITS_PER_SEC,"bytes_transferred":$IPERF_SRV_BYTES_TRANSFERRED,"retransmits":$IPERF_SRV_RETRANSMITS,"jitter_ms":$IPERF_SRV_JITTER_MS,"lost_packets":$IPERF_SRV_LOST_PACKETS,"lost_percent":$IPERF_SRV_LOST_PERCENT}
SRVJSON
)
            fi
            
            iperf_json=$(cat <<IPERFJSON
{"success":true,"bits_per_second":$IPERF_BITS_PER_SEC,"bytes_transferred":$IPERF_BYTES_TRANSFERRED,"retransmits":$IPERF_RETRANSMITS,"jitter_ms":$IPERF_JITTER_MS,"lost_packets":$IPERF_LOST_PACKETS,"lost_percent":$IPERF_LOST_PERCENT,"protocol":"$([ "$IPERF_UDP" = "true" ] && echo "udp" || echo "tcp")","reverse_mode":$IPERF_REVERSE,"server_output_available":$IPERF_SRV_OUTPUT_AVAILABLE,"server_output":$srv_json_block}
IPERFJSON
)
        else
            iperf_json='{"success":false,"error":"iperf_test_failed"}'
        fi
    fi
    
    # Build webpage test results JSON: array of per-URL objects
    local webpage_json="null"
    if [ "$WEBPAGE_TEST_ENABLED" = "true" ] && [ "$status" = "success" ]; then
        if [ ${#WEBPAGE_TEST_RESULTS[@]} -gt 0 ]; then
            webpage_json="["
            local _wfirst=true
            for _wr in "${WEBPAGE_TEST_RESULTS[@]}"; do
                $_wfirst && _wfirst=false || webpage_json+=","
                webpage_json+="$_wr"
            done
            webpage_json+="]"
        else
            webpage_json="[]"
        fi
    fi
    
    if [ "$status" = "success" ]; then
        iter_json=$(cat <<EOJSON
{"iteration":$iteration,"timestamp":"$(date -Iseconds)","status":"success","ue_ip":"$PR_UE_IP","vrf":"$PR_VRF","timing_ms":{"total":${PR_TOTAL_MS:-null},"startup_to_registration":${PR_STARTUP_TO_REG_MS:-null},"registration_to_pdu_init":${PR_REG_TO_PDU_INIT_MS:-null},"pdu_setup":${PR_PDU_SETUP_MS:-null}},"ping_results":$ping_json,"download_results":$download_json,"video_results":$video_json,"iperf_results":$iperf_json,"webpage_results":$webpage_json}
EOJSON
)
    else
        iter_json=$(cat <<EOJSON
{"iteration":$iteration,"timestamp":"$(date -Iseconds)","status":"failed","error":"$PR_ERROR","timing_ms":{"total":null,"startup_to_registration":null,"registration_to_pdu_init":null,"pdu_setup":null},"ping_results":null,"download_results":null,"video_results":null,"iperf_results":null,"webpage_results":null}
EOJSON
)
    fi
    jq ".iterations += [$iter_json]" "$BATCH_RESULTS_FILE" > "${BATCH_RESULTS_FILE}.tmp" && mv "${BATCH_RESULTS_FILE}.tmp" "$BATCH_RESULTS_FILE"
}

add_summary() {
    local summary=$(jq '{
        total_iterations: .test_info.iterations,
        successful_iterations: [.iterations[] | select(.status == "success")] | length,
        failed_iterations: [.iterations[] | select(.status != "success")] | length,
        timing_total_ms: {
            min: ([.iterations[] | select(.status == "success") | .timing_ms.total] | min // 0),
            max: ([.iterations[] | select(.status == "success") | .timing_ms.total] | max // 0),
            avg: (([.iterations[] | select(.status == "success") | .timing_ms.total] | add // 0) / ([.iterations[] | select(.status == "success")] | length | if . == 0 then 1 else . end)),
            all_values: [.iterations[] | select(.status == "success") | .timing_ms.total]
        },
        timing_startup_to_registration_ms: {
            min: ([.iterations[] | select(.status == "success") | .timing_ms.startup_to_registration | select(. != null)] | min // 0),
            max: ([.iterations[] | select(.status == "success") | .timing_ms.startup_to_registration | select(. != null)] | max // 0),
            avg: (([.iterations[] | select(.status == "success") | .timing_ms.startup_to_registration | select(. != null)] | add // 0) / ([.iterations[] | select(.status == "success") | .timing_ms.startup_to_registration | select(. != null)] | length | if . == 0 then 1 else . end))
        },
        timing_registration_to_pdu_init_ms: {
            min: ([.iterations[] | select(.status == "success") | .timing_ms.registration_to_pdu_init | select(. != null)] | min // 0),
            max: ([.iterations[] | select(.status == "success") | .timing_ms.registration_to_pdu_init | select(. != null)] | max // 0),
            avg: (([.iterations[] | select(.status == "success") | .timing_ms.registration_to_pdu_init | select(. != null)] | add // 0) / ([.iterations[] | select(.status == "success") | .timing_ms.registration_to_pdu_init | select(. != null)] | length | if . == 0 then 1 else . end))
        },
        timing_pdu_setup_ms: {
            min: ([.iterations[] | select(.status == "success") | .timing_ms.pdu_setup | select(. != null)] | min // 0),
            max: ([.iterations[] | select(.status == "success") | .timing_ms.pdu_setup | select(. != null)] | max // 0),
            avg: (([.iterations[] | select(.status == "success") | .timing_ms.pdu_setup | select(. != null)] | add // 0) / ([.iterations[] | select(.status == "success") | .timing_ms.pdu_setup | select(. != null)] | length | if . == 0 then 1 else . end))
        },
        total_pings: ([.iterations[] | select(.status == "success") | .ping_results.total] | add // 0),
        successful_pings: ([.iterations[] | select(.status == "success") | .ping_results.successful] | add // 0),
        overall_packet_loss: (([.iterations[] | select(.status == "success") | .ping_results.failed] | add // 0) / ([.iterations[] | select(.status == "success") | .ping_results.total] | add // 1) * 100),
        ping_rtt_ms: {
            min: ([.iterations[] | select(.status == "success") | .ping_results.min_ms | select(. > 0)] | min // 0),
            max: ([.iterations[] | select(.status == "success") | .ping_results.max_ms] | max // 0),
            avg: (([.iterations[] | select(.status == "success") | .ping_results.avg_ms] | add // 0) / ([.iterations[] | select(.status == "success")] | length | if . == 0 then 1 else . end))
        },
        download_test: {
            successful_downloads: ([.iterations[] | select(.status == "success") | .download_results | select(. != null and .success == true)] | length),
            failed_downloads: ([.iterations[] | select(.status == "success") | .download_results | select(. != null and .success == false)] | length),
            total_bytes: ([.iterations[] | select(.status == "success") | .download_results | select(. != null and .success == true) | .size_bytes] | add // 0),
            speed_bytes_per_sec: {
                min: ([.iterations[] | select(.status == "success") | .download_results | select(. != null and .success == true) | .speed_bytes_per_sec] | min // 0),
                max: ([.iterations[] | select(.status == "success") | .download_results | select(. != null and .success == true) | .speed_bytes_per_sec] | max // 0),
                avg: (([.iterations[] | select(.status == "success") | .download_results | select(. != null and .success == true) | .speed_bytes_per_sec] | add // 0) / ([.iterations[] | select(.status == "success") | .download_results | select(. != null and .success == true)] | length | if . == 0 then 1 else . end))
            },
            time_total_sec: {
                min: ([.iterations[] | select(.status == "success") | .download_results | select(. != null and .success == true) | .time_total_sec] | min // 0),
                max: ([.iterations[] | select(.status == "success") | .download_results | select(. != null and .success == true) | .time_total_sec] | max // 0),
                avg: (([.iterations[] | select(.status == "success") | .download_results | select(. != null and .success == true) | .time_total_sec] | add // 0) / ([.iterations[] | select(.status == "success") | .download_results | select(. != null and .success == true)] | length | if . == 0 then 1 else . end))
            }
        },
        video_test: {
            successful_tests: ([.iterations[] | select(.status == "success") | .video_results | select(. != null and .success == true)] | length),
            failed_tests: ([.iterations[] | select(.status == "success") | .video_results | select(. != null and .success == false)] | length),
            total_bytes: ([.iterations[] | select(.status == "success") | .video_results | select(. != null and .success == true) | .size_bytes] | add // 0),
            speed_bytes_per_sec: {
                min: ([.iterations[] | select(.status == "success") | .video_results | select(. != null and .success == true) | .speed_bytes_per_sec] | min // 0),
                max: ([.iterations[] | select(.status == "success") | .video_results | select(. != null and .success == true) | .speed_bytes_per_sec] | max // 0),
                avg: (([.iterations[] | select(.status == "success") | .video_results | select(. != null and .success == true) | .speed_bytes_per_sec] | add // 0) / ([.iterations[] | select(.status == "success") | .video_results | select(. != null and .success == true)] | length | if . == 0 then 1 else . end))
            },
            streaming_mbps: {
                min: ([.iterations[] | select(.status == "success") | .video_results | select(. != null and .success == true) | .streaming_mbps] | min // 0),
                max: ([.iterations[] | select(.status == "success") | .video_results | select(. != null and .success == true) | .streaming_mbps] | max // 0),
                avg: (([.iterations[] | select(.status == "success") | .video_results | select(. != null and .success == true) | .streaming_mbps] | add // 0) / ([.iterations[] | select(.status == "success") | .video_results | select(. != null and .success == true)] | length | if . == 0 then 1 else . end))
            },
            time_total_sec: {
                min: ([.iterations[] | select(.status == "success") | .video_results | select(. != null and .success == true) | .time_total_sec] | min // 0),
                max: ([.iterations[] | select(.status == "success") | .video_results | select(. != null and .success == true) | .time_total_sec] | max // 0),
                avg: (([.iterations[] | select(.status == "success") | .video_results | select(. != null and .success == true) | .time_total_sec] | add // 0) / ([.iterations[] | select(.status == "success") | .video_results | select(. != null and .success == true)] | length | if . == 0 then 1 else . end))
            }
        },
        iperf_test: {
            successful_tests: ([.iterations[] | select(.status == "success") | .iperf_results | select(. != null and .success == true)] | length),
            failed_tests: ([.iterations[] | select(.status == "success") | .iperf_results | select(. != null and .success == false)] | length),
            total_bytes: ([.iterations[] | select(.status == "success") | .iperf_results | select(. != null and .success == true) | .bytes_transferred] | add // 0),
            bits_per_second: {
                min: ([.iterations[] | select(.status == "success") | .iperf_results | select(. != null and .success == true) | .bits_per_second] | min // 0),
                max: ([.iterations[] | select(.status == "success") | .iperf_results | select(. != null and .success == true) | .bits_per_second] | max // 0),
                avg: (([.iterations[] | select(.status == "success") | .iperf_results | select(. != null and .success == true) | .bits_per_second] | add // 0) / ([.iterations[] | select(.status == "success") | .iperf_results | select(. != null and .success == true)] | length | if . == 0 then 1 else . end))
            },
            retransmits: {
                min: ([.iterations[] | select(.status == "success") | .iperf_results | select(. != null and .success == true) | .retransmits] | min // 0),
                max: ([.iterations[] | select(.status == "success") | .iperf_results | select(. != null and .success == true) | .retransmits] | max // 0),
                total: ([.iterations[] | select(.status == "success") | .iperf_results | select(. != null and .success == true) | .retransmits] | add // 0)
            },
            server_output: {
                tests_with_server_output: ([.iterations[] | select(.status == "success") | .iperf_results | select(. != null and .success == true and .server_output_available == true)] | length),
                bits_per_second: {
                    min: ([.iterations[] | select(.status == "success") | .iperf_results | select(. != null and .success == true and .server_output != null) | .server_output.bits_per_second] | min // 0),
                    max: ([.iterations[] | select(.status == "success") | .iperf_results | select(. != null and .success == true and .server_output != null) | .server_output.bits_per_second] | max // 0),
                    avg: (([.iterations[] | select(.status == "success") | .iperf_results | select(. != null and .success == true and .server_output != null) | .server_output.bits_per_second] | add // 0) / ([.iterations[] | select(.status == "success") | .iperf_results | select(. != null and .success == true and .server_output != null)] | length | if . == 0 then 1 else . end))
                },
                retransmits_total: ([.iterations[] | select(.status == "success") | .iperf_results | select(. != null and .success == true and .server_output != null) | .server_output.retransmits] | add // 0)
            }
        },
        webpage_test: {
            by_url: (
                . as $root |
                ([$root.iterations[] | select(.status == "success") | .webpage_results // [] | .[] | .url] | unique) as $urls |
                $urls | map(. as $u | {
                    url: $u,
                    successful: ([$root.iterations[] | select(.status == "success") | .webpage_results // [] | .[] | select(.url == $u and .success == true)] | length),
                    failed:     ([$root.iterations[] | select(.status == "success") | .webpage_results // [] | .[] | select(.url == $u and .success != true)] | length),
                    ttfb_ms: {
                        min: ([$root.iterations[] | select(.status == "success") | .webpage_results // [] | .[] | select(.url == $u and .success == true) | .ttfb_ms | select(. != null)] | min // 0),
                        max: ([$root.iterations[] | select(.status == "success") | .webpage_results // [] | .[] | select(.url == $u and .success == true) | .ttfb_ms | select(. != null)] | max // 0),
                        avg: (([$root.iterations[] | select(.status == "success") | .webpage_results // [] | .[] | select(.url == $u and .success == true) | .ttfb_ms | select(. != null)] | add // 0) / ([$root.iterations[] | select(.status == "success") | .webpage_results // [] | .[] | select(.url == $u and .success == true)] | length | if . == 0 then 1 else . end))
                    },
                    fcp_ms: {
                        min: ([$root.iterations[] | select(.status == "success") | .webpage_results // [] | .[] | select(.url == $u and .success == true) | .fcp_ms | select(. != null)] | min // 0),
                        max: ([$root.iterations[] | select(.status == "success") | .webpage_results // [] | .[] | select(.url == $u and .success == true) | .fcp_ms | select(. != null)] | max // 0),
                        avg: (([$root.iterations[] | select(.status == "success") | .webpage_results // [] | .[] | select(.url == $u and .success == true) | .fcp_ms | select(. != null)] | add // 0) / ([$root.iterations[] | select(.status == "success") | .webpage_results // [] | .[] | select(.url == $u and .success == true)] | length | if . == 0 then 1 else . end))
                    },
                    lcp_ms: {
                        min: ([$root.iterations[] | select(.status == "success") | .webpage_results // [] | .[] | select(.url == $u and .success == true) | .lcp_ms | select(. != null)] | min // 0),
                        max: ([$root.iterations[] | select(.status == "success") | .webpage_results // [] | .[] | select(.url == $u and .success == true) | .lcp_ms | select(. != null)] | max // 0),
                        avg: (([$root.iterations[] | select(.status == "success") | .webpage_results // [] | .[] | select(.url == $u and .success == true) | .lcp_ms | select(. != null)] | add // 0) / ([$root.iterations[] | select(.status == "success") | .webpage_results // [] | .[] | select(.url == $u and .success == true)] | length | if . == 0 then 1 else . end))
                    },
                    dcl_ms: {
                        min: ([$root.iterations[] | select(.status == "success") | .webpage_results // [] | .[] | select(.url == $u and .success == true) | .dcl_ms | select(. != null)] | min // 0),
                        max: ([$root.iterations[] | select(.status == "success") | .webpage_results // [] | .[] | select(.url == $u and .success == true) | .dcl_ms | select(. != null)] | max // 0),
                        avg: (([$root.iterations[] | select(.status == "success") | .webpage_results // [] | .[] | select(.url == $u and .success == true) | .dcl_ms | select(. != null)] | add // 0) / ([$root.iterations[] | select(.status == "success") | .webpage_results // [] | .[] | select(.url == $u and .success == true)] | length | if . == 0 then 1 else . end))
                    },
                    page_load_ms: {
                        min: ([$root.iterations[] | select(.status == "success") | .webpage_results // [] | .[] | select(.url == $u and .success == true) | .page_load_ms | select(. != null)] | min // 0),
                        max: ([$root.iterations[] | select(.status == "success") | .webpage_results // [] | .[] | select(.url == $u and .success == true) | .page_load_ms | select(. != null)] | max // 0),
                        avg: (([$root.iterations[] | select(.status == "success") | .webpage_results // [] | .[] | select(.url == $u and .success == true) | .page_load_ms | select(. != null)] | add // 0) / ([$root.iterations[] | select(.status == "success") | .webpage_results // [] | .[] | select(.url == $u and .success == true)] | length | if . == 0 then 1 else . end))
                    },
                    total_ms: {
                        min: ([$root.iterations[] | select(.status == "success") | .webpage_results // [] | .[] | select(.url == $u and .success == true) | .total_ms | select(. != null)] | min // 0),
                        max: ([$root.iterations[] | select(.status == "success") | .webpage_results // [] | .[] | select(.url == $u and .success == true) | .total_ms | select(. != null)] | max // 0),
                        avg: (([$root.iterations[] | select(.status == "success") | .webpage_results // [] | .[] | select(.url == $u and .success == true) | .total_ms | select(. != null)] | add // 0) / ([$root.iterations[] | select(.status == "success") | .webpage_results // [] | .[] | select(.url == $u and .success == true)] | length | if . == 0 then 1 else . end))
                    }
                })
            )
        }
    }' "$BATCH_RESULTS_FILE")
    jq ".summary = $summary" "$BATCH_RESULTS_FILE" > "${BATCH_RESULTS_FILE}.tmp" && mv "${BATCH_RESULTS_FILE}.tmp" "$BATCH_RESULTS_FILE"
}

print_summary() {
    log ""; log "═══════════════════════════════════════════════════════════════"
    log "                     FINAL SUMMARY"
    log "═══════════════════════════════════════════════════════════════"
    local s=$(jq '.summary' "$BATCH_RESULTS_FILE")
    log "🔧 Configuration: Roaming=$ROAMING_MODE, VPLMN=$SECURITY_MODE"
    [ "$CONFIG_FILE_MODE" = "true" ] && log "   Config File: $CONFIG_FILE_PATH"
    log "📊 Iterations: $(echo "$s" | jq '.successful_iterations')/$(echo "$s" | jq '.total_iterations') successful"
    log "⏱️  Timing (Total): min=$(echo "$s" | jq '.timing_total_ms.min')ms, max=$(echo "$s" | jq '.timing_total_ms.max')ms, avg=$(printf "%.2f" "$(echo "$s" | jq '.timing_total_ms.avg')")ms"
    
    # Print ping test summary if enabled
    if [ "$PING_TEST_ENABLED" = "true" ]; then
        log "📡 Pings: $(echo "$s" | jq '.successful_pings')/$(echo "$s" | jq '.total_pings'), loss=$(printf "%.2f" "$(echo "$s" | jq '.overall_packet_loss')")%"
    fi
    
    # Print download test summary if enabled
    if [ "$DOWNLOAD_TEST_ENABLED" = "true" ]; then
        local dl_success=$(echo "$s" | jq '.download_test.successful_downloads')
        local dl_failed=$(echo "$s" | jq '.download_test.failed_downloads')
        local dl_speed_avg=$(echo "$s" | jq '.download_test.speed_bytes_per_sec.avg')
        local dl_speed_mbps=$(echo "scale=2; $dl_speed_avg / 1048576" | bc 2>/dev/null | sed 's/^\./0./' || echo "0")
        log "📥 Downloads: $dl_success/$((dl_success + dl_failed)) successful, avg speed: ${dl_speed_mbps} MB/s"
    fi
    
    # Print video test summary if enabled
    if [ "$VIDEO_TEST_ENABLED" = "true" ]; then
        local vid_success=$(echo "$s" | jq '.video_test.successful_tests')
        local vid_failed=$(echo "$s" | jq '.video_test.failed_tests')
        local vid_mbps_avg=$(echo "$s" | jq '.video_test.streaming_mbps.avg')
        local vid_mbps_fmt=$(printf "%.2f" "$vid_mbps_avg" 2>/dev/null || echo "0")
        log "🎬 Video: $vid_success/$((vid_success + vid_failed)) successful, avg bitrate: ${vid_mbps_fmt} Mbps"
    fi
    
    # Print iperf3 test summary if enabled
    if [ "$IPERF_TEST_ENABLED" = "true" ]; then
        local iperf_success=$(echo "$s" | jq '.iperf_test.successful_tests')
        local iperf_failed=$(echo "$s" | jq '.iperf_test.failed_tests')
        local iperf_bps_avg=$(echo "$s" | jq '.iperf_test.bits_per_second.avg')
        local iperf_mbps=$(echo "scale=2; $iperf_bps_avg / 1000000" | bc 2>/dev/null | sed 's/^\./0./' || echo "0")
        local iperf_retrans=$(echo "$s" | jq '.iperf_test.retransmits.total')
        log "📊 iperf3 (client): $iperf_success/$((iperf_success + iperf_failed)) successful, avg: ${iperf_mbps} Mbps, retransmits: $iperf_retrans"
        
        # Show server-side summary if available
        local srv_count=$(echo "$s" | jq '.iperf_test.server_output.tests_with_server_output // 0')
        if [ "$srv_count" -gt 0 ] 2>/dev/null; then
            local srv_bps_avg=$(echo "$s" | jq '.iperf_test.server_output.bits_per_second.avg')
            local srv_mbps=$(echo "scale=2; $srv_bps_avg / 1000000" | bc 2>/dev/null | sed 's/^\./0./' || echo "0")
            local srv_retrans=$(echo "$s" | jq '.iperf_test.server_output.retransmits_total // 0')
            log "📊 iperf3 (server): avg: ${srv_mbps} Mbps, retransmits: $srv_retrans ($srv_count tests with server output)"
        fi
    fi
    
    # Print webpage test summary if enabled
    if [ "$WEBPAGE_TEST_ENABLED" = "true" ]; then
        local wp_by_url
        wp_by_url=$(echo "$s" | jq -c '.webpage_test.by_url // []')
        local wp_count
        wp_count=$(echo "$wp_by_url" | jq 'length')
        if [ "${wp_count:-0}" -gt 0 ]; then
            log "🌐 Webpage (Browsertime) results:"
            echo "$wp_by_url" | jq -c '.[]' | while read -r entry; do
                local _url _ok _fail _ttfb_avg _load_avg _total_avg
                _url=$(echo "$entry" | jq -r '.url')
                _ok=$(echo "$entry"       | jq '.successful')
                _fail=$(echo "$entry"     | jq '.failed')
                _ttfb_avg=$(echo "$entry" | jq '.ttfb_ms.avg | ceil')
                _fcp_avg=$(echo "$entry"  | jq '.fcp_ms.avg | ceil')
                _lcp_avg=$(echo "$entry"  | jq '.lcp_ms.avg | ceil')
                _dcl_avg=$(echo "$entry"  | jq '.dcl_ms.avg | ceil')
                _load_avg=$(echo "$entry" | jq '.page_load_ms.avg | ceil')
                _total_avg=$(echo "$entry" | jq '(.total_ms.avg // 0) | ceil')
                log "   $_url : $_ok/$((${_ok}+${_fail})) OK | TTFB avg ${_ttfb_avg}ms | FCP avg ${_fcp_avg}ms | LCP avg ${_lcp_avg}ms | DCL avg ${_dcl_avg}ms | Load avg ${_load_avg}ms | Total avg ${_total_avg}ms"
            done
        else
            log "🌐 Webpage: no per-URL data in summary (check iterations)"
        fi
    fi

    # Print N6 delay info if enabled
    if [ "$N6_DELAY_ENABLED" = "true" ]; then
        log "🌐 N6 Delay: $N6_DELAY_VALUE ${N6_DELAY_JITTER:+(±$N6_DELAY_JITTER)} on both ogstun and $SERVER_IP:$SERVER_INTERFACE"
    fi
    
    log "📁 Results: $BATCH_RESULTS_FILE"
    
    # Print startup metrics if enabled
    print_startup_metrics
}

# ============================================================================
# Batch Execution
# ============================================================================

run_batch() {
    log "╔════════════════════════════════════════════════════════════╗"
    log "║            Starting Batch Test Execution                   ║"
    log "╚════════════════════════════════════════════════════════════╝"
    init_results
    local restart_needed=false
    for iteration in $(seq 1 "$ITERATIONS"); do
        log ""; log "═══════════════════════════════════════════════════════════════"
        log " ITERATION $iteration of $ITERATIONS"
        log "═══════════════════════════════════════════════════════════════"
        [ "$restart_needed" = true ] && { restart_testbed; restart_needed=false; }
        [ "$TESTBED_RESTART_INTERVAL" -gt 0 ] && [ $((iteration % TESTBED_RESTART_INTERVAL)) -eq 0 ] && [ "$iteration" -gt 1 ] && restart_testbed
        if start_packetrusher_with_timing "$iteration"; then
            # Run ping tests if enabled
            [ "$PING_TEST_ENABLED" = "true" ] && perform_ping_tests "$PR_UE_IP" "$PR_VRF"
            # Run download test if enabled
            [ "$DOWNLOAD_TEST_ENABLED" = "true" ] && perform_download_test "$PR_UE_IP" "$PR_VRF"
            # Run video streaming test if enabled
            [ "$VIDEO_TEST_ENABLED" = "true" ] && perform_video_test "$PR_UE_IP" "$PR_VRF"
            # Run iperf3 test if enabled
            [ "$IPERF_TEST_ENABLED" = "true" ] && perform_iperf_test "$PR_UE_IP" "$PR_VRF"
            # Run webpage loading tests if enabled
            [ "$WEBPAGE_TEST_ENABLED" = "true" ] && perform_webpage_test "$PR_UE_IP" "$PR_VRF"
            add_iteration_result "$iteration" "success"
        else
            log "❌ Iteration $iteration FAILED: $PR_ERROR"
            add_iteration_result "$iteration" "failed"
            [ "$PR_ERROR" = "timeout" ] || [ "$PR_ERROR" = "container_start_failed" ] || [ "$PR_ERROR" = "gtp_kernel_error" ] && restart_needed=true
        fi
        stop_packetrusher
        [[ $(( iteration % MAX_LOG_FILES )) -eq 0 ]] && prune_pr_logs
        [ "$iteration" -lt "$ITERATIONS" ] && { log "   ⏳ Waiting ${ITERATION_DELAY}s..."; sleep "$ITERATION_DELAY"; }
    done
    add_summary
    log "╔════════════════════════════════════════════════════════════╗"
    log "║                   BATCH TEST COMPLETE                      ║"
    log "╚════════════════════════════════════════════════════════════╝"
}

prune_pr_logs() {
    mapfile -t _pr_logs < <(ls -1t "$LOG_DIR"/packetrusher_iter*.log 2>/dev/null)
    if [[ ${#_pr_logs[@]} -gt $MAX_LOG_FILES ]]; then
        local pr_pruned=$(( ${#_pr_logs[@]} - MAX_LOG_FILES ))
        printf '%s\n' "${_pr_logs[@]:$MAX_LOG_FILES}" | xargs rm -f --
        log "   🗑️  Pruned $pr_pruned old PacketRusher log(s) (keeping last $MAX_LOG_FILES)"
    fi
}

prune_browsertime_logs() {
    # Browsertime writes one directory per run ($LOG_DIR/browsertime_<TIMESTAMP>),
    # so prune the oldest directories (not files) the same way as the log files.
    mapfile -t _bt_dirs < <(ls -1dt "$LOG_DIR"/browsertime_*/ 2>/dev/null)
    if [[ ${#_bt_dirs[@]} -gt $MAX_LOG_FILES ]]; then
        local bt_pruned=$(( ${#_bt_dirs[@]} - MAX_LOG_FILES ))
        printf '%s\n' "${_bt_dirs[@]:$MAX_LOG_FILES}" | xargs rm -rf --
        log "   🗑️  Pruned $bt_pruned old Browsertime log dir(s) (keeping last $MAX_LOG_FILES)"
    fi
}

prune_old_logs() {
    local batch_pruned=0
    mapfile -t _batch_logs < <(ls -1t "$LOG_DIR"/batch_*.log 2>/dev/null)
    if [[ ${#_batch_logs[@]} -gt $MAX_LOG_FILES ]]; then
        batch_pruned=$(( ${#_batch_logs[@]} - MAX_LOG_FILES ))
        printf '%s\n' "${_batch_logs[@]:$MAX_LOG_FILES}" | xargs rm -f --
        log "🗑️  Pruned $batch_pruned old batch log(s) (keeping last $MAX_LOG_FILES)"
    fi
    prune_pr_logs
    prune_browsertime_logs
}

cleanup() {
    log "🧹 Cleaning up..."
    [ ${#APPLIED_DELAYS[@]} -gt 0 ] && remove_all_delays
    stop_packetrusher
    prune_old_logs
    log "✅ Cleanup complete"
}
trap cleanup EXIT
