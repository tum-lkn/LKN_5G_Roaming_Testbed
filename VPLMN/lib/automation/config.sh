#!/bin/bash
# lib/automation/config.sh
# Startup timing metrics, configuration file parsing and display,
# interactive test setup menus (select_mode, show_delay_preconfiguration_menu),
# and quick mode.

record_timing() {
    local name=$1
    [ "$STARTUP_METRICS_ENABLED" = "true" ] && STARTUP_TIMINGS["$name"]=$(date +%s%3N)
}

get_elapsed_ms() {
    local start_name=$1
    local end_name=$2
    local start=${STARTUP_TIMINGS[$start_name]:-0}
    local end=${STARTUP_TIMINGS[$end_name]:-$(date +%s%3N)}
    echo $((end - start))
}

print_startup_metrics() {
    [ "$STARTUP_METRICS_ENABLED" != "true" ] && return
    log ""
    log "╔═══════════════════════════════════════════════════════════════╗"
    log "║              Startup Performance Metrics                      ║"
    log "╠═══════════════════════════════════════════════════════════════╣"
    [ -n "${STARTUP_TIMINGS[preflight_start]:-}" ] && [ -n "${STARTUP_TIMINGS[preflight_end]:-}" ] && \
        log "║  Preflight checks    : $(get_elapsed_ms preflight_start preflight_end)ms"
    [ -n "${STARTUP_TIMINGS[networks_start]:-}" ] && [ -n "${STARTUP_TIMINGS[networks_end]:-}" ] && \
        log "║  Network startup     : $(get_elapsed_ms networks_start networks_end)ms"
    [ -n "${STARTUP_TIMINGS[health_start]:-}" ] && [ -n "${STARTUP_TIMINGS[health_end]:-}" ] && \
        log "║  Health checks       : $(get_elapsed_ms health_start health_end)ms"
    [ -n "${STARTUP_TIMINGS[ipsec_start]:-}" ] && [ -n "${STARTUP_TIMINGS[ipsec_end]:-}" ] && \
        log "║  IPsec setup         : $(get_elapsed_ms ipsec_start ipsec_end)ms"
    [ -n "${STARTUP_TIMINGS[delays_start]:-}" ] && [ -n "${STARTUP_TIMINGS[delays_end]:-}" ] && \
        log "║  Delay application   : $(get_elapsed_ms delays_start delays_end)ms"
    [ -n "${STARTUP_TIMINGS[total_start]:-}" ] && \
        log "║  Total startup time  : $(get_elapsed_ms total_start total_end)ms"
    log "╚═══════════════════════════════════════════════════════════════╝"
}

# ============================================================================
# Configuration File Functions
# ============================================================================

generate_sample_config() {
    local output_file="${1:-batch_config_sample.conf}"
    
    cat > "$output_file" << 'EOFCONFIG'
# ============================================================================
# Open5GS Batch Automation Configuration File
# Version: 3.2.5 (Web Page Loading Tests)
# ============================================================================

# ROAMING CONFIGURATION
ROAMING_MODE=hr
IPSEC_ENABLED=false

# SECURITY CONFIGURATION
VPLMN_SECURITY=tls
HPLMN_SECURITY=tls

# TEST PARAMETERS
ITERATIONS=10
PING_COUNT=10
PING_TARGET=8.8.8.8
ITERATION_DELAY=2
TESTBED_RESTART_INTERVAL=0

# PING CONFIGURATION (New in v3.0.0)
# Payload size in bytes (empty = default 56 bytes)
# PING_PAYLOAD_SIZE=1400
# Ping interval in seconds (default: 1)
# PING_INTERVAL=0.2

# WEB PAGE LOADING TESTS (Updated in v3.3.0 - Browsertime-based)
# Test real website loading times through a real browser over the 5G GTP tunnel.
# Requires sitespeedio/browsertime Docker image.
# Add one WEBPAGE_URL_N line per URL to test (N = 1, 2, 3, ...).
WEBPAGE_TEST_ENABLED=true
WEBPAGE_BROWSER=firefox
WEBPAGE_ITERATIONS=1
WEBPAGE_TIMEOUT=120
WEBPAGE_URL_1=https://www.youtube.com/@Cristiano
WEBPAGE_URL_2=https://www.instagram.com/leomessi/
WEBPAGE_URL_3=https://www.facebook.com/DonaldTrump/
WEBPAGE_URL_4=https://www.google.com/search?q=lionel+messi
WEBPAGE_URL_5=https://en.wikipedia.org/wiki/Cristiano_Ronaldo
WEBPAGE_URL_6=https://github.com/open5gs/open5gs
WEBPAGE_URL_7=http://1.1.1.1

# PERFORMANCE TUNING (v2.9.0+)
NETWORK_READY_TIMEOUT=30
SERVICE_CHECK_INTERVAL=1
IPSEC_ESTABLISH_TIMEOUT=10
MIN_NETWORK_STABILIZE_TIME=10

# SERVER CONFIGURATION (Updated in v3.2.3)
# SERVER_IP=10.162.149.210
# SERVER_USER=roaming
# SERVER_INTERFACE=ens18

# N6 DELAY CONFIGURATION (Merged in v3.2.3)
# When enabled, delay is applied to BOTH ogstun (UPF) and server interface
# N6_DELAY_ENABLED=true
# N6_DELAY_VALUE=50ms
# N6_DELAY_JITTER=10ms

# NETWORK DELAY CONFIGURATION (Optional)
# IMPORTANT: Set DELAY_ENABLED=true to enable delays
# If DELAY_ENABLED=false, delay rules will be ignored even if specified
DELAY_ENABLED=false

# Delay rules format: location:service:mode=delay_value
# Or with jitter: location:service:mode=delay_value:jitter_value
#
# Examples:
# DELAY_RULE_1=local:open5gs-upf:gtpu=50ms
# DELAY_RULE_2=local:open5gs-upf:gtpu=50ms:10ms
# DELAY_RULE_3=local:open5gs-sepp:n32=25ms:5ms
# DELAY_RULE_4=local:open5gs-smf:pfcp=20ms
EOFCONFIG

    echo "✅ Sample configuration file generated: $output_file"
    echo ""
    echo "Usage:"
    echo "  1. Edit the configuration file to match your test requirements"
    echo "  2. Run: $0 --config $output_file"
}

