#!/bin/bash

# ============================================================================
# n4_ipsec.sh — start / stop / status the N4 (PFCP) IPsec tunnel: SMF <-> UPF.
#
# The N4 tunnel terminates in two namespaces on the SAME VPLMN host:
#   • SMF end  -> inside the open5gs-smf container (charon, IKE initiator)
#   • UPF end  -> on the host (host-mode UPF, charon responder, shares the host
#                 charon with the N9 tunnel; N4 is a separate conn 'n4-smf-upf')
#
#   ./n4_ipsec.sh deploy     One-time: generate certs, install on host + into the
#                            SMF container, write both configs (does NOT start).
#   ./n4_ipsec.sh start      Bring the N4 tunnel UP  (host responder + SMF up).
#   ./n4_ipsec.sh stop       Bring the N4 tunnel DOWN (leaves N9 untouched).
#   ./n4_ipsec.sh status     Show the N4 SA on both ends.
#   ./n4_ipsec.sh cipher N   Switch ESP cipher to mode N (1-6) and restart N4 only.
#   ./n4_ipsec.sh esp-status Print the ESP cipher this N4 conn is configured with.
#
# Requires: root (sudo) for the host side; docker access for the SMF side.
# The SMF cert package + these scripts must be visible inside the container at
# $SMF_MOUNT (bind-mounted via docker-compose — see docker/n4-ipsec/README).
# ============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}==>${NC} $*"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}!${NC} $*"; }
die()  { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }

ACTION="${1:-}"
CONN="n4-smf-upf"
SMF_CTR="open5gs-smf"
SMF_MOUNT="/n4-ipsec"                 # where certs/smf is bind-mounted in the SMF

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .../docker/n4-ipsec
SMF_PKG="$SCRIPT_DIR/certs/smf"
HOST_DIR="$SCRIPT_DIR/certs/host"

# ── ESP cipher selection ────────────────────────────────────────────────────
# This N4 tunnel is fully self-contained on THIS host (SMF container + host UPF),
# so it can run a different ESP cipher from the other PLMN's N4 and from N9.
# The chosen mode (1-6, same numbering as N9's esp_config.sh) is persisted here
# and threaded into BOTH ends' configs — they are regenerated on every start, so
# the choice must be re-applied each time rather than edited in place.
declare -A ESP_CONFIGS=(
    [1]="aes128gcm16"      [2]="aes256gcm16"
    [3]="aes128-sha256"    [4]="aes256-sha256"
    [5]="null-sha256"      [6]="null-aes128gmac"
)
ESP_STATE="$SCRIPT_DIR/.n4_esp_mode"        # remembers the last-applied mode

# esp proposal string for the currently-selected mode (default AES-128-GCM).
current_esp() {
    local m=""
    [ -f "$ESP_STATE" ] && m="$(cat "$ESP_STATE" 2>/dev/null)"
    # an empty/garbage key is a 'bad array subscript' error, not a :- fallback
    [[ "$m" =~ ^[1-6]$ ]] || m=1
    echo "${ESP_CONFIGS[$m]}"
}

# sudo helper (passwordless where configured; otherwise prompts once)
SUDO="sudo"; [ "$(id -u)" -eq 0 ] && SUDO=""

