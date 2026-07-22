#!/bin/bash

# ============================================================================
# IKE Phase Performance Evaluation Script — Post-Quantum ML-KEM / ML-DSA
# DOCKERIZED VERSION (2 containers instead of 2 VMs)
#
# Port of ike_eval.sh (StrongSwan 6.0.x, swanctl) to a two-container
# Docker testbed:
#
#   VM testbed                    ->  Docker testbed
#   ---------------------------------------------------------------
#   PC1 / VPLMN VM (initiator)    ->  container pq-vplmn
#   PC2 / HPLMN VM (responder)    ->  container pq-hplmn
#   systemctl start/stop          ->  swan-start / swan-stop (docker exec)
#   ssh user@remote "cmd"         ->  docker exec pq-hplmn cmd
#   tc netem on VM NICs           ->  tc netem on container eth0 (both)
#   tcpdump on PC1                ->  tcpdump inside pq-vplmn (eth0)
#   /etc/swanctl/swanctl.conf     ->  same path, written via docker exec
#
# Measurement notes:
#   * Wire timings (pcap) are computed exactly as before with tshark+awk.
#   * Wall-clock (daemon start -> INSTALLED) is measured INSIDE the
#     initiator container (swan-run-initiator), so `docker exec` overhead
#     does not pollute it.
#   * Both containers run on ONE host (~0.05 ms RTT, shared CPU): absolute
#     numbers differ from the VM testbed, relative comparison of the four
#     configurations remains valid. Use delay_ms to emulate distance.
#
# Usage: ./ike_eval_docker.sh <config> [iterations] [delay_ms]
#   1 = Classical (ECP-256 + RSA)
#   2 = PQ Key Exchange (ML-KEM-768 + RSA)
#   3 = PQ Auth (ECP-256 + ML-DSA-65)
#   4 = Fully PQ (ML-KEM-768 + ML-DSA-65)
#   5 = All four (full comparison)
#
#   delay_ms = optional netem delay in ms applied in BOTH containers
#              (default: 0). e.g. 10 = +10ms each way = +20ms RTT
#
# Examples:
#   ./ike_eval_docker.sh 5 30        # all configs, 30 iters, no delay
#   ./ike_eval_docker.sh 5 30 10     # all configs, 30 iters, 10ms delay
# ============================================================================

set -euo pipefail

# ── Load shared settings (same .env as docker-compose.yml) ──
# readlink -f: resolve symlinks, so the script also works when invoked via a
# symlink (e.g. ~/ike_eval.sh -> ~/pq-ike-docker/ike_eval_docker.sh for the
# testbed WebUI backend) — conf/, results/ and .env stay anchored to the
# real project directory.
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
cd "$SCRIPT_DIR"
[ -f ./.env ] && set -a && . ./.env && set +a

# ── Containers & Network ──
VPLMN_CTR="${VPLMN_CTR:-pq-vplmn}"          # PC1 / initiator
HPLMN_CTR="${HPLMN_CTR:-pq-hplmn}"          # PC2 / responder
PC1_IP="${PC1_IP:-192.168.40.55}"
REMOTE_PC_IP="${PC2_IP:-192.168.40.230}"

# ── Certificate Identities (must match the VM setup's N9 tunnel DNs, i.e.
#    docker/ipsectunnel/01_setup_ca.sh + 03_setup_ipsec_pc1_cert.sh, and the PLMN the
#    VPLMN core actually serves: mcc999/mnc71. Keep in sync with the defaults in
#    container/gen-certs — the cert subject and these IDs must be identical or
#    IKE auth fails on an identity mismatch.) ──
PC1_ID='C=3G, O=Open5GS, CN=upf.5gc.mnc071.mcc999.3gppnetwork.org'
PC2_ID='C=3G, O=Open5GS, CN=upf.5gc.mnc001.mcc001.3gppnetwork.org'

# ── IKE Proposal Configurations ──
# 4-scenario comparison: Classical vs PQ for key exchange AND authentication
# ESP stays the same for all: aes128gcm16
declare -A IKE_PROPOSALS
declare -A PC1_CERTS
declare -A PC2_CERTS
declare -A CONFIG_LABELS
declare -A AUTH_ALGS

# Scenario 1: Fully classical
IKE_PROPOSALS[classical_rsa]="aes128gcm16-prfsha256-ecp256"
PC1_CERTS[classical_rsa]="pc1-upf-cert.pem"
PC2_CERTS[classical_rsa]="pc2-upf-cert.pem"
CONFIG_LABELS[classical_rsa]="ECP-256 + RSA (Fully Classical)"
AUTH_ALGS[classical_rsa]="rsa"

# Scenario 2: PQ key exchange, classical auth
IKE_PROPOSALS[mlkem768_rsa]="aes128gcm16-prfsha256-mlkem768"
PC1_CERTS[mlkem768_rsa]="pc1-upf-cert.pem"
PC2_CERTS[mlkem768_rsa]="pc2-upf-cert.pem"
CONFIG_LABELS[mlkem768_rsa]="ML-KEM-768 + RSA (PQ Key Exchange)"
AUTH_ALGS[mlkem768_rsa]="rsa"