parse_config_file() {
    local config_file="$1"
    
    if [ ! -f "$config_file" ]; then
        echo "❌ Configuration file not found: $config_file"
        exit 1
    fi
    
    log "📄 Loading configuration from: $config_file"
    
    # First pass: Parse DELAY_ENABLED to know if we should honor delay rules
    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ ! "$line" =~ = ]] && continue
        
        local key="${line%%=*}"
        local value="${line#*=}"
        value=$(echo "$value" | sed 's/^["'"'"']//;s/["'"'"']$//')
        
        if [ "$key" = "DELAY_ENABLED" ]; then
            case "$value" in
                true|TRUE|yes|YES|1) DELAY_ENABLED="true" ;;
                false|FALSE|no|NO|0) DELAY_ENABLED="false" ;;
            esac
            DELAY_ENABLED_EXPLICIT="true"
            break
        fi
    done < "$config_file"
    
    # Second pass: Parse all configuration
    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ ! "$line" =~ = ]] && continue
        
        local key="${line%%=*}"
        local value="${line#*=}"
        value=$(echo "$value" | sed 's/^["'"'"']//;s/["'"'"']$//')
        
        case "$key" in
            ROAMING_MODE)
                case "$value" in
                    hr|HR) 
                        ROAMING_MODE="hr"
                        UPF_IMAGE="open5gs-upf:v2.7.6-hr"
                        PR_CONFIG_FOLDER="hr_roaming"
                        ;;
                    lbo|LBO)
                        ROAMING_MODE="lbo"
                        UPF_IMAGE="open5gs-upf:v2.7.2"
                        PR_CONFIG_FOLDER="lbo_roaming"
                        ;;
                    non-roaming|non_roaming|NON-ROAMING|NON_ROAMING|nonroaming)
                        ROAMING_MODE="non-roaming"
                        UPF_IMAGE="open5gs-upf:v2.7.2"
                        PR_CONFIG_FOLDER="non_roaming"
                        ;;
                esac
                log "   Roaming Mode: $ROAMING_MODE"
                ;;
            IPSEC_ENABLED)
                case "$value" in
                    true|TRUE|yes|YES|1) IPSEC_ENABLED="true" ;;
                    false|FALSE|no|NO|0) IPSEC_ENABLED="false" ;;
                esac
                log "   IPsec Enabled: $IPSEC_ENABLED"
                ;;
            IPSEC_MODE)
                if [[ "$value" =~ ^[1-6]$ ]]; then
                    IPSEC_MODE="$value"
                    log "   IPsec Mode: $IPSEC_MODE (${IPSEC_MODE_NAMES[$IPSEC_MODE]})"
                else
                    log "   ⚠️  Invalid IPSEC_MODE '$value' (must be 1-6), ignoring"
                fi
                ;;
            VPLMN_SECURITY)
                case "$value" in
                    tls|TLS) SECURITY_MODE="tls"; SUFFIX="_tls.yaml" ;;
                    plain|PLAIN) SECURITY_MODE="plain"; SUFFIX=".yaml" ;;
                esac
                log "   VPLMN Security: $SECURITY_MODE"
                ;;
            HPLMN_SECURITY)
                case "$value" in
                    tls|TLS) REMOTE_SECURITY_MODE="tls"; REMOTE_SUFFIX="_tls.yaml" ;;
                    plain|PLAIN) REMOTE_SECURITY_MODE="plain"; REMOTE_SUFFIX=".yaml" ;;
                esac
                log "   HPLMN Security: $REMOTE_SECURITY_MODE"
                ;;
            ITERATIONS)
                if [ "$value" -gt 100 ]; then
                    log "   ⚠️  Warning: Iterations capped at 100 (requested: $value)"
                    ITERATIONS=100
                else
                    ITERATIONS="$value"
                fi
                log "   Iterations: $ITERATIONS"
                ;;
            PING_COUNT)
                PING_COUNT="$value"
                log "   Ping Count: $PING_COUNT"
                ;;
            PING_TARGET)
                PING_TARGET="$value"
                log "   Ping Target: $PING_TARGET"
                ;;
            PING_PAYLOAD_SIZE)
                PING_PAYLOAD_SIZE="$value"
                log "   Ping Payload Size: ${PING_PAYLOAD_SIZE} bytes"
                ;;
            PING_INTERVAL)
                PING_INTERVAL="$value"
                log "   Ping Interval: ${PING_INTERVAL}s"
                ;;
            PING_TEST_ENABLED)
                case "$value" in
                    true|TRUE|yes|YES|1) PING_TEST_ENABLED="true" ;;
                    false|FALSE|no|NO|0) PING_TEST_ENABLED="false" ;;
                esac
                log "   Ping Test Enabled: $PING_TEST_ENABLED"
                ;;
            ITERATION_DELAY)
                ITERATION_DELAY="$value"
                log "   Iteration Delay: ${ITERATION_DELAY}s"
                ;;
            TESTBED_RESTART_INTERVAL)
                TESTBED_RESTART_INTERVAL="$value"
                log "   Testbed Restart Interval: $TESTBED_RESTART_INTERVAL"
                ;;
            DELAY_ENABLED)
                # Already handled in first pass, just log
                log "   Delay Enabled: $DELAY_ENABLED"
                ;;
            DELAY_RULE_*)
                # Only add delay rules if DELAY_ENABLED is true
                if [ "$DELAY_ENABLED" = "true" ]; then
                    # Parse delay rule with optional jitter: location:service:mode=delay[:jitter]
                    if [[ "$value" =~ ^(local|remote):([^:]+):([^=]+)=([^:]+)(:(.+))?$ ]]; then
                        local d_location="${BASH_REMATCH[1]}"
                        local d_service="${BASH_REMATCH[2]}"
                        local d_mode="${BASH_REMATCH[3]}"
                        local d_delay="${BASH_REMATCH[4]}"
                        local d_jitter="${BASH_REMATCH[6]:-}"
                        
                        if [ -n "$d_jitter" ]; then
                            DELAY_CONFIGS["$d_location:$d_service:$d_mode"]="$d_delay:$d_jitter"
                            log "   Delay Rule: $d_location:$d_service:$d_mode = $d_delay (jitter: $d_jitter)"
                        else
                            DELAY_CONFIGS["$d_location:$d_service:$d_mode"]="$d_delay"
                            log "   Delay Rule: $d_location:$d_service:$d_mode = $d_delay"
                        fi
                    fi
                else
                    log "   Delay Rule (IGNORED - DELAY_ENABLED=false): $value"
                fi
                ;;
            # Download test configuration (NEW in v3.2.0)
            DOWNLOAD_TEST_ENABLED)
                case "$value" in
                    true|TRUE|yes|YES|1) DOWNLOAD_TEST_ENABLED="true" ;;
                    false|FALSE|no|NO|0) DOWNLOAD_TEST_ENABLED="false" ;;
                esac
                log "   Download Test Enabled: $DOWNLOAD_TEST_ENABLED"
                ;;
            DOWNLOAD_TEST_URL)
                DOWNLOAD_TEST_URL="$value"
                log "   Download Test URL: $DOWNLOAD_TEST_URL"
                ;;
            DOWNLOAD_TEST_SIZE_LABEL)
                DOWNLOAD_TEST_SIZE_LABEL="$value"
                log "   Download Test Size Label: $DOWNLOAD_TEST_SIZE_LABEL"
                ;;
            # Video streaming test configuration (NEW in v3.2.0)
            VIDEO_TEST_ENABLED)
                case "$value" in
                    true|TRUE|yes|YES|1) VIDEO_TEST_ENABLED="true" ;;
                    false|FALSE|no|NO|0) VIDEO_TEST_ENABLED="false" ;;
                esac
                log "   Video Test Enabled: $VIDEO_TEST_ENABLED"
                ;;
            VIDEO_TEST_URL)
                VIDEO_TEST_URL="$value"
                log "   Video Test URL: $VIDEO_TEST_URL"
                ;;
            VIDEO_TEST_SIZE_LABEL)
                VIDEO_TEST_SIZE_LABEL="$value"
                log "   Video Test Size Label: $VIDEO_TEST_SIZE_LABEL"
                ;;
            # iperf3 test configuration (NEW in v3.2.1)
            IPERF_TEST_ENABLED)
                case "$value" in
                    true|TRUE|yes|YES|1) IPERF_TEST_ENABLED="true" ;;
                    false|FALSE|no|NO|0) IPERF_TEST_ENABLED="false" ;;
                esac
                log "   iperf3 Test Enabled: $IPERF_TEST_ENABLED"
                ;;
            IPERF_SERVER_IP)
                IPERF_SERVER_IP="$value"
                log "   iperf3 Server IP: $IPERF_SERVER_IP"
                ;;
            IPERF_SERVER_PORT)
                IPERF_SERVER_PORT="$value"
                log "   iperf3 Server Port: $IPERF_SERVER_PORT"
                ;;
            IPERF_DURATION)
                IPERF_DURATION="$value"
                log "   iperf3 Duration: ${IPERF_DURATION}s"
                ;;
            IPERF_PARALLEL)
                IPERF_PARALLEL="$value"
                log "   iperf3 Parallel Streams: $IPERF_PARALLEL"
                ;;
            IPERF_REVERSE)
                case "$value" in
                    true|TRUE|yes|YES|1) IPERF_REVERSE="true" ;;
                    false|FALSE|no|NO|0) IPERF_REVERSE="false" ;;
                esac
                log "   iperf3 Reverse Mode: $IPERF_REVERSE"
                ;;
            IPERF_UDP)
                case "$value" in
                    true|TRUE|yes|YES|1) IPERF_UDP="true" ;;
                    false|FALSE|no|NO|0) IPERF_UDP="false" ;;
                esac
                log "   iperf3 UDP Mode: $IPERF_UDP"
                ;;
            IPERF_BANDWIDTH)
                IPERF_BANDWIDTH="$value"
                log "   iperf3 Target Bandwidth: $IPERF_BANDWIDTH"
                ;;
            # Webpage test configuration (Updated in v3.3.0 - Browsertime)
            WEBPAGE_TEST_ENABLED)
                case "$value" in
                    true|TRUE|yes|YES|1) WEBPAGE_TEST_ENABLED="true" ;;
                    false|FALSE|no|NO|0) WEBPAGE_TEST_ENABLED="false" ;;
                esac
                log "   Webpage Test Enabled: $WEBPAGE_TEST_ENABLED"
                ;;
            WEBPAGE_BROWSER)
                case "$value" in
                    firefox|chrome|edge) WEBPAGE_BROWSER="$value" ;;
                    *) log "   ⚠️  Unknown browser '$value', keeping firefox" ;;
                esac
                log "   Webpage Browser: $WEBPAGE_BROWSER"
                ;;
            WEBPAGE_ITERATIONS)
                WEBPAGE_ITERATIONS="$value"
                log "   Webpage Browsertime Iterations: $WEBPAGE_ITERATIONS"
                ;;
            WEBPAGE_TIMEOUT)
                WEBPAGE_TIMEOUT="$value"
                log "   Webpage Test Timeout: ${WEBPAGE_TIMEOUT}s"
                ;;
            WEBPAGE_URL_*)
                # Append URL to the list (WEBPAGE_URL_1, WEBPAGE_URL_2, ...)
                WEBPAGE_URLS+=("$value")
                log "   Webpage URL: $value"
                ;;
            # Backward compat: old fixed YouTube/Instagram keys → append to URL list
            WEBPAGE_YOUTUBE_URL)
                WEBPAGE_URLS+=("$value")
                log "   ⚠️  WEBPAGE_YOUTUBE_URL is deprecated, use WEBPAGE_URL_N (mapped: $value)"
                ;;
            WEBPAGE_INSTAGRAM_URL)
                WEBPAGE_URLS+=("$value")
                log "   ⚠️  WEBPAGE_INSTAGRAM_URL is deprecated, use WEBPAGE_URL_N (mapped: $value)"
                ;;
            # N6 Delay Configuration (MERGED in v3.2.3)
            N6_DELAY_ENABLED)
                case "$value" in
                    true|TRUE|yes|YES|1) N6_DELAY_ENABLED="true" ;;
                    false|FALSE|no|NO|0) N6_DELAY_ENABLED="false" ;;
                esac
                log "   N6 Delay Enabled: $N6_DELAY_ENABLED"
                ;;
            N6_DELAY_VALUE)
                N6_DELAY_VALUE="$value"
                log "   N6 Delay Value: $N6_DELAY_VALUE"
                ;;
            N6_DELAY_JITTER)
                N6_DELAY_JITTER="$value"
                log "   N6 Delay Jitter: $N6_DELAY_JITTER"
                ;;
            # Server configuration (NEW in v3.2.3)
            SERVER_IP)
                SERVER_IP="$value"
                log "   Server IP: $SERVER_IP"
                ;;
            SERVER_USER)
                SERVER_USER="$value"
                log "   Server User: $SERVER_USER"
                ;;
            SERVER_INTERFACE)
                SERVER_INTERFACE="$value"
                log "   Server Interface: $SERVER_INTERFACE"
                ;;
            # Backward compatibility: map old N6_SERVER_* params
            N6_SERVER_DELAY_ENABLED)
                log "   ⚠️  N6_SERVER_DELAY_ENABLED is deprecated in v3.2.3 (server delay is now automatic when N6_DELAY_ENABLED=true)"
                ;;
            N6_SERVER_DELAY_VALUE)
                log "   ⚠️  N6_SERVER_DELAY_VALUE is deprecated in v3.2.3 (uses N6_DELAY_VALUE for both ogstun and server)"
                ;;
            N6_SERVER_DELAY_JITTER)
                log "   ⚠️  N6_SERVER_DELAY_JITTER is deprecated in v3.2.3 (uses N6_DELAY_JITTER for both ogstun and server)"
                ;;
            N6_SERVER_INTERFACE)
                SERVER_INTERFACE="$value"
                log "   ⚠️  N6_SERVER_INTERFACE is deprecated, use SERVER_INTERFACE instead (mapped: $value)"
                ;;
            # Performance tuning parameters
            NETWORK_READY_TIMEOUT) NETWORK_READY_TIMEOUT="$value" ;;
            SERVICE_CHECK_INTERVAL) SERVICE_CHECK_INTERVAL="$value" ;;
            IPSEC_ESTABLISH_TIMEOUT) IPSEC_ESTABLISH_TIMEOUT="$value" ;;
            MIN_NETWORK_STABILIZE_TIME) MIN_NETWORK_STABILIZE_TIME="$value" ;;
            # Infrastructure overrides
            HPLMN_IP) HPLMN_IP="$value" ;;
            REMOTE_PC_USER) REMOTE_PC_USER="$value" ;;
            REMOTE_PC_PATH) REMOTE_PC_PATH="$value" ;;
            PR_IP) PR_IP="$value" ;;
            PR_CONTAINER) PR_CONTAINER="$value" ;;
            PR_IMAGE) PR_IMAGE="$value" ;;
            PR_NETWORK) PR_NETWORK="$value" ;;
            CONFIG_DIR) CONFIG_DIR="$value" ;;
            LOG_DIR) LOG_DIR="$value"; mkdir -p "$LOG_DIR" ;;
            RESULTS_DIR) RESULTS_DIR="$value"; mkdir -p "$RESULTS_DIR" ;;
            MAX_LOG_FILES) MAX_LOG_FILES="$value" ;;
            # Config metadata (NEW in user request)
            VPLMN_NAME) VPLMN_NAME="$value" ;;
            DN_LOCATION) DN_LOCATION="$value" ;;
            DN_LATENCY) DN_LATENCY="$value" ;;
            DN_JITTER) DN_JITTER="$value" ;;
        esac
    done < "$config_file"
    
    # Set defaults
    ITERATIONS="${ITERATIONS:-$DEFAULT_ITERATIONS}"
    PING_COUNT="${PING_COUNT:-$DEFAULT_PING_COUNT}"
    PING_TARGET="${PING_TARGET:-$DEFAULT_TARGET}"
    ITERATION_DELAY="${ITERATION_DELAY:-2}"
    TESTBED_RESTART_INTERVAL="${TESTBED_RESTART_INTERVAL:-0}"
    PING_INTERVAL="${PING_INTERVAL:-1}"
    
    # Set BATCH_RESULTS_FILE if not already set by run_with_config_file (NEW in user request)
    if [ -z "$BATCH_RESULTS_FILE" ]; then
        BATCH_RESULTS_FILE="$RESULTS_DIR/batch_results_${TIMESTAMP}.json"
    fi
    
    log "✅ Configuration loaded successfully"
}

