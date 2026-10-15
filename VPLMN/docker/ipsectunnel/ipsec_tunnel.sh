#!/bin/bash
# ============================================================================
# ipsec_tunnel.sh — start / stop the N9 IPsec tunnel on BOTH PCs at once.
#
# Same script lives in docker/ipsectunnel/ of BOTH repos; it auto-detects which PC it
# is running on (from its own path) and drives the other PC over SSH.
#
#   ./ipsec_tunnel.sh start    Start IPsec on both PCs (runs 03_setup_* ; PC2 first, then PC1)
#   ./ipsec_tunnel.sh stop     Stop IPsec on both PCs (ipsec stop + flush xfrm state/policy)
#   ./ipsec_tunnel.sh status   Show the SA on both PCs
#
# PC1 = VPLMN (auto=start, initiator)   PC2 = HPLMN (auto=add, responder)
# Requires: SSH key auth to the other PC and passwordless (or cached) sudo on both.
# ============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}==>${NC} $*"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}!${NC} $*"; }
die()  { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }

ACTION="${1:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .../{VPLMN|HPLMN}/docker/ipsectunnel
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_DIR/.env"
[[ -f "$ENV_FILE" ]] || die ".env not found at $ENV_FILE"

get_env() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d'=' -f2 | tr -d '[:space:]'; }
VPLMN_IP="$(get_env VPLMN_IP)";     HPLMN_IP="$(get_env HPLMN_IP)"
VPLMN_USER="$(get_env VPLMN_USER)"; HPLMN_USER="$(get_env HPLMN_USER)"
[[ -n "$VPLMN_IP" && -n "$HPLMN_IP" ]] || die "VPLMN_IP / HPLMN_IP missing in $ENV_FILE"
VPLMN_USER="${VPLMN_USER:-$(whoami)}"; HPLMN_USER="${HPLMN_USER:-$(whoami)}"

# Which PC are we on? Prefer the machine's real IP (robust even if the "wrong"
# repo copy is run); fall back to the repo path this script lives in.
LOCAL_IPS="$(hostname -I 2>/dev/null) $(ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ')"
if   grep -qFw "$VPLMN_IP" <<<"$LOCAL_IPS"; then LOCAL_ROLE="PC1"
elif grep -qFw "$HPLMN_IP" <<<"$LOCAL_IPS"; then LOCAL_ROLE="PC2"
else
    case "$PROJECT_DIR" in
        *VPLMN*) LOCAL_ROLE="PC1" ;;
        *HPLMN*) LOCAL_ROLE="PC2" ;;
        *) die "Cannot determine whether this is VPLMN or HPLMN (IP not local, path unknown)" ;;
    esac
fi

# Per-endpoint settings
PC1_IP="$VPLMN_IP"; PC1_USER="$VPLMN_USER"; PC1_REPO="VPLMN"; PC1_DIR="pc1"; PC1_SCRIPT="03_setup_ipsec_pc1_cert.sh"; PC1_CONN="pc1-to-pc2-gtpu-tunnel-cert"
PC2_IP="$HPLMN_IP"; PC2_USER="$HPLMN_USER"; PC2_REPO="HPLMN"; PC2_DIR="pc2"; PC2_SCRIPT="03_setup_ipsec_pc2_cert.sh"; PC2_CONN="pc2-to-pc1-gtpu-tunnel-cert"

# Where the pcX cert dir lives for an endpoint: absolute if local, ~-based if remote (SSH expands ~ as the remote user).
certdir_for() {
    local ep="$1" sub repo
    if [[ "$ep" == "PC1" ]]; then sub="$PC1_DIR"; repo="$PC1_REPO"; else sub="$PC2_DIR"; repo="$PC2_REPO"; fi
    if [[ "$ep" == "$LOCAL_ROLE" ]]; then
        echo "$SCRIPT_DIR/ipsec_certificates/$sub"
    else
        echo "~/LKN_5G_Roaming_Testbed/$repo/docker/ipsectunnel/ipsec_certificates/$sub"
    fi
}

# Run a command at an endpoint (locally, or over SSH for the other PC).
run_at() {
    local ep="$1" cmd="$2"
    if [[ "$ep" == "$LOCAL_ROLE" ]]; then
        bash -c "$cmd"
    else
        local user ip
        if [[ "$ep" == "PC1" ]]; then user="$PC1_USER"; ip="$PC1_IP"; else user="$PC2_USER"; ip="$PC2_IP"; fi
        ssh -o ConnectTimeout=10 -o BatchMode=yes "$user@$ip" "$cmd"
    fi
}

label_for() { [[ "$1" == "PC1" ]] && echo "PC1 (VPLMN)" || echo "PC2 (HPLMN)"; }

do_start() {
    info "Starting N9 IPsec tunnel on BOTH PCs..."
    # PC2 (responder, auto=add) MUST come up before PC1 (initiator, auto=start)
    for ep in PC2 PC1; do
        local d s; d="$(certdir_for "$ep")"
        [[ "$ep" == "PC1" ]] && s="$PC1_SCRIPT" || s="$PC2_SCRIPT"
        info "$(label_for "$ep"): running $s ..."
        if run_at "$ep" "cd $d && sudo ./$s"; then
            ok "$(label_for "$ep") IPsec started"
        else
            die "$(label_for "$ep") failed to start (see output above)"
        fi
    done
    echo; do_status
}

do_stop() {
    info "Stopping N9 IPsec tunnel on BOTH PCs (both directions)..."
    local rc=0
    # Bring down ONLY the N9 conn on each side — never 'ipsec stop' or a global
    # 'ip xfrm flush', which on the VPLMN host would also tear down the N4
    # (SMF<->UPF) tunnel that shares this host's charon.
    for ep in PC1 PC2; do
        local conn; [[ "$ep" == "PC1" ]] && conn="$PC1_CONN" || conn="$PC2_CONN"
        info "$(label_for "$ep"): ipsec down $conn ..."
        if run_at "$ep" "sudo ipsec down $conn 2>/dev/null; true"; then
            ok "$(label_for "$ep") N9 conn down (charon left running for N4)"
        else
            warn "$(label_for "$ep") stop reported an error"; rc=1
        fi
    done
    [[ $rc -eq 0 ]] && ok "N9 tunnel down on both PCs (N9 is now cleartext; N4 untouched)."
}

do_status() {
    info "IPsec status on both PCs:"
    for ep in PC1 PC2; do
        echo "── $(label_for "$ep") ──"
        run_at "$ep" "sudo ipsec statusall 2>/dev/null | grep -E 'ESTABLISHED|INSTALLED|bytes_'" \
            || echo "  (no active SA / tunnel down)"
    done
}

echo "This machine: $(label_for "$LOCAL_ROLE")   |   PC1=$PC1_USER@$PC1_IP  PC2=$PC2_USER@$PC2_IP"
case "$ACTION" in
    start)  do_start ;;
    stop)   do_stop ;;
    status) do_status ;;
    *) echo "Usage: $0 {start|stop|status}" >&2; exit 1 ;;
esac