# Scenario 3: Classical key exchange, PQ auth
IKE_PROPOSALS[ecp256_mldsa]="aes128gcm16-prfsha256-ecp256"
PC1_CERTS[ecp256_mldsa]="pq-pc1-upf-cert.pem"
PC2_CERTS[ecp256_mldsa]="pq-pc2-upf-cert.pem"
CONFIG_LABELS[ecp256_mldsa]="ECP-256 + ML-DSA-65 (PQ Auth)"
AUTH_ALGS[ecp256_mldsa]="mldsa65"

# Scenario 4: Fully post-quantum
IKE_PROPOSALS[mlkem768_mldsa]="aes128gcm16-prfsha256-mlkem768"
PC1_CERTS[mlkem768_mldsa]="pq-pc1-upf-cert.pem"
PC2_CERTS[mlkem768_mldsa]="pq-pc2-upf-cert.pem"
CONFIG_LABELS[mlkem768_mldsa]="ML-KEM-768 + ML-DSA-65 (Fully PQ)"
AUTH_ALGS[mlkem768_mldsa]="mldsa65"

ESP_PROPOSAL="aes128gcm16"

# ── Test Parameters ──
ITERATIONS=30
TIMEOUT=60
DELAY_BETWEEN="${DELAY_BETWEEN:-5}"
NETWORK_DELAY_MS=0                       # netem delay per container (ms)

# ── Paths (host side <-> container side via bind mounts) ──
RESULTS_DIR="./results/json"
LOG_DIR="./results/logs"
PCAP_DIR="./results/pcaps"               # host view
PCAP_DIR_CTR="/results/pcaps"            # same dir, container view
LOG_DIR_CTR="/results/logs"
SWANCTL_CONF="/etc/swanctl/swanctl.conf" # inside the containers

# ── Colors ──
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

# ============================================================================
# Helper Functions
# ============================================================================

show_usage() {
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  IKE Post-Quantum Performance Evaluation (Docker)     ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Usage: $0 <config> [iterations] [delay_ms]"
    echo ""
    echo "  Configs:"
    echo "    1 = Classical only (ECP-256 + RSA certs)"
    echo "    2 = PQ Key Exchange only (ML-KEM-768 + RSA certs)"
    echo "    3 = PQ Auth only (ECP-256 + ML-DSA-65 certs)"
    echo "    4 = Fully PQ (ML-KEM-768 + ML-DSA-65 certs)"
    echo "    5 = All four (full comparison)"
    echo ""
    echo "  delay_ms: netem delay added in BOTH containers (default: 0)"
    echo "            e.g., 10 = +10ms each way = +20ms RTT"
    echo ""
    echo "  Examples:"
    echo "    $0 5              # All 4, 30 iters, no delay"
    echo "    $0 5 30 10        # All 4, 30 iters, 10ms delay"
    echo "    $0 4 50           # Fully PQ, 50 iters, no delay"
    exit 1
}

# docker exec wrappers (replace local commands + run_remote/SSH)
dexec_v() { docker exec "$VPLMN_CTR" "$@"; }
dexec_h() { docker exec "$HPLMN_CTR" "$@"; }

log() {
    echo -e "$@"
}

# ============================================================================
# Network Delay Functions
# In the dedicated Docker bridge, eth0 of each container carries ONLY the
# traffic to/from the peer, so plain netem on eth0 is equivalent to the
# original per-peer tc filter (and docker exec is unaffected — it does not
# traverse the bridge).
# ============================================================================

apply_network_delay() {
    local delay_ms=$1
    [ "$delay_ms" -eq 0 ] && return 0

    log "${YELLOW}Applying ${delay_ms}ms delay inside both containers...${NC}"
    log "${CYAN}  (Simulates ${delay_ms}ms network distance between VPLMN and HPLMN)${NC}"

    dexec_v tc qdisc replace dev eth0 root netem delay "${delay_ms}ms"
    log "${GREEN}  ✅ ${VPLMN_CTR} (${PC1_IP}): +${delay_ms}ms egress on eth0${NC}"

    dexec_h tc qdisc replace dev eth0 root netem delay "${delay_ms}ms"
    log "${GREEN}  ✅ ${HPLMN_CTR} (${REMOTE_PC_IP}): +${delay_ms}ms egress on eth0${NC}"

    # Verify with ping (initiator -> responder)
    local rtt
    rtt=$(dexec_v ping -c 3 -q "$REMOTE_PC_IP" 2>/dev/null | tail -1 | awk -F'/' '{print $5}' || true)
    log "${CYAN}  Measured RTT: ~${rtt}ms (expected ~$((delay_ms * 2))ms added)${NC}"
    echo ""
}

remove_network_delay() {
    local delay_ms=$1
    [ "$delay_ms" -eq 0 ] && return 0

    log "${YELLOW}Removing network delay...${NC}"
    dexec_v tc qdisc del dev eth0 root 2>/dev/null || true
    dexec_h tc qdisc del dev eth0 root 2>/dev/null || true
    log "${GREEN}  ✅ Delay removed from both containers${NC}"
}

# ============================================================================
# swanctl.conf Generation (identical to the VM version)
# ============================================================================