print_config_summary() {
    log ""
    log "╔═══════════════════════════════════════════════════════════════╗"
    log "║           Configuration Summary (from file)                   ║"
    log "╠═══════════════════════════════════════════════════════════════╣"
    log "║  Roaming Mode      : $ROAMING_MODE"
    [ "$ROAMING_MODE" = "hr" ] && log "║  N9 IPsec          : $IPSEC_ENABLED"
    log "║  VPLMN Security    : $SECURITY_MODE"
    [ "$ROAMING_MODE" != "non-roaming" ] && log "║  HPLMN Security    : $REMOTE_SECURITY_MODE"
    log "║  Iterations        : $ITERATIONS"
    log "║  Iteration Delay   : ${ITERATION_DELAY}s"
    log "║  Network Delay     : $DELAY_ENABLED (${#DELAY_CONFIGS[@]} rules)"
    log "║  N6 Delay          : $N6_DELAY_ENABLED"
    if [ "$N6_DELAY_ENABLED" = "true" ]; then
        log "║    Delay Value     : ${N6_DELAY_VALUE:-none} ${N6_DELAY_JITTER:+(jitter: $N6_DELAY_JITTER)}"
        local ogstun_loc="local"
        [ "$ROAMING_MODE" = "hr" ] && ogstun_loc="remote"
        log "║    ogstun target   : $ogstun_loc UPF"
        log "║    server target   : $SERVER_USER@$SERVER_IP ($SERVER_INTERFACE)"
    fi
    log "╠═══════════════════════════════════════════════════════════════╣"
    log "║  Server Configuration:                                        ║"
    log "║    IP               : $SERVER_IP"
    log "║    User             : $SERVER_USER"
    log "║    Interface        : $SERVER_INTERFACE"
    log "╠═══════════════════════════════════════════════════════════════╣"
    log "║  Test Modes:                                                  ║"
    log "║    Ping Test       : $PING_TEST_ENABLED"
    if [ "$PING_TEST_ENABLED" = "true" ]; then
        log "║      Count         : $PING_COUNT"
        log "║      Target        : $PING_TARGET"
        log "║      Interval      : ${PING_INTERVAL}s"
        [ -n "$PING_PAYLOAD_SIZE" ] && log "║      Payload       : ${PING_PAYLOAD_SIZE} bytes"
    fi
    log "║    Download Test   : $DOWNLOAD_TEST_ENABLED"
    if [ "$DOWNLOAD_TEST_ENABLED" = "true" ]; then
        log "║      URL           : $DOWNLOAD_TEST_URL"
        [ -n "$DOWNLOAD_TEST_SIZE_LABEL" ] && log "║      File Size     : $DOWNLOAD_TEST_SIZE_LABEL"
    fi
    log "║    Video Test      : $VIDEO_TEST_ENABLED"
    if [ "$VIDEO_TEST_ENABLED" = "true" ]; then
        log "║      URL           : $VIDEO_TEST_URL"
        [ -n "$VIDEO_TEST_SIZE_LABEL" ] && log "║      File Size     : $VIDEO_TEST_SIZE_LABEL"
    fi
    log "║    iperf3 Test     : $IPERF_TEST_ENABLED"
    if [ "$IPERF_TEST_ENABLED" = "true" ]; then
        log "║      Server        : $IPERF_SERVER_IP:$IPERF_SERVER_PORT"
        log "║      Duration      : ${IPERF_DURATION}s"
        [ "$IPERF_PARALLEL" -gt 1 ] && log "║      Parallel      : $IPERF_PARALLEL streams"
        [ "$IPERF_REVERSE" = "true" ] && log "║      Mode          : Reverse (download)"
        [ "$IPERF_UDP" = "true" ] && log "║      Protocol      : UDP (bandwidth: ${IPERF_BANDWIDTH:-auto})"
    fi
    log "║    Webpage Test    : $WEBPAGE_TEST_ENABLED"
    if [ "$WEBPAGE_TEST_ENABLED" = "true" ]; then
        log "║      Browser       : $WEBPAGE_BROWSER (iter: $WEBPAGE_ITERATIONS)"
        log "║      Timeout       : ${WEBPAGE_TIMEOUT}s per URL"
        log "║      URLs (${#WEBPAGE_URLS[@]}):"
        for _wu in "${WEBPAGE_URLS[@]}"; do
            log "║        $_wu"
        done
    fi
    log "╠═══════════════════════════════════════════════════════════════╣"
    log "║  Performance Tuning:                                         ║"
    log "║    Network Timeout : ${NETWORK_READY_TIMEOUT}s"
    log "║    Check Interval  : ${SERVICE_CHECK_INTERVAL}s"
    log "║    IPsec Timeout   : ${IPSEC_ESTABLISH_TIMEOUT}s"
    log "╚═══════════════════════════════════════════════════════════════╝"
}