have_docker() { command -v docker >/dev/null 2>&1; }
smf_running() { have_docker && $SUDO docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$SMF_CTR"; }
dexec() { $SUDO docker exec "$SMF_CTR" bash -lc "$1"; }

do_deploy() {
    info "Deploying N4 IPsec (certs + config on both ends; tunnel NOT started)..."
    [ -f "$SCRIPT_DIR/01_setup_n4_ca.sh" ] || die "01_setup_n4_ca.sh missing"
    $SUDO bash "$SCRIPT_DIR/01_setup_n4_ca.sh" || die "certificate generation failed"
    ok "certificates generated"

    local esp; esp="$(current_esp)"
    ( cd "$HOST_DIR" && $SUDO bash ./install_certs_host.sh ) || die "host cert install failed"
    $SUDO bash "$HOST_DIR/setup_ipsec_n4_host.sh" --no-start --esp "$esp" || die "host (UPF) config failed"
    ok "host (UPF) side configured (esp=$esp)"

    # SMF side needs the running container. If the stack is down (e.g. deploy is
    # run from setup.sh before 'docker compose up'), pre-stage host+certs only —
    # the SMF config is (re)applied on every 'start' anyway, so nothing is lost.
    if smf_running && dexec "test -d $SMF_MOUNT"; then
        dexec "cd $SMF_MOUNT && ./install_certs_smf.sh && ./setup_ipsec_smf.sh --no-start --esp $esp" \
            || die "SMF side config failed (inside $SMF_CTR)"
        ok "SMF side configured (inside $SMF_CTR)"
    else
        warn "$SMF_CTR not running (or $SMF_MOUNT not mounted) — SMF side will be"
        warn "applied automatically on the next '$0 start'. Certs are staged and ready."
    fi
    echo; ok "Deploy complete. Start the tunnel with: $0 start"
}

do_start() {
    local esp; esp="$(current_esp)"
    info "Starting N4 IPsec tunnel ($CONN) — esp=$esp..."
    # Host (responder) first so it is listening when the SMF initiates.
    $SUDO bash "$HOST_DIR/setup_ipsec_n4_host.sh" --esp "$esp"
    ok "host responder ready"

    smf_running || die "container $SMF_CTR is not running"
    dexec "test -d $SMF_MOUNT" || die "$SMF_MOUNT not mounted in $SMF_CTR"
    # (Re)write the SMF config each start — it does not persist across restarts —
    # then bring the conn up as initiator.
    dexec "cd $SMF_MOUNT && ./install_certs_smf.sh >/dev/null && ./setup_ipsec_smf.sh --esp $esp"
    echo; do_status
}

# Switch the ESP cipher (mode 1-6) for THIS PLMN's N4 tunnel and restart it only.
# N9 and the other PLMN's N4 are untouched (do_stop/do_start are N4-scoped).
do_cipher() {
    local m="${1:-}"
    [[ "$m" =~ ^[1-6]$ ]] || die "cipher: mode must be 1-6 (got '${m:-<none>}')"
    local esp="${ESP_CONFIGS[$m]}"
    info "Setting N4 ESP cipher -> mode $m ($esp); restarting N4 only..."
    echo "$m" > "$ESP_STATE"
    do_stop || true
    sleep 1
    do_start
    echo; ok "N4 cipher applied: mode $m ($esp)"
}

# Print the ESP cipher this host's N4 conn is currently configured with (reads
# the live drop-in, the source of truth for what charon loaded).
do_esp_status() {
    local line esp
    line="$($SUDO grep -E '^\s*esp=' /etc/ipsec.d/n4-smf-upf.conf 2>/dev/null | head -1)"
    esp="$(echo "$line" | sed -E 's/.*esp=([A-Za-z0-9_-]+).*/\1/')"
    echo "N4_ESP=${esp:-unknown}"
}

do_stop() {
    info "Stopping N4 IPsec tunnel ($CONN) — N9 is left untouched..."
    if smf_running; then
        dexec "ipsec down $CONN 2>/dev/null; ipsec stop 2>/dev/null; ip xfrm state flush 2>/dev/null; ip xfrm policy flush 2>/dev/null" || true
        ok "SMF side down"
    else
        warn "$SMF_CTR not running — nothing to stop on the SMF side"
    fi
    # Host: bring only the N4 conn down; do NOT stop charon (N9 shares it).
    $SUDO ipsec down "$CONN" 2>/dev/null || true
    ok "host N4 conn down (N9 SA, if any, still up)"
}

do_status() {
    info "N4 IPsec status:"
    echo "── UPF / host ──"
    $SUDO ipsec statusall 2>/dev/null | grep -E "$CONN|ESTABLISHED|INSTALLED|bytes_" || echo "  (no N4 SA / down)"
    echo "── SMF container ──"
    if smf_running; then
        dexec "ipsec statusall 2>/dev/null | grep -E '$CONN|ESTABLISHED|INSTALLED|bytes_'" || echo "  (no N4 SA / down)"
    else
        echo "  ($SMF_CTR not running)"
    fi
}

case "$ACTION" in
    deploy)     do_deploy ;;
    start)      do_start ;;
    stop)       do_stop ;;
    status)     do_status ;;
    cipher)     do_cipher "${2:-}" ;;
    esp-status) do_esp_status ;;
    *) echo "Usage: $0 {deploy|start|stop|status|cipher <1-6>|esp-status}" >&2; exit 1 ;;
esac