generate_swanctl_conf() {
    local local_addr=$1
    local remote_addr=$2
    local local_id=$3
    local remote_id=$4
    local local_cert=$5
    local ike_proposal=$6
    local start_action=$7

    cat << CONFEOF
# Auto-generated by ike_eval_docker.sh — $(date)
connections {
    upf-n9-tunnel {
        local_addrs = ${local_addr}
        remote_addrs = ${remote_addr}
        version = 2
        proposals = ${ike_proposal}
        rekey_time = 24h
        dpd_delay = 30s
        unique = replace
        local {
            auth = pubkey
            id = "${local_id}"
            certs = ${local_cert}
        }
        remote {
            auth = pubkey
            id = "${remote_id}"
        }
        children {
            n9-gtpu {
                local_ts = ${local_addr}/32[udp/2152]
                remote_ts = ${remote_addr}/32[udp/2152]
                mode = tunnel
                esp_proposals = ${ESP_PROPOSAL}
                rekey_time = 8h
                replay_window = 32
                start_action = ${start_action}
                close_action = start
                dpd_action = start
                reqid = 1
            }
        }
    }
}
CONFEOF
}

# ============================================================================
# StrongSwan Control (charon via docker exec instead of systemctl/SSH)
# ============================================================================

stop_both() {
    dexec_v swan-stop 2>/dev/null || true
    dexec_h swan-stop 2>/dev/null || true
}

start_responder() {
    # Start HPLMN (responder) first: swan-start blocks until charon is up
    # and the config (start_action = trap) is loaded.
    if ! dexec_h swan-start 2>/tmp/.swan_resp_err.$$; then
        log "${RED}  ⚠ responder swan-start failed:${NC} $(tail -1 /tmp/.swan_resp_err.$$ 2>/dev/null)"
        log "${RED}    (see: docker exec $HPLMN_CTR cat /var/log/strongswan/charon.log)${NC}"
    fi
    sleep 0.5
}

# (Initiator start + wall-clock measurement happen inside the container:
#  see container/swan-run-initiator)

patch_proposals() {
    local ike_proposal=$1
    local pc1_cert=$2
    local pc2_cert=$3

    # VPLMN config (initiator: start_action = start)
    generate_swanctl_conf \
        "$PC1_IP" "$REMOTE_PC_IP" \
        "$PC1_ID" "$PC2_ID" \
        "$pc1_cert" \
        "$ike_proposal" \
        "start" | docker exec -i "$VPLMN_CTR" tee "$SWANCTL_CONF" > /dev/null

    # HPLMN config (responder: start_action = trap)
    generate_swanctl_conf \
        "$REMOTE_PC_IP" "$PC1_IP" \
        "$PC2_ID" "$PC1_ID" \
        "$pc2_cert" \
        "$ike_proposal" \
        "trap" | docker exec -i "$HPLMN_CTR" tee "$SWANCTL_CONF" > /dev/null
}

# ============================================================================
# Pcap Timing Extraction (tshark runs inside the initiator container,
# parsing logic identical to the VM version)
#
# Handles both classical and PQ IKE handshakes, including IP-fragmented
# SA_INIT packets (large ML-KEM keys exceed the 1500-byte MTU — Docker's
# bridge/veth fragments exactly like a physical link).
#
# Output: success,sa_init_rtt_us,auth_rtt_us,total_us,processing_us
# ============================================================================