create_env_file_from_config() {
    local _vplmn_ip _vplmn_user
    _vplmn_ip=$(grep -oP '^VPLMN_IP\s*=\s*\K[0-9.]+' "$ENV_FILE" 2>/dev/null || true)
    _vplmn_user="${SUDO_USER:-$USER}"
    cat > "$ENV_FILE" <<EOF
# Generated by testbed automation script v$SCRIPT_VERSION - $(date -Iseconds)
# Security: $SECURITY_MODE
# Roaming: $ROAMING_MODE

HPLMN_IP=$HPLMN_IP
VPLMN_IP=$_vplmn_ip
HPLMN_USER=$REMOTE_PC_USER
VPLMN_USER=$_vplmn_user
PERF_SERVER_IP=$SERVER_IP
PERF_SERVER_USER=$SERVER_USER

UPF_IMAGE=$UPF_IMAGE

NRF_CONFIG=nrf$SUFFIX
SCP_CONFIG=scp$SUFFIX
AMF_CONFIG=amf$SUFFIX
SMF_CONFIG=smf$SUFFIX
UPF_CONFIG=upf$SUFFIX
AUSF_CONFIG=ausf$SUFFIX
UDM_CONFIG=udm$SUFFIX
PCF_CONFIG=pcf$SUFFIX
NSSF_CONFIG=nssf$SUFFIX
BSF_CONFIG=bsf$SUFFIX
UDR_CONFIG=udr$SUFFIX
SEPP_CONFIG=sepp$SUFFIX
EOF
    log "✅ Local .env file created"
}


