#!/bin/bash
# ============================================================================
# Config File Generator - Top-Level Batch Configs (All Modes, All Tests)
#
# Generates the standard per-mode config set into this configs/ directory:
#   1. non_roaming.conf
#   2. lbo.conf
#   3. hr.conf            (no IPsec)
#   4. hr_ipsec_1.conf    (AES-128-GCM)
#   5. hr_ipsec_2.conf    (AES-256-GCM)
#   6. hr_ipsec_3.conf    (AES-128-CBC + SHA256)
#   7. hr_ipsec_4.conf    (AES-256-CBC + SHA256)
#   8. hr_ipsec_5.conf    (NULL + SHA256)
#   9. hr_ipsec_6.conf    (NULL + GMAC)
#
# These are the configs the WebUI "Run Config File" tab lists and that
# `testbed_automation.sh --config configs/<name>.conf` runs. Regenerating
# overwrites them from the single template below, so per-mode drift is not
# possible — edit the template here, not the individual files.
#
# The performance-server IP is a single variable (SERVER_IP). setup.sh runs
# this script as a final step, and configure_ip_from_env.sh rewrites the
# SERVER_IP line here (not the generated .conf files) so a re-generate always
# bakes in the current IP.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR"

# ── Performance/test server IP ──────────────────────────────────────────────
# configure_ip_from_env.sh rewrites THIS line from .env (PERF_SERVER_IP). It is
# baked into the DOWNLOAD_TEST_URL, VIDEO_TEST_URL, IPERF_SERVER_IP and SERVER_IP
# fields of every generated config. Keep the trailing "# PERF_SERVER_IP" tag —
# that comment is the sed anchor configure_ip_from_env.sh matches on.
SERVER_IP="10.162.149.115"  # PERF_SERVER_IP

count=0

generate_config() {
    local filename="$1"
    local roaming_mode="$2"
    local ipsec_enabled="$3"
    local ipsec_mode="$4"

    # IPsec-enabled configs carry an active IPSEC_MODE=<n>; the others keep it
    # commented out as a template hint (matches the hand-written originals).
    local ipsec_mode_line
    if [[ "$ipsec_enabled" == "true" ]]; then
        ipsec_mode_line="IPSEC_MODE=${ipsec_mode}"
    else
        ipsec_mode_line="# IPSEC_MODE=2"
    fi

    cat > "${OUTPUT_DIR}/${filename}" << EOF
# ============================================================================
# Open5GS Batch Automation Configuration File
# Version: 2.9.0 (Optimized)
# ============================================================================

# ROAMING CONFIGURATION
ROAMING_MODE=${roaming_mode}
IPSEC_ENABLED=${ipsec_enabled}
${ipsec_mode_line}


# SECURITY CONFIGURATION
VPLMN_SECURITY=plain
HPLMN_SECURITY=plain

# TEST PARAMETERS
ITERATIONS=2
ITERATION_DELAY=2
TESTBED_RESTART_INTERVAL=10

# PING TEST
PING_TEST_ENABLED=true
PING_COUNT=400
PING_TARGET=${SERVER_IP}
PING_INTERVAL=0.02
PING_PAYLOAD_SIZE=1400


# DOWNLOAD TEST
DOWNLOAD_TEST_ENABLED=true
DOWNLOAD_TEST_URL=http://${SERVER_IP}:9000/100MB.bin
DOWNLOAD_TEST_SIZE_LABEL=100MB


# VIDEO TEST
VIDEO_TEST_ENABLED=true
VIDEO_TEST_URL=http://${SERVER_IP}:9000/video_150MB.mp4
VIDEO_TEST_SIZE_LABEL=150MB Video

# IPERF3 TEST
IPERF_TEST_ENABLED=true
IPERF_SERVER_IP=${SERVER_IP}
IPERF_SERVER_PORT=5201
IPERF_DURATION=5
IPERF_PARALLEL=1
IPERF_REVERSE=true
IPERF_UDP=true
IPERF_BANDWIDTH=100M

# WEBPAGE TEST (Browsertime real-browser page-load timings)
WEBPAGE_TEST_ENABLED=true
WEBPAGE_BROWSER=firefox
WEBPAGE_ITERATIONS=1
WEBPAGE_TIMEOUT=120
# Add one WEBPAGE_URL_N line per URL to test (N = 1, 2, 3, ...)
WEBPAGE_URL_1=https://www.youtube.com/@Cristiano
WEBPAGE_URL_2=https://www.instagram.com/leomessi/
WEBPAGE_URL_3=https://en.wikipedia.org/wiki/Cristiano_Ronaldo
WEBPAGE_URL_4=https://github.com/open5gs/open5gs

# SERVER CONFIGURATION
SERVER_IP=${SERVER_IP}

# DELAY CONFIGURATION
N6_DELAY_ENABLED=false
DELAY_ENABLED=false

# PERFORMANCE TUNING
# Reduce these values for faster startup (may reduce reliability)
NETWORK_READY_TIMEOUT=30
SERVICE_CHECK_INTERVAL=1
IPSEC_ESTABLISH_TIMEOUT=10
MIN_NETWORK_STABILIZE_TIME=10
EOF

    count=$((count + 1))
    echo "Generated: ${filename}"
}

# ============================================================================
# Generate all configs
# ============================================================================

echo "Generating configs in ${OUTPUT_DIR} ..."
echo ""

generate_config "non_roaming.conf" "non-roaming" "false" ""
generate_config "lbo.conf"         "lbo"         "false" ""
generate_config "hr.conf"          "hr"          "false" ""
generate_config "hr_ipsec_1.conf"  "hr"          "true"  "1"
generate_config "hr_ipsec_2.conf"  "hr"          "true"  "2"
generate_config "hr_ipsec_3.conf"  "hr"          "true"  "3"
generate_config "hr_ipsec_4.conf"  "hr"          "true"  "4"
generate_config "hr_ipsec_5.conf"  "hr"          "true"  "5"
generate_config "hr_ipsec_6.conf"  "hr"          "true"  "6"

echo ""
echo "============================================"
echo "Done! Generated ${count} config files in ${OUTPUT_DIR}"
echo "============================================"