extract_all_timings() {
    local pcap_ctr=$1     # pcap path as seen INSIDE the container
    local out_file=$2     # output csv on the host

    # Check if we have type-34 (SA_INIT) packets decoded by tshark
    local sa_init_count
    sa_init_count=$(dexec_v tshark -r "$pcap_ctr" -Y "isakmp.exchangetype==34" \
        -T fields -e frame.number 2>/dev/null | wc -l || true)
    sa_init_count=${sa_init_count:-0}

    if [ "$sa_init_count" -gt 0 ]; then
        # ── Method 1: Standard parsing (SA_INIT visible) ──
        dexec_v tshark -r "$pcap_ctr" -Y "isakmp" -t e \
            -T fields \
            -e frame.time_epoch \
            -e isakmp.exchangetype \
            -e isakmp.flags \
            -e ip.src \
            -E separator=$'\t' 2>/dev/null | awk -v pc1="$PC1_IP" '
        BEGIN { FS="\t" }
        {
            epoch = $1 + 0; etype = $2 + 0; flags = $3; src = $4
            from_pc1 = (src == pc1) ? 1 : 0
            is_request = (flags == "0x08") ? 1 : 0
            is_response = (flags == "0x20") ? 1 : 0
        }
        etype == 34 && from_pc1 && is_request {
            if (auth_resp > 0 && init_req > 0 && init_resp > 0) {
                printf "success,%.0f,%.0f,%.0f,%.0f\n", \
                    (init_resp-init_req)*1e6, (auth_resp-auth_req)*1e6, \
                    (auth_resp-init_req)*1e6, (auth_req-init_resp)*1e6
            }
            init_req = epoch; init_resp = 0; auth_req = 0; auth_resp = 0; next
        }
        etype == 34 && !from_pc1 && is_response && init_req > 0 { init_resp = epoch; next }
        etype == 43 && from_pc1 && init_resp > 0 { inter_req = epoch; next }
        etype == 43 && !from_pc1 && inter_req > 0 { inter_resp = epoch; next }
        etype == 35 && from_pc1 && is_request && init_resp > 0 && auth_req == 0 { auth_req = epoch; next }
        etype == 35 && !from_pc1 && is_response && auth_req > 0 && auth_resp == 0 { auth_resp = epoch }
        END {
            if (auth_resp > 0 && init_req > 0 && init_resp > 0) {
                printf "success,%.0f,%.0f,%.0f,%.0f\n", \
                    (init_resp-init_req)*1e6, (auth_resp-auth_req)*1e6, \
                    (auth_resp-init_req)*1e6, (auth_req-init_resp)*1e6
            }
        }' > "$out_file" || true
    else
        # ── Method 2: Fallback for IP-fragmented SA_INIT (e.g. ML-KEM-1024) ──
        # Parse ALL packets: Fragmented IP = SA_INIT, ISAKMP type 35 = AUTH
        dexec_v tshark -r "$pcap_ctr" -t e \
            -T fields \
            -e frame.time_epoch \
            -e _ws.col.Protocol \
            -e ip.src \
            -e isakmp.exchangetype \
            -e isakmp.flags \
            -E separator=$'\t' 2>/dev/null | awk -v pc1="$PC1_IP" -v pc2="$REMOTE_PC_IP" '
        BEGIN { FS="\t" }
        {
            epoch = $1 + 0; proto = $2; src = $3; etype = $4 + 0; flags = $5
            from_pc1 = (src == pc1) ? 1 : 0
            from_pc2 = (src == pc2) ? 1 : 0
        }

        # Fragmented IP from PC1 = potential SA_INIT request
        proto == "IPv4" && from_pc1 && state != "got_init_req" && state != "got_init_resp" {
            # New handshake detected — emit previous if complete
            if (auth_resp > 0 && init_req > 0 && init_resp > 0) {
                printf "success,%.0f,%.0f,%.0f,%.0f\n", \
                    (init_resp-init_req)*1e6, (auth_resp-auth_req)*1e6, \
                    (auth_resp-init_req)*1e6, (auth_req-init_resp)*1e6
            }
            init_req = epoch; init_resp = 0; auth_req = 0; auth_resp = 0
            state = "got_init_req"
            next
        }

        # Fragmented IP from HPLMN after SA_INIT req = SA_INIT response
        proto == "IPv4" && from_pc2 && state == "got_init_req" {
            init_resp = epoch
            state = "got_init_resp"
            next
        }

        # IKE_AUTH (35) Request from PC1
        etype == 35 && from_pc1 && flags == "0x08" && init_resp > 0 && auth_req == 0 {
            auth_req = epoch
            next
        }

        # IKE_AUTH (35) Response from HPLMN
        etype == 35 && from_pc2 && flags == "0x20" && auth_req > 0 && auth_resp == 0 {
            auth_resp = epoch
            state = ""
        }

        # INFORMATIONAL (37) from PC1 = end of handshake, reset state for next
        etype == 37 && from_pc1 {
            state = ""
        }

        END {
            if (auth_resp > 0 && init_req > 0 && init_resp > 0) {
                printf "success,%.0f,%.0f,%.0f,%.0f\n", \
                    (init_resp-init_req)*1e6, (auth_resp-auth_req)*1e6, \
                    (auth_resp-init_req)*1e6, (auth_req-init_resp)*1e6
            }
        }' > "$out_file" || true
    fi
}

# ============================================================================
# JSON Writer (schema identical to the VM version, so existing analysis
# scripts like analyze_ike_results.py keep working)
# ============================================================================