show_delay_preconfiguration_menu() {
    echo; echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║     Network Delay Pre-Configuration                           ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo; echo "Do you want to configure network delays?"
    echo "  1) Yes - Configure delay settings"
    echo "  2) No  - Run without delay"
    read -rp "Enter choice [1-2]: " DELAY_CHOICE
    [ "$DELAY_CHOICE" != "1" ] && { DELAY_ENABLED="false"; log "ℹ️  Network delay: DISABLED"; return; }
    DELAY_ENABLED="true"
    local continue_adding="y"
    while [[ "$continue_adding" =~ ^[Yy]$ ]]; do
        echo; echo "Select location: 1) VPLMN (Local)"; [ "$ROAMING_MODE" != "non-roaming" ] && echo "  2) HPLMN (Remote)"
        read -rp "Enter choice: " LOC_CHOICE
        local location="local" services=("${VPLMN_SERVICES[@]}")
        [ "$LOC_CHOICE" = "2" ] && [ "$ROAMING_MODE" != "non-roaming" ] && { location="remote"; services=("${HPLMN_SERVICES[@]}"); }
        echo; echo "Available services:"; local i=1
        for svc in "${services[@]}"; do echo "  $i) $svc"; ((i++)); done
        read -rp "Select service number: " SVC_CHOICE
        [[ "$SVC_CHOICE" =~ ^[0-9]+$ ]] && [ "$SVC_CHOICE" -ge 1 ] && [ "$SVC_CHOICE" -le "${#services[@]}" ] || { read -rp "Add another? [y/N]: " continue_adding; continue; }
        local selected="${services[$((SVC_CHOICE-1))]}"
        echo "Selected: $selected on $location"
        
        local mode=""
        if is_host_network_service "$selected"; then
            echo "UPF delay mode:"
            echo "  1) GTP-U (N9 user plane, port $GTPU_PORT — works with or without IPsec)"
            echo "  2) IPsec (ESP protocol)"
            echo "  3) PFCP (N4 control plane, port $PFCP_PORT)"
            [ "$location" = "local" ] && echo "  4) N3 (local only)"
            echo "  5) Full (all traffic)"
            echo "  6) Cancel"
            read -rp "Choice: " UPF_CHOICE
            case "$UPF_CHOICE" in 1) mode="gtpu" ;; 2) mode="ipsec" ;; 3) mode="pfcp" ;; 4) [ "$location" = "local" ] && mode="n3" ;; 5) mode="full" ;; esac
        elif [ "$selected" = "open5gs-sepp" ]; then
            echo "SEPP delay mode:"
            echo "  1) N32 (ports $SEPP_N32_PORT_1/$SEPP_N32_PORT_2 - SEPP-to-SEPP)"
            echo "  2) Full eth0 (all container traffic)"
            echo "  3) Cancel"
            read -rp "Choice: " SEPP_CHOICE
            case "$SEPP_CHOICE" in 1) mode="n32" ;; 2) mode="eth0" ;; esac
        elif [ "$selected" = "open5gs-smf" ]; then
            echo "SMF delay mode:"
            echo "  1) PFCP (SMF-UPF communication, port $PFCP_PORT)"
            echo "  2) Full eth0 (all container traffic)"
            echo "  3) Cancel"
            read -rp "Choice: " SMF_CHOICE
            case "$SMF_CHOICE" in 1) mode="pfcp" ;; 2) mode="eth0" ;; esac
        else
            mode="eth0"
        fi
        
        if [ -n "$mode" ]; then
            read -rp "Delay value (e.g., 50ms): " delay_value
            if validate_delay_format "$delay_value"; then
                read -rp "Add jitter? (e.g., 10ms, or leave empty for none): " jitter_value
                if [ -n "$jitter_value" ]; then
                    if validate_delay_format "$jitter_value"; then
                        DELAY_CONFIGS["$location:$selected:$mode"]="$delay_value:$jitter_value"
                        echo "✅ Added: $location:$selected:$mode = $delay_value (jitter: $jitter_value)"
                    else
                        echo "⚠️ Invalid jitter format, adding delay without jitter"
                        DELAY_CONFIGS["$location:$selected:$mode"]="$delay_value"
                    fi
                else
                    DELAY_CONFIGS["$location:$selected:$mode"]="$delay_value"
                    echo "✅ Added: $location:$selected:$mode = $delay_value"
                fi
            else
                echo "⚠️ Invalid delay format"
            fi
        fi
        read -rp "Add another delay rule? [y/N]: " continue_adding
    done
    show_delay_config_summary
}