write_json() {
    local outfile=$1 config_name=$2 ike_proposal=$3
    shift 3
    local results=("$@")
    local init_v=() auth_v=() total_v=() proc_v=() wall_v=()
    local ok=0 fail=0

    for r in "${results[@]}"; do
        IFS=',' read -r st i a t p w <<< "$r"
        if [ "$st" = "success" ]; then
            init_v+=("$i"); auth_v+=("$a"); total_v+=("$t"); proc_v+=("$p"); wall_v+=("$w")
            ok=$((ok+1))
        else
            fail=$((fail+1))
        fi
    done

    calc_stats() {
        local arr=("$@")
        [ ${#arr[@]} -eq 0 ] && { echo "0,0,0,0,0,0,0"; return; }
        printf '%s\n' "${arr[@]}" | sort -n | awk '
            {a[NR]=$1;s+=$1} END {
                n=NR;m=s/n; for(i=1;i<=n;i++)sq+=(a[i]-m)^2; sd=sqrt(sq/n);
                med=(n%2)?a[int(n/2)+1]:(a[n/2]+a[n/2+1])/2;
                p95=int(n*0.95+0.5);if(p95<1)p95=1;if(p95>n)p95=n;
                p99=int(n*0.99+0.5);if(p99<1)p99=1;if(p99>n)p99=n;
                printf "%.1f,%.1f,%d,%d,%.1f,%d,%d",m,med,a[1],a[n],sd,a[p95],a[p99]
            }'
    }

    IFS=',' read -r init_mean init_med init_min init_max init_sd init_p95 init_p99 <<< "$(calc_stats "${init_v[@]}")"
    IFS=',' read -r auth_mean auth_med auth_min auth_max auth_sd auth_p95 auth_p99 <<< "$(calc_stats "${auth_v[@]}")"
    IFS=',' read -r total_mean total_med total_min total_max total_sd total_p95 total_p99 <<< "$(calc_stats "${total_v[@]}")"
    IFS=',' read -r wall_mean wall_med wall_min wall_max wall_sd wall_p95 wall_p99 <<< "$(calc_stats "${wall_v[@]}")"

    local raw=""
    for i in "${!results[@]}"; do
        IFS=',' read -r st iv av tv pv wv <<< "${results[$i]}"
        [ -n "$raw" ] && raw+=","$'\n'
        raw+="    {\"iteration\": $((i+1)), \"ike_sa_init_rtt_us\": ${iv:-0}, \"ike_auth_rtt_us\": ${av:-0}, \"total_wire_us\": ${tv:-0}, \"local_processing_us\": ${pv:-0}, \"wall_clock_ms\": ${wv:-0}, \"status\": \"${st}\"}"
    done

    cat > "$outfile" << ENDJSON
{
  "test_type": "ike_pq_evaluation",
  "config_name": "${config_name}",
  "ike_parameters": {
    "ike_proposal": "${ike_proposal}",
    "esp_proposal": "${ESP_PROPOSAL}",
    "authentication": "${AUTH_ALGS[$config_name]}",
    "pq_algorithm": "${config_name}",
    "strongswan_version": "${SWAN_VERSION}"
  },
  "network": {
    "environment": "docker (2 containers, single host bridge)",
    "pc1_ip": "${PC1_IP}",
    "pc2_ip": "${REMOTE_PC_IP}",
    "pc1_role": "initiator (container ${VPLMN_CTR})",
    "pc2_role": "responder (container ${HPLMN_CTR})",
    "added_delay_ms_per_vm": ${NETWORK_DELAY_MS},
    "added_rtt_ms": $((NETWORK_DELAY_MS * 2))
  },
  "summary": {
    "total": ${#results[@]},
    "success": ${ok},
    "failed": ${fail},
    "success_rate_pct": $(awk "BEGIN {printf \"%.1f\", ${ok}/${#results[@]}*100}")
  },
  "ike_sa_init_rtt_us": {
    "description": "IKE_SA_INIT request to response (DH + KEM exchange)",
    "mean": $init_mean, "median": $init_med, "min": $init_min, "max": $init_max,
    "std_dev": $init_sd, "p95": $init_p95, "p99": $init_p99
  },
  "ike_auth_rtt_us": {
    "description": "IKE_AUTH request to response (certificate verification)",
    "mean": $auth_mean, "median": $auth_med, "min": $auth_min, "max": $auth_max,
    "std_dev": $auth_sd, "p95": $auth_p95, "p99": $auth_p99
  },
  "total_wire_us": {
    "description": "IKE_SA_INIT request to IKE_AUTH response (full handshake)",
    "mean": $total_mean, "median": $total_med, "min": $total_min, "max": $total_max,
    "std_dev": $total_sd, "p95": $total_p95, "p99": $total_p99
  },
  "wall_clock_ms": {
    "description": "charon start to INSTALLED (daemon startup + handshake)",
    "mean": $wall_mean, "median": $wall_med, "min": $wall_min, "max": $wall_max,
    "std_dev": $wall_sd
  },
  "raw_results": [
${raw}
  ]
}
ENDJSON
}

# ============================================================================
# Argument Parsing
# ============================================================================

[ -z "${1:-}" ] && show_usage
CONFIG_NUM="$1"
[ -n "${2:-}" ] && ITERATIONS="$2"
[ -n "${3:-}" ] && NETWORK_DELAY_MS="$3"
[[ "$CONFIG_NUM" =~ ^[1-5]$ ]] || show_usage

declare -a TEST_CONFIGS=()
case "$CONFIG_NUM" in
    1) TEST_CONFIGS=("classical_rsa") ;;
    2) TEST_CONFIGS=("mlkem768_rsa") ;;
    3) TEST_CONFIGS=("ecp256_mldsa") ;;
    4) TEST_CONFIGS=("mlkem768_mldsa") ;;
    5) TEST_CONFIGS=("classical_rsa" "mlkem768_rsa" "ecp256_mldsa" "mlkem768_mldsa") ;;
esac

# ============================================================================
# Pre-flight Checks
# ============================================================================

echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  IKE Post-Quantum Performance Evaluation (Docker)     ║${NC}"
echo -e "${BLUE}║  StrongSwan — Native ML-KEM (FIPS 203) / ML-DSA       ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Pre-flight checks...${NC}"

for cmd in docker awk sort grep stat; do
    command -v $cmd &>/dev/null || { echo -e "${RED}  ❌ $cmd missing on host${NC}"; exit 1; }
done
echo -e "${GREEN}  ✅ host tools (docker, awk, ...)${NC}"

# Containers must be up — if they aren't but the image is already built,
# start them automatically (lets the WebUI trigger runs without a manual
# `docker compose up -d` after host reboots).
ensure_containers() {
    local all_up ctr state ok
    all_up=1
    for ctr in "$VPLMN_CTR" "$HPLMN_CTR"; do
        state=$(docker inspect -f '{{.State.Running}}' "$ctr" 2>/dev/null || echo "false")
        [ "$state" = "true" ] || all_up=0
    done
    [ "$all_up" = "1" ] && return 0

    if ! docker image inspect pq-ike-strongswan:local >/dev/null 2>&1; then
        echo -e "${RED}  ❌ image pq-ike-strongswan:local not built yet — run: docker compose build${NC}"
        return 1
    fi
    if ! docker compose version >/dev/null 2>&1; then
        echo -e "${RED}  ❌ docker compose v2 not available — start containers manually${NC}"
        return 1
    fi
    echo -e "${YELLOW}  containers not running — starting (docker compose up -d)...${NC}"
    docker compose up -d >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
        ok=1
        for ctr in "$VPLMN_CTR" "$HPLMN_CTR"; do
            state=$(docker inspect -f '{{.State.Running}}' "$ctr" 2>/dev/null || echo "false")
            [ "$state" = "true" ] || ok=0
        done
        [ "$ok" = "1" ] && return 0
        sleep 1
    done
    return 1
}