select_mode() {
    log "======================================="
    log " Open5GS Batch Test Configuration"
    log "======================================="
    echo; echo "Select UPF Roaming Mode:"
    echo "  1) Home Routed (HR)"
    echo "  2) Local Breakout (LBO)"
    echo "  3) Non-Roaming"
    read -rp "Enter choice [1-3]: " ROAMING_CHOICE
    case "$ROAMING_CHOICE" in
        1) ROAMING_MODE="hr"; UPF_IMAGE="open5gs-upf:v2.7.6-hr"; PR_CONFIG_FOLDER="hr_roaming" ;;
        2) ROAMING_MODE="lbo"; UPF_IMAGE="open5gs-upf:v2.7.2"; PR_CONFIG_FOLDER="lbo_roaming" ;;
        3) ROAMING_MODE="non-roaming"; UPF_IMAGE="open5gs-upf:v2.7.2"; PR_CONFIG_FOLDER="non_roaming" ;;
        *) error_exit "Invalid roaming mode" ;;
    esac
    if [ "$ROAMING_MODE" = "hr" ]; then
        echo; check_ipsec_status; echo
        echo "Enable IPsec on N9? 1)Yes 2)No"
        read -rp "Choice [1-2]: " IPSEC_CHOICE
        if [ "$IPSEC_CHOICE" = "1" ]; then
            IPSEC_ENABLED="true"
            echo
            echo "Select IPsec ESP Mode:"
            echo "  1) AES-128-GCM (AEAD, fast, recommended)"
            echo "  2) AES-256-GCM (AEAD, stronger key)"
            echo "  3) AES-128-CBC + SHA256 (Separate enc+auth)"
            echo "  4) AES-256-CBC + SHA256 (Separate, stronger)"
            echo "  5) NULL + SHA256 (⚠️  NO ENCRYPTION - integrity only)"
            echo "  6) NULL + GMAC (⚠️  NO ENCRYPTION - integrity only)"
            echo "  0) Use current IPsec config (no change)"
            read -rp "Choice [0-6, default=1]: " IPSEC_MODE_CHOICE
            IPSEC_MODE_CHOICE="${IPSEC_MODE_CHOICE:-1}"
            if [[ "$IPSEC_MODE_CHOICE" =~ ^[1-6]$ ]]; then
                IPSEC_MODE="$IPSEC_MODE_CHOICE"
                echo "✅ Selected: ${IPSEC_MODE_NAMES[$IPSEC_MODE]}"
            elif [ "$IPSEC_MODE_CHOICE" = "0" ]; then
                IPSEC_MODE=""
                echo "✅ Using current IPsec configuration"
            else
                echo "⚠️  Invalid choice, defaulting to AES-128-GCM"
                IPSEC_MODE="1"
            fi
        else
            IPSEC_ENABLED="false"
        fi
    fi
    echo; echo "VPLMN Security: 1)TLS 2)Plain"
    read -rp "Choice [1-2]: " SECURITY_CHOICE
    [ "$SECURITY_CHOICE" = "1" ] && { SECURITY_MODE="tls"; SUFFIX="_tls.yaml"; } || { SECURITY_MODE="plain"; SUFFIX=".yaml"; }
    if [ "$ROAMING_MODE" != "non-roaming" ]; then
        echo; echo "HPLMN Security: 1)TLS 2)Plain"
        read -rp "Choice [1-2]: " REMOTE_SECURITY_CHOICE
        [ "$REMOTE_SECURITY_CHOICE" = "1" ] && { REMOTE_SECURITY_MODE="tls"; REMOTE_SUFFIX="_tls.yaml"; } || { REMOTE_SECURITY_MODE="plain"; REMOTE_SUFFIX=".yaml"; }
    fi
    show_delay_preconfiguration_menu
    
    # Set default ping values
    PING_COUNT=${PING_COUNT:-$DEFAULT_PING_COUNT}
    PING_TARGET=${PING_TARGET:-$DEFAULT_TARGET}
    PING_INTERVAL=${PING_INTERVAL:-1}
    
    # Test Mode Configuration
    echo; echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║     Test Mode Configuration                                   ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo
    echo "Select test modes (you can enable multiple tests):"
    echo "Each selected test will run in every iteration."
    echo
    
    # Initialize all tests as disabled
    PING_TEST_ENABLED="false"
    DOWNLOAD_TEST_ENABLED="false"
    VIDEO_TEST_ENABLED="false"
    IPERF_TEST_ENABLED="false"
    WEBPAGE_TEST_ENABLED="false"
    
    # Ping test selection
    echo "1) Ping Test (latency measurement)"
    read -rp "   Enable ping test? [Y/n]: " PING_CHOICE
    [[ ! "$PING_CHOICE" =~ ^[Nn]$ ]] && PING_TEST_ENABLED="true"
    
    # Download test selection
    echo "2) Download Test (file download throughput)"
    read -rp "   Enable download test? [y/N]: " DL_CHOICE
    [[ "$DL_CHOICE" =~ ^[Yy]$ ]] && DOWNLOAD_TEST_ENABLED="true"
    
    # Video streaming test selection
    echo "3) Video Streaming Test (video throughput + quality)"
    read -rp "   Enable video streaming test? [y/N]: " VID_CHOICE
    [[ "$VID_CHOICE" =~ ^[Yy]$ ]] && VIDEO_TEST_ENABLED="true"
    
    # iperf3 test selection
    echo "4) iperf3 Test (raw network throughput)"
    read -rp "   Enable iperf3 test? [y/N]: " IPERF_CHOICE
    [[ "$IPERF_CHOICE" =~ ^[Yy]$ ]] && IPERF_TEST_ENABLED="true"
    
    # Webpage loading test selection
    echo "5) Webpage Loading Test (real-world website performance)"
    read -rp "   Enable webpage loading test? [y/N]: " WEBPAGE_CHOICE
    [[ "$WEBPAGE_CHOICE" =~ ^[Yy]$ ]] && WEBPAGE_TEST_ENABLED="true"
    
    # Validate at least one test is enabled
    if [ "$PING_TEST_ENABLED" = "false" ] && [ "$DOWNLOAD_TEST_ENABLED" = "false" ] && [ "$VIDEO_TEST_ENABLED" = "false" ] && [ "$IPERF_TEST_ENABLED" = "false" ] && [ "$WEBPAGE_TEST_ENABLED" = "false" ]; then
        echo "⚠️  At least one test must be enabled. Enabling Ping test."
        PING_TEST_ENABLED="true"
    fi
    
    # Show selection summary
    echo
    echo "Selected tests:"
    [ "$PING_TEST_ENABLED" = "true" ] && echo "  ✅ Ping Test"
    [ "$DOWNLOAD_TEST_ENABLED" = "true" ] && echo "  ✅ Download Test"
    [ "$VIDEO_TEST_ENABLED" = "true" ] && echo "  ✅ Video Streaming Test"
    [ "$IPERF_TEST_ENABLED" = "true" ] && echo "  ✅ iperf3 Test"
    [ "$WEBPAGE_TEST_ENABLED" = "true" ] && echo "  ✅ Webpage Loading Test"
    
    # Configure ping test parameters if enabled
    if [ "$PING_TEST_ENABLED" = "true" ]; then
        echo
        echo "--- Ping Test Configuration ---"
        read -rp "Pings per iteration [default: $DEFAULT_PING_COUNT]: " PING_COUNT; PING_COUNT=${PING_COUNT:-$DEFAULT_PING_COUNT}
        read -rp "Ping target [default: $DEFAULT_TARGET]: " PING_TARGET; PING_TARGET=${PING_TARGET:-$DEFAULT_TARGET}
        read -rp "Ping interval in seconds [default: 1]: " PING_INTERVAL; PING_INTERVAL=${PING_INTERVAL:-1}
        read -rp "Ping payload size in bytes (empty for default 56): " PING_PAYLOAD_SIZE
    fi
    
    # Configure download test parameters if enabled
    if [ "$DOWNLOAD_TEST_ENABLED" = "true" ]; then
        echo
        echo "--- Download Test Configuration ---"
        echo "Server options (perf-server $SERVER_IP):"
        echo "  1) 10MB file (http://$SERVER_IP:$DEFAULT_DOWNLOAD_PORT/10MB.bin)"
        echo "  2) 50MB file (http://$SERVER_IP:$DEFAULT_DOWNLOAD_PORT/50MB.bin)"
        echo "  3) 100MB file (http://$SERVER_IP:$DEFAULT_DOWNLOAD_PORT/100MB.bin)"
        echo "  4) Custom URL"
        read -rp "Enter choice [1-4]: " FILE_CHOICE
        case "$FILE_CHOICE" in
            1) DOWNLOAD_TEST_URL="http://$SERVER_IP:$DEFAULT_DOWNLOAD_PORT/10MB.bin"; DOWNLOAD_TEST_SIZE_LABEL="10MB" ;;
            2) DOWNLOAD_TEST_URL="http://$SERVER_IP:$DEFAULT_DOWNLOAD_PORT/50MB.bin"; DOWNLOAD_TEST_SIZE_LABEL="50MB" ;;
            3) DOWNLOAD_TEST_URL="http://$SERVER_IP:$DEFAULT_DOWNLOAD_PORT/100MB.bin"; DOWNLOAD_TEST_SIZE_LABEL="100MB" ;;
            4) 
                read -rp "Enter download URL: " DOWNLOAD_TEST_URL
                read -rp "Enter file size label (e.g., 50MB): " DOWNLOAD_TEST_SIZE_LABEL
                ;;
            *)
                DOWNLOAD_TEST_URL="http://$SERVER_IP:$DEFAULT_DOWNLOAD_PORT/10MB.bin"
                DOWNLOAD_TEST_SIZE_LABEL="10MB"
                echo "⚠️  Invalid choice, defaulting to 10MB"
                ;;
        esac
        echo "✅ Download: $DOWNLOAD_TEST_SIZE_LABEL from $DOWNLOAD_TEST_URL"
    fi
    
    # Configure video streaming test parameters if enabled
    if [ "$VIDEO_TEST_ENABLED" = "true" ]; then
        echo
        echo "--- Video Streaming Test Configuration ---"
        echo "Server options (perf-server $SERVER_IP):"
        echo "  1) 150MB video (http://$SERVER_IP:$DEFAULT_DOWNLOAD_PORT/video_150MB.mp4)"
        echo "  2) 50MB file (http://$SERVER_IP:$DEFAULT_DOWNLOAD_PORT/50MB.bin)"
        echo "  3) 100MB file (http://$SERVER_IP:$DEFAULT_DOWNLOAD_PORT/100MB.bin)"
        echo "  4) Custom URL"
        read -rp "Enter choice [1-4]: " VID_FILE_CHOICE
        case "$VID_FILE_CHOICE" in
            1) VIDEO_TEST_URL="http://$SERVER_IP:$DEFAULT_DOWNLOAD_PORT/video_150MB.mp4"; VIDEO_TEST_SIZE_LABEL="150MB Video" ;;
            2) VIDEO_TEST_URL="http://$SERVER_IP:$DEFAULT_DOWNLOAD_PORT/50MB.bin"; VIDEO_TEST_SIZE_LABEL="50MB File" ;;
            3) VIDEO_TEST_URL="http://$SERVER_IP:$DEFAULT_DOWNLOAD_PORT/100MB.bin"; VIDEO_TEST_SIZE_LABEL="100MB File" ;;
            4) 
                read -rp "Enter video URL: " VIDEO_TEST_URL
                read -rp "Enter video size label (e.g., 500MB Video): " VIDEO_TEST_SIZE_LABEL
                ;;
            *)
                VIDEO_TEST_URL="http://$SERVER_IP:$DEFAULT_DOWNLOAD_PORT/video_150MB.mp4"
                VIDEO_TEST_SIZE_LABEL="150MB Video"
                echo "⚠️  Invalid choice, defaulting to 150MB Video"
                ;;
        esac
        echo "✅ Video: $VIDEO_TEST_SIZE_LABEL from $VIDEO_TEST_URL"
    fi
    
    # Configure iperf3 test parameters if enabled
    if [ "$IPERF_TEST_ENABLED" = "true" ]; then
        echo
        echo "--- iperf3 Test Configuration ---"
        read -rp "iperf3 server IP [default: $SERVER_IP]: " IPERF_SERVER_IP
        IPERF_SERVER_IP=${IPERF_SERVER_IP:-$SERVER_IP}
        read -rp "iperf3 server port [default: $DEFAULT_IPERF_PORT]: " IPERF_SERVER_PORT
        IPERF_SERVER_PORT=${IPERF_SERVER_PORT:-$DEFAULT_IPERF_PORT}
        read -rp "Test duration in seconds [default: 10]: " IPERF_DURATION
        IPERF_DURATION=${IPERF_DURATION:-10}
        read -rp "Parallel streams [default: 1]: " IPERF_PARALLEL
        IPERF_PARALLEL=${IPERF_PARALLEL:-1}
        read -rp "Reverse mode (download test)? [y/N]: " IPERF_REV
        [[ "$IPERF_REV" =~ ^[Yy]$ ]] && IPERF_REVERSE="true" || IPERF_REVERSE="false"
        read -rp "Use UDP instead of TCP? [y/N]: " IPERF_UDP_CHOICE
        if [[ "$IPERF_UDP_CHOICE" =~ ^[Yy]$ ]]; then
            IPERF_UDP="true"
            read -rp "Target bandwidth (e.g., 100M, 1G) [default: auto]: " IPERF_BANDWIDTH
        else
            IPERF_UDP="false"
        fi
        echo "✅ iperf3: $IPERF_SERVER_IP:$IPERF_SERVER_PORT, ${IPERF_DURATION}s"
        [ "$IPERF_REVERSE" = "true" ] && echo "   Mode: Reverse (download)"
        [ "$IPERF_UDP" = "true" ] && echo "   Protocol: UDP (bandwidth: ${IPERF_BANDWIDTH:-auto})"
    fi
    
    # Configure webpage test parameters if enabled
    if [ "$WEBPAGE_TEST_ENABLED" = "true" ]; then
        echo
        echo "--- Browsertime Webpage Loading Test Configuration ---"
        echo
        echo "Browser selection:"
        echo "  1) Firefox (default)"
        echo "  2) Chrome"
        echo "  3) Edge"
        read -rp "Choice [1-3, default: 1]: " _wp_br_choice
        case "${_wp_br_choice:-1}" in
            2) WEBPAGE_BROWSER="chrome" ;;
            3) WEBPAGE_BROWSER="edge" ;;
            *) WEBPAGE_BROWSER="firefox" ;;
        esac
        echo "✅ Browser: $WEBPAGE_BROWSER"

        read -rp "Browsertime iterations per URL [default: $WEBPAGE_ITERATIONS]: " _wp_iter
        [[ "${_wp_iter:-}" =~ ^[1-9][0-9]*$ ]] && WEBPAGE_ITERATIONS="$_wp_iter"
        read -rp "Timeout per URL in seconds [default: $WEBPAGE_TIMEOUT]: " _wp_timeout
        [[ "${_wp_timeout:-}" =~ ^[1-9][0-9]*$ ]] && WEBPAGE_TIMEOUT="$_wp_timeout"

        echo
        echo "Select URLs to test (enter numbers, multiple allowed):"
        local _wp_defaults=(
            "https://www.youtube.com/@Cristiano"
            "https://www.instagram.com/leomessi/"
            "https://www.facebook.com/DonaldTrump/"
            "https://www.google.com/search?q=lionel+messi"
            "https://en.wikipedia.org/wiki/Cristiano_Ronaldo"
            "https://github.com/open5gs/open5gs"
            "http://1.1.1.1"
        )
        local _i=1
        for _u in "${_wp_defaults[@]}"; do
            printf "  %d) %s\n" "$_i" "$_u"
            _i=$((_i + 1))
        done
        printf "  %d) Enter custom URL\n" "$_i"
        echo
        WEBPAGE_URLS=()
        echo "Enter URL numbers separated by spaces (e.g., 1 2 3), or 0 for none:"
        read -rp "Selection: " _wp_selection
        for _sel in $_wp_selection; do
            if [[ "$_sel" =~ ^[0-9]+$ ]] && [ "$_sel" -ge 1 ] && [ "$_sel" -le "${#_wp_defaults[@]}" ]; then
                WEBPAGE_URLS+=("${_wp_defaults[$((_sel - 1))]}") 
                echo "  + ${_wp_defaults[$((_sel - 1))]}"
            fi
        done
        # Allow adding custom URLs
        while true; do
            read -rp "Add a custom URL? (leave empty to finish): " _wp_custom
            [ -z "$_wp_custom" ] && break
            WEBPAGE_URLS+=("$_wp_custom")
            echo "  + $_wp_custom"
        done
        if [ ${#WEBPAGE_URLS[@]} -eq 0 ]; then
            echo "⚠️  No URLs selected - defaulting to first two preset URLs"
            WEBPAGE_URLS=("https://www.youtube.com/@Cristiano" "https://www.instagram.com/leomessi/")
        fi
        echo "✅ Webpage test: ${#WEBPAGE_URLS[@]} URL(s), browser=$WEBPAGE_BROWSER, iter=$WEBPAGE_ITERATIONS, timeout=${WEBPAGE_TIMEOUT}s"
    fi
    
    # N6 Delay Configuration (interactive)
    echo; echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║     N6 Interface Delay Configuration                          ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo
    echo "N6 delay simulates internet latency between UPF and data network."
    echo "When enabled, the same delay is applied to BOTH:"
    echo "  • UPF ogstun (tun device) - based on roaming mode"
    echo "  • Server interface ($SERVER_INTERFACE on $SERVER_IP)"
    echo
    read -rp "Enable N6 delay? [y/N]: " N6_CHOICE
    if [[ "$N6_CHOICE" =~ ^[Yy]$ ]]; then
        N6_DELAY_ENABLED="true"
        read -rp "Delay value (e.g., 50ms): " N6_DELAY_VALUE
        read -rp "Jitter (e.g., 10ms, or leave empty): " N6_DELAY_JITTER
        echo "✅ N6 delay: $N6_DELAY_VALUE ${N6_DELAY_JITTER:+(jitter: $N6_DELAY_JITTER)}"
    else
        N6_DELAY_ENABLED="false"
    fi
    
    echo; read -rp "Iterations (max 100) [default: $DEFAULT_ITERATIONS]: " ITERATIONS; ITERATIONS=${ITERATIONS:-$DEFAULT_ITERATIONS}
    [ "$ITERATIONS" -gt 100 ] && { echo "⚠️  Capping at 100 iterations"; ITERATIONS=100; }
    read -rp "Delay between iterations [default: 2]: " ITERATION_DELAY; ITERATION_DELAY=${ITERATION_DELAY:-2}
    read -rp "Testbed restart interval [default: 0=disabled]: " TESTBED_RESTART_INTERVAL; TESTBED_RESTART_INTERVAL=${TESTBED_RESTART_INTERVAL:-0}
    read -rp "Max log files to keep per type [default: $MAX_LOG_FILES]: " _max_logs_input
    [[ "$_max_logs_input" =~ ^[1-9][0-9]*$ ]] && MAX_LOG_FILES="$_max_logs_input"
    
    log "======================================="
    log " Configuration Summary"
    log "======================================="
    log "  Roaming Mode: $ROAMING_MODE"
    if [ "$ROAMING_MODE" = "hr" ]; then
        log "  N9 IPsec: $IPSEC_ENABLED"
        [ "$IPSEC_ENABLED" = "true" ] && [ -n "$IPSEC_MODE" ] && log "  IPsec Mode: $IPSEC_MODE (${IPSEC_MODE_NAMES[$IPSEC_MODE]})"
    fi
    log "  VPLMN Security: $SECURITY_MODE"
    [ "$ROAMING_MODE" != "non-roaming" ] && log "  HPLMN Security: $REMOTE_SECURITY_MODE"
    log "  Server: $SERVER_USER@$SERVER_IP ($SERVER_INTERFACE)"
    log "  Iterations: $ITERATIONS"
    log "  Test Modes:"
    if [ "$PING_TEST_ENABLED" = "true" ]; then
        log "    Ping Test: ENABLED"
        log "      Count: $PING_COUNT, Target: $PING_TARGET, Interval: ${PING_INTERVAL}s"
        [ -n "$PING_PAYLOAD_SIZE" ] && log "      Payload: ${PING_PAYLOAD_SIZE} bytes"
    else
        log "    Ping Test: DISABLED"
    fi
    if [ "$DOWNLOAD_TEST_ENABLED" = "true" ]; then
        log "    Download Test: ENABLED"
        log "      File: $DOWNLOAD_TEST_SIZE_LABEL ($DOWNLOAD_TEST_URL)"
    else
        log "    Download Test: DISABLED"
    fi
    if [ "$VIDEO_TEST_ENABLED" = "true" ]; then
        log "    Video Test: ENABLED"
        log "      File: $VIDEO_TEST_SIZE_LABEL"
        log "      URL: $VIDEO_TEST_URL"
    else
        log "    Video Test: DISABLED"
    fi
    if [ "$IPERF_TEST_ENABLED" = "true" ]; then
        log "    iperf3 Test: ENABLED"
        log "      Server: $IPERF_SERVER_IP:$IPERF_SERVER_PORT"
        log "      Duration: ${IPERF_DURATION}s, Streams: $IPERF_PARALLEL"
        [ "$IPERF_REVERSE" = "true" ] && log "      Mode: Reverse (download)"
        [ "$IPERF_UDP" = "true" ] && log "      Protocol: UDP (bandwidth: ${IPERF_BANDWIDTH:-auto})"
    else
        log "    iperf3 Test: DISABLED"
    fi
    if [ "$WEBPAGE_TEST_ENABLED" = "true" ]; then
        log "    Webpage Loading Test: ENABLED"
        log "      Browser: $WEBPAGE_BROWSER (iter: $WEBPAGE_ITERATIONS)"
        log "      Timeout: ${WEBPAGE_TIMEOUT}s per URL"
        log "      URLs (${#WEBPAGE_URLS[@]}):"
        for _wu in "${WEBPAGE_URLS[@]}"; do log "        $_wu"; done
    else
        log "    Webpage Loading Test: DISABLED"
    fi
    if [ "$N6_DELAY_ENABLED" = "true" ]; then
        log "  N6 Delay: ENABLED ($N6_DELAY_VALUE ${N6_DELAY_JITTER:+±$N6_DELAY_JITTER})"
        log "    Applied to: ogstun + $SERVER_IP:$SERVER_INTERFACE"
    else
        log "  N6 Delay: DISABLED"
    fi
    log "  Network Delay: $DELAY_ENABLED (${#DELAY_CONFIGS[@]} rules)"
    log "  Max log files per type: $MAX_LOG_FILES"
    
    echo; read -rp "Proceed? [Y/n]: " confirm; [[ "$confirm" =~ ^[Nn]$ ]] && exit 0
    create_env_file_from_config
}


quick_mode() {
    log "Quick Mode - Networks assumed running"
    echo "Select Roaming: 1)HR 2)LBO 3)Non-Roaming"
    read -rp "Choice: " c
    case "$c" in 1) ROAMING_MODE="hr"; PR_CONFIG_FOLDER="hr_roaming" ;; 2) ROAMING_MODE="lbo"; PR_CONFIG_FOLDER="lbo_roaming" ;; 3) ROAMING_MODE="non-roaming"; PR_CONFIG_FOLDER="non_roaming" ;; *) error_exit "Invalid" ;; esac
    [ "$ROAMING_MODE" = "hr" ] && { check_ipsec_status; echo "IPsec? 1)Yes 2)No"; read -rp "Choice: " c; IPSEC_ENABLED=$([ "$c" = "1" ] && echo "true" || echo "false"); [ "$IPSEC_ENABLED" = "true" ] && start_all_ipsec || stop_all_ipsec; }
    echo "VPLMN: 1)TLS 2)Plain"; read -rp "Choice: " c; SECURITY_MODE=$([ "$c" = "1" ] && echo "tls" || echo "plain")
    [ "$ROAMING_MODE" != "non-roaming" ] && { echo "HPLMN: 1)TLS 2)Plain"; read -rp "Choice: " c; REMOTE_SECURITY_MODE=$([ "$c" = "1" ] && echo "tls" || echo "plain"); }
    show_delay_preconfiguration_menu
    read -rp "Iterations (max 100) [5]: " ITERATIONS; ITERATIONS=${ITERATIONS:-5}
    [ "$ITERATIONS" -gt 100 ] && { echo "⚠️  Capping at 100 iterations"; ITERATIONS=100; }
    read -rp "Pings [10]: " PING_COUNT; PING_COUNT=${PING_COUNT:-10}
    read -rp "Ping interval [1]: " PING_INTERVAL; PING_INTERVAL=${PING_INTERVAL:-1}
    read -rp "Ping payload (empty=default): " PING_PAYLOAD_SIZE
    PING_TARGET="8.8.8.8"; ITERATION_DELAY=2; TESTBED_RESTART_INTERVAL=0
    apply_preconfigured_delays
    run_batch; print_summary
}