if ensure_containers; then
    echo -e "${GREEN}  ✅ containers $VPLMN_CTR + $HPLMN_CTR running${NC}"
else
    echo -e "${RED}  ❌ containers not running — fix with: docker compose build && docker compose up -d${NC}"
    exit 1
fi

for cmd in tcpdump tshark swanctl pki tc; do
    dexec_v bash -c "command -v $cmd" &>/dev/null || { echo -e "${RED}  ❌ $cmd missing in container${NC}"; exit 1; }
done
echo -e "${GREEN}  ✅ container tools (tcpdump, tshark, swanctl, pki, tc)${NC}"

mkdir -p "$RESULTS_DIR" "$LOG_DIR" "$PCAP_DIR" 2>/dev/null || true
if [ ! -w "$RESULTS_DIR" ]; then
    # Docker creates missing bind-mount dirs as root when `compose up` runs
    # before the first eval. Fix ownership from inside the container (where
    # we are root) — no sudo needed on the host.
    dexec_v chown -R "$(id -u):$(id -g)" /results 2>/dev/null || true
    mkdir -p "$RESULTS_DIR" "$LOG_DIR" "$PCAP_DIR" 2>/dev/null || true
fi
[ -w "$RESULTS_DIR" ] || { echo -e "${RED}  ❌ $RESULTS_DIR not writable (try: sudo chown -R \$USER results/)${NC}"; exit 1; }
echo -e "${GREEN}  ✅ results directories writable${NC}"

# Back-compat for the testbed WebUI backend, which lists results from
# <script_dir>/ike_pq_results — point that name at results/json.
if [ ! -e ./ike_pq_results ] || [ -L ./ike_pq_results ]; then
    ln -sfn "results/json" "./ike_pq_results" 2>/dev/null || true
fi

# Start both daemons once for capability checks
stop_both
dexec_h swan-start >/dev/null 2>&1 || { echo -e "${RED}  ❌ charon failed to start on responder (check docker exec $HPLMN_CTR cat /var/log/strongswan/charon.log)${NC}"; exit 1; }
dexec_v swan-start >/dev/null 2>&1 || { echo -e "${RED}  ❌ charon failed to start on initiator${NC}"; exit 1; }
echo -e "${GREEN}  ✅ charon daemon starts in both containers${NC}"

SWAN_VERSION=$(dexec_v swanctl --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?(dr[0-9]+)?' | head -1 || true)
SWAN_VERSION="${SWAN_VERSION:-unknown}"
echo -e "${GREEN}  ✅ strongSwan version: ${SWAN_VERSION}${NC}"

# Check ML-KEM is available (initiator)
ML_KEM_COUNT=$(dexec_v swanctl --list-algs 2>/dev/null | grep -c "ML_KEM" || true)
[ "$ML_KEM_COUNT" -ge 3 ] || { echo -e "${RED}  ❌ ML-KEM algorithms not available (found $ML_KEM_COUNT, need 3)${NC}"; exit 1; }
echo -e "${GREEN}  ✅ ML-KEM-512/768/1024 available (initiator)${NC}"

# Check ML-KEM on responder
REMOTE_ML=$(dexec_h swanctl --list-algs 2>/dev/null | grep -c "ML_KEM" || true)
[ "$REMOTE_ML" -ge 3 ] || { echo -e "${RED}  ❌ HPLMN ML-KEM not available (found $REMOTE_ML)${NC}"; exit 1; }
echo -e "${GREEN}  ✅ HPLMN ML-KEM available${NC}"

# Check ML-DSA is available (for PQ auth scenarios)
if dexec_v pki --gen --type mldsa65 >/dev/null 2>&1; then
    echo -e "${GREEN}  ✅ ML-DSA support available${NC}"
else
    echo -e "${YELLOW}  ⚠ ML-DSA not available (PQ auth scenarios will fail — build with SWAN_REF=ml-dsa)${NC}"
fi

# Check PQ certificates exist
if dexec_v test -f /etc/swanctl/x509/pq-pc1-upf-cert.pem; then
    echo -e "${GREEN}  ✅ PQ certificates installed (ML-DSA-65)${NC}"
else
    echo -e "${YELLOW}  ⚠ PQ certificates not found (run: docker compose run --rm certs)${NC}"
fi

stop_both

# Capture inside the initiator container; eth0 is its only data interface
CAPTURE_IF="eth0"
echo -e "${GREEN}  ✅ Capture interface: ${CAPTURE_IF} (inside ${VPLMN_CTR})${NC}"

echo ""
echo -e "${CYAN}Plan: ${TEST_CONFIGS[*]} | $ITERATIONS iterations each${NC}"
echo -e "${CYAN}ESP:  ${ESP_PROPOSAL} (same for all)${NC}"
if [ "$NETWORK_DELAY_MS" -gt 0 ]; then
    echo -e "${CYAN}Delay: ${NETWORK_DELAY_MS}ms per container (×2 = $((NETWORK_DELAY_MS * 2))ms added RTT)${NC}"
else
    echo -e "${CYAN}Delay: none${NC}"
fi
echo ""

if [ "$NETWORK_DELAY_MS" -gt 0 ]; then
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)_delay${NETWORK_DELAY_MS}ms
else
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)_nodelay
fi

# ── Cleanup on interrupt / hangup ──
# HUP matters for WebUI integration: the backend runs this script over
# `ssh -tt`; when the SSH client is killed (Cancel button), the remote side
# receives SIGHUP — this trap then removes netem, stops tcpdump, and stops
# charon in both containers, leaving the testbed clean.
cleanup() {
    echo ""
    log "${YELLOW}Interrupted — cleaning up...${NC}"
    dexec_v pkill -x tcpdump 2>/dev/null || true
    remove_network_delay "$NETWORK_DELAY_MS" || true
    stop_both
    exit 130
}
trap cleanup INT TERM HUP

# ── Apply network delay if specified ──
apply_network_delay "$NETWORK_DELAY_MS"

# ============================================================================
# Main Test Loop
# ============================================================================

TOTAL_CONFIGS=${#TEST_CONFIGS[@]}
CONFIG_IDX=0

for config_name in "${TEST_CONFIGS[@]}"; do
    CONFIG_IDX=$((CONFIG_IDX+1))
    ike_proposal="${IKE_PROPOSALS[$config_name]}"
    pc1_cert="${PC1_CERTS[$config_name]}"
    pc2_cert="${PC2_CERTS[$config_name]}"
    config_label="${CONFIG_LABELS[$config_name]}"
    config_upper=$(echo "$config_name" | tr '[:lower:]' '[:upper:]')

    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║ [$CONFIG_IDX/$TOTAL_CONFIGS] Testing: ${config_label}${NC}"
    echo -e "${BLUE}║ IKE: ${ike_proposal} | Cert: ${pc1_cert}${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # ── Stop and patch configs ──
    log "${YELLOW}Stopping StrongSwan (both containers)...${NC}"
    stop_both

    log "${YELLOW}Patching proposals in both containers...${NC}"
    patch_proposals "$ike_proposal" "$pc1_cert" "$pc2_cert"

    # Verify
    log "${CYAN}Verification:${NC}"
    echo -n "  PC1: "; dexec_v grep "proposals" "$SWANCTL_CONF" | head -1 | tr -d ' '
    echo -n "  PC2: "; dexec_h grep "proposals" "$SWANCTL_CONF" | head -1 | tr -d ' '
    echo ""

    # ── Start long-running tcpdump inside the initiator container ──
    pcap_name="${TIMESTAMP}_${config_name}.pcap"
    pcap_file="$PCAP_DIR/$pcap_name"             # host view
    pcap_ctr="$PCAP_DIR_CTR/$pcap_name"          # container view
    td_log_ctr="$LOG_DIR_CTR/${config_name}_tcpdump.log"
    rm -f "$pcap_file" 2>/dev/null || dexec_v rm -f "$pcap_ctr"

    # Broad filter: ALL traffic to/from HPLMN on IKE ports + ESP.
    # Includes IP fragments (ML-KEM payloads exceed MTU).
    TD_FILTER="host $REMOTE_PC_IP and (udp port 500 or udp port 4500 or esp)"
    docker exec -d "$VPLMN_CTR" bash -c \
        "exec tcpdump -U -i $CAPTURE_IF -nn -w '$pcap_ctr' '$TD_FILTER' 2>'$td_log_ctr'"

    # Wait for pcap header
    for attempt in $(seq 1 30); do
        [ -f "$pcap_file" ] && { sz=$(stat -c%s "$pcap_file" 2>/dev/null || echo 0); [ "$sz" -ge 24 ] && break; }
        sleep 0.1
    done
    sleep 1
    log "${GREEN}  ✅ tcpdump running inside ${VPLMN_CTR}${NC}"
    echo ""

    # ── Run iterations ──
    log "${CYAN}Running $ITERATIONS iterations...${NC}"
    echo ""
    printf "  %-5s  %10s  %-8s\n" "ITER" "WALL_CLK" "STATUS"
    echo "  ──────────────────────────────"

    wall_times=()

    for ((i = 1; i <= ITERATIONS; i++)); do
        stop_both
        start_responder

        # charon start + load + poll-for-INSTALLED, timed INSIDE the container
        result=$(dexec_v swan-run-initiator "$TIMEOUT")
        IFS=':' read -r wall_ms poll_status <<< "$result"

        wall_times+=("$wall_ms:$poll_status")

        case "$poll_status" in
            success) color="${GREEN}" ;; *) color="${RED}" ;;
        esac
        printf "  ${color}%-5d  %7s ms  %-8s${NC}\n" "$i" "${wall_ms:-??}" "$poll_status"
        dexec_v swanctl --list-sas > "$LOG_DIR/${config_name}_iter${i}.log" 2>&1 || true
        [ "$i" -lt "$ITERATIONS" ] && sleep "$DELAY_BETWEEN"
    done

    echo "  ──────────────────────────────"

    # ── Stop tcpdump ──
    echo ""
    log "${YELLOW}Stopping tcpdump...${NC}"
    sleep 1
    dexec_v pkill -x tcpdump 2>/dev/null || true
    for _ in $(seq 1 20); do
        dexec_v pgrep -x tcpdump >/dev/null 2>&1 || break
        sleep 0.1
    done

    pcap_size=$(stat -c%s "$pcap_file" 2>/dev/null || echo 0)
    pkt_count=$(dexec_v tshark -r "$pcap_ctr" -Y "isakmp" 2>/dev/null | wc -l || true)
    log "${GREEN}  ✅ Pcap: ${pcap_size} bytes, ${pkt_count} IKE packets${NC}"

    # ── Extract timing ──
    log "${YELLOW}Extracting wire timing...${NC}"
    timing_file="/tmp/ike_timings_${config_name}.$$.csv"
    extract_all_timings "$pcap_ctr" "$timing_file"

    mapfile -t pcap_lines < "$timing_file"
    num_handshakes=${#pcap_lines[@]}
    log "${GREEN}  ✅ Found ${num_handshakes} handshakes${NC}"

    # ── Merge pcap + wall clock ──
    combined_results=()
    for ((i = 0; i < ITERATIONS; i++)); do
        IFS=':' read -r wms wst <<< "${wall_times[$i]}"
        if [ "$wst" != "success" ]; then
            combined_results+=("timeout,0,0,0,0,${wms:-0}")
            continue
        fi
        if [ "$i" -lt "$num_handshakes" ]; then
            IFS=',' read -r pst iv av tv pv <<< "${pcap_lines[$i]}"
            if [ "$pst" = "success" ]; then
                combined_results+=("success,${iv},${av},${tv},${pv},${wms}")
            else
                combined_results+=("pcap_error,0,0,0,0,${wms}")
            fi
        else
            combined_results+=("pcap_missing,0,0,0,0,${wms}")
        fi
    done

    # ── Display results table ──
    echo ""
    printf "  %-5s  %12s  %12s  %12s  %10s  %-8s\n" \
        "ITER" "INIT_RTT" "AUTH_RTT" "TOTAL_WIRE" "WALL_CLK" "STATUS"
    printf "  %-5s  %12s  %12s  %12s  %10s\n" "" "(µs)" "(µs)" "(µs)" "(ms)"
    echo "  ────────────────────────────────────────────────────────────────────────"

    for ((i = 0; i < ${#combined_results[@]}; i++)); do
        IFS=',' read -r st iv av tv pv wv <<< "${combined_results[$i]}"
        case "$st" in success) color="${GREEN}" ;; *) color="${RED}" ;; esac
        printf "  ${color}%-5d  %9s µs  %9s µs  %9s µs  %7s ms  %-8s${NC}\n" \
            "$((i+1))" "$iv" "$av" "$tv" "$wv" "$st"
    done

    echo "  ────────────────────────────────────────────────────────────────────────"

    # ── Save JSON ──
    json_file="$RESULTS_DIR/${TIMESTAMP}_ike_${config_name}.json"
    write_json "$json_file" "$config_name" "$ike_proposal" "${combined_results[@]}"

    ok_count=0; ok_total=()
    for r in "${combined_results[@]}"; do
        IFS=',' read -r st iv av tv pv wv <<< "$r"
        [ "$st" = "success" ] && { ok_count=$((ok_count+1)); ok_total+=("$tv"); }
    done
    echo ""
    if [ ${#ok_total[@]} -gt 0 ]; then
        avg_us=$(printf '%s\n' "${ok_total[@]}" | awk '{s+=$1} END {printf "%.0f", s/NR}')
        avg_ms=$(awk "BEGIN {printf \"%.2f\", $avg_us/1000}")
        log "${GREEN}  ✅ ${config_upper}: ${ok_count}/${ITERATIONS} successful${NC}"
        log "${GREEN}     Mean wire time: ${avg_us} µs (${avg_ms} ms)${NC}"
    else
        log "${RED}  ❌ ${config_upper}: ${ok_count}/${ITERATIONS}${NC}"
    fi
    log "  JSON: ${CYAN}${json_file}${NC}"
    log "  Pcap: ${CYAN}${pcap_file}${NC}"
    echo ""
    rm -f "$timing_file"
done

# ============================================================================
# Teardown and Summary
# ============================================================================

log "${YELLOW}Stopping StrongSwan in both containers...${NC}"
stop_both

# ── Remove network delay ──
remove_network_delay "$NETWORK_DELAY_MS"

trap - INT TERM HUP

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  All Tests Complete                                    ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Results: ${CYAN}${RESULTS_DIR}/${TIMESTAMP}_ike_*.json${NC}"
echo -e "  Pcaps:   ${CYAN}${PCAP_DIR}/${NC}"
echo -e "  Logs:    ${CYAN}${LOG_DIR}/ + docker exec <ctr> cat /var/log/strongswan/charon.log${NC}"
echo ""
echo -e "${CYAN}Analyze (same JSON schema as the VM testbed):${NC}"
echo -e "  python3 analyze_ike_results.py ${RESULTS_DIR}/${TIMESTAMP}_ike_*.json --chart --csv results_pq.csv"
echo ""
