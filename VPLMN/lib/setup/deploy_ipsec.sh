#!/bin/bash
# ============================================================================
# deploy_ipsec.sh — End-to-end N9 IPsec setup across both PCs.
#
# Run this ON PC1 (VPLMN). It drives PC2 (HPLMN) over SSH and performs the
# full flow from docs/IPSEC.md:
#   [checks] strongSwan present on both sides (installs if missing)
#   [step 1] generate CA + certs on PC1            (01_setup_ca.sh)
#   [step 2] copy the pc2/ package to PC2          (scp into existing pc2 folder)
#   [step 3] install certs on PC1 and PC2          (02_install_certs_pcX.sh)
#   [prompt] ask whether to start the tunnel; if yes:
#   [step 4] start IPsec PC2 first, then PC1       (03_setup_ipsec_pcX_cert.sh)
#            then verify the SA on both ends
#
# Requirements: SSH key auth to PC2 and passwordless (or cached) sudo on both.
#
# Options:
#   --regenerate      Force regenerating the CA/certs even if they already exist
#   --yes             Don't prompt — start the tunnel automatically after setup
#   --no-start        Do the setup only; never start the tunnel
#   --remote-repo P   Path of the HPLMN repo on PC2, relative to its $HOME
#                     (default: LKN_5G_Roaming_Testbed/HPLMN)
#   -h, --help        Show this help
# ============================================================================

set -uo pipefail

# ── Colors / logging ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}==>${NC} $*"; }
ok()    { echo -e "  ${GREEN}✓${NC} $*"; }
warn()  { echo -e "  ${YELLOW}!${NC} $*"; }
die()   { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }
hdr()   { echo; echo -e "${BLUE}==========================================${NC}"; echo -e "${BLUE} $*${NC}"; echo -e "${BLUE}==========================================${NC}"; }

# ── Defaults / args ──
REGENERATE=false
AUTO_START=""          # "" = ask, "yes" = start, "no" = don't
REMOTE_REPO="LKN_5G_Roaming_Testbed/HPLMN"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --regenerate)   REGENERATE=true; shift ;;
        --yes)          AUTO_START="yes"; shift ;;
        --no-start)     AUTO_START="no"; shift ;;
        --remote-repo)  REMOTE_REPO="$2"; shift 2 ;;
        -h|--help)      awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
        *)              die "Unknown option: $1 (use --help)" ;;
    esac
done

# ── Locate local repo / load .env ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"      # .../setup
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"                     # .../VPLMN
IPSEC_DIR="$PROJECT_DIR/docker/ipsectunnel"                            # .../docker/ipsectunnel
[[ -d "$IPSEC_DIR" ]] || die "docker/ipsectunnel/ not found at $IPSEC_DIR"
ENV_FILE="$PROJECT_DIR/.env"
[[ -f "$ENV_FILE" ]] || die ".env not found at $ENV_FILE"

get_env() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d'=' -f2 | tr -d '[:space:]'; }
VPLMN_IP="$(get_env VPLMN_IP)"
HPLMN_IP="$(get_env HPLMN_IP)"
HPLMN_USER="$(get_env HPLMN_USER)"
[[ -n "$VPLMN_IP" ]]   || die "VPLMN_IP not set in .env"
[[ -n "$HPLMN_IP" ]]   || die "HPLMN_IP not set in .env"
[[ -n "$HPLMN_USER" ]] || die "HPLMN_USER not set in .env"

SSH_TARGET="${HPLMN_USER}@${HPLMN_IP}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)

# Local paths (PC1 / VPLMN)
LOCAL_PC1="$IPSEC_DIR/ipsec_certificates/pc1"
LOCAL_PC2="$IPSEC_DIR/ipsec_certificates/pc2"
# Remote paths (PC2 / HPLMN) — '~' is expanded by the remote shell
REMOTE_PC2="~/$REMOTE_REPO/docker/ipsectunnel/ipsec_certificates/pc2"

# ── SSH helpers ──
ssh_co()  { ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$@"; }              # check-only / quiet
ssh_run() { ssh "${SSH_OPTS[@]}" -t "$SSH_TARGET" "$@"; }           # run (tty for sudo)

hdr "N9 IPsec deployment"
echo "  PC1 (VPLMN, local) : $VPLMN_IP"
echo "  PC2 (HPLMN, remote): $SSH_TARGET"
echo "  Remote repo        : ~/$REMOTE_REPO"
[[ "$REGENERATE" == true ]] && echo "  Mode               : regenerate certs"

# ── Pre-flight checks ──
hdr "Checks"

info "SSH connectivity to PC2..."
ssh_co "true" 2>/dev/null || die "Cannot SSH to $SSH_TARGET (need key auth + reachable host)"
ok "SSH to $SSH_TARGET works"

info "Local sub-scripts present..."
for f in "$IPSEC_DIR/01_setup_ca.sh" \
         "$LOCAL_PC1/02_install_certs_pc1.sh" \
         "$LOCAL_PC1/03_setup_ipsec_pc1_cert.sh"; do
    [[ -f "$f" ]] || die "Missing local script: $f"
done
ok "PC1 scripts found"

info "Remote sub-scripts present..."
ssh_co "test -f $REMOTE_PC2/02_install_certs_pc2.sh && test -f $REMOTE_PC2/03_setup_ipsec_pc2_cert.sh" \
    || die "Remote scripts missing under $REMOTE_PC2 (check --remote-repo)"
ok "PC2 scripts found"

# strongSwan must exist BEFORE 02 (which calls 'ipsec pki' but does not install it)
ensure_strongswan_local() {
    if command -v ipsec >/dev/null 2>&1 && ipsec pki --help >/dev/null 2>&1; then
        ok "strongSwan present on PC1"
    else
        warn "strongSwan missing on PC1 — installing..."
        sudo apt-get update -qq && sudo apt-get install -y strongswan strongswan-pki strongswan-starter \
            || die "Failed to install strongSwan on PC1"
        ok "strongSwan installed on PC1"
    fi
}
ensure_strongswan_remote() {
    if ssh_co "command -v ipsec >/dev/null 2>&1 && ipsec pki --help >/dev/null 2>&1"; then
        ok "strongSwan present on PC2"
    else
        warn "strongSwan missing on PC2 — installing..."
        ssh_run "sudo apt-get update -qq && sudo apt-get install -y strongswan strongswan-pki strongswan-starter" \
            || die "Failed to install strongSwan on PC2"
        ok "strongSwan installed on PC2"
    fi
}
info "strongSwan on both sides..."
ensure_strongswan_local
ensure_strongswan_remote

# ── Step 1: generate CA + certs on PC1 ──
hdr "Step 1/3 — Generate CA & certificates (PC1)"
CERTS_EXIST=false
[[ -f "$LOCAL_PC1/ca-cert.pem" && -f "$LOCAL_PC1/pc1-upf-cert.pem" && -f "$LOCAL_PC2/pc2-upf-cert.pem" ]] && CERTS_EXIST=true

if [[ "$CERTS_EXIST" == true && "$REGENERATE" == false ]]; then
    warn "Certificates already exist — reusing them (pass --regenerate to recreate)"
else
    [[ "$CERTS_EXIST" == true ]] && warn "Regenerating: this creates a NEW CA; both PCs will be reinstalled below"
    info "Running 01_setup_ca.sh ..."
    ( cd "$IPSEC_DIR" && sudo ./01_setup_ca.sh ) || die "01_setup_ca.sh failed"
    ok "CA and certificates generated"
fi

# ── Step 2: distribute the pc2 package to PC2 ──
hdr "Step 2/3 — Distribute certs to PC2"
info "Copying pc2/* → $SSH_TARGET:$REMOTE_PC2/ ..."
scp "${SSH_OPTS[@]}" -r "$LOCAL_PC2"/* "$SSH_TARGET:$REMOTE_PC2/" >/dev/null \
    || die "scp of pc2 certificate package failed"
ssh_co "chmod +x $REMOTE_PC2/*.sh" || true
ok "pc2 package copied into existing pc2 folder"

# ── Step 3: install certs on both PCs ──
hdr "Step 3/3 — Install certificates (both PCs)"
info "PC1: 02_install_certs_pc1.sh ..."
( cd "$LOCAL_PC1" && sudo ./02_install_certs_pc1.sh ) || die "PC1 cert install failed"
ok "PC1 certificates installed"

info "PC2: 02_install_certs_pc2.sh ..."
ssh_run "cd $REMOTE_PC2 && sudo ./02_install_certs_pc2.sh" || die "PC2 cert install failed"
ok "PC2 certificates installed"

# ── Prompt: start the tunnel? ──
hdr "Setup complete"
echo "Certificates are generated, distributed, and installed on both PCs."
echo

START=""
if [[ "$AUTO_START" == "yes" ]]; then
    START="y"
elif [[ "$AUTO_START" == "no" ]]; then
    START="n"
else
    read -rp "Start the IPsec tunnel on BOTH sides now? (y/N): " ans
    [[ "$ans" =~ ^[Yy]$ ]] && START="y" || START="n"
fi

if [[ "$START" != "y" ]]; then
    # Not starting the tunnel — but still regenerate /etc/ipsec.conf on BOTH PCs
    # so the on-disk peer IPs stay consistent with .env. Without this, the config
    # keeps its old left=/right= (e.g. a stale PC1 IP) and any later start — CLI
    # or WebUI — fails with NO_PROPOSAL_CHOSEN. The 03 scripts in --no-start mode
    # write the config + secrets and prep the host, but do NOT run 'ipsec start'.
    hdr "Writing IPsec config (tunnel NOT started)"
    warn "This rewrites /etc/ipsec.conf on both PCs; any running tunnel is stopped."
    info "PC2: 03_setup_ipsec_pc2_cert.sh --no-start ..."
    ssh_run "cd $REMOTE_PC2 && sudo ./03_setup_ipsec_pc2_cert.sh --no-start" || die "PC2 config write failed"
    ok "PC2 /etc/ipsec.conf updated (peer IPs synced, tunnel not started)"
    info "PC1: 03_setup_ipsec_pc1_cert.sh --no-start ..."
    ( cd "$LOCAL_PC1" && sudo ./03_setup_ipsec_pc1_cert.sh --no-start ) || die "PC1 config write failed"
    ok "PC1 /etc/ipsec.conf updated (peer IPs synced, tunnel not started)"
    echo
    ok "Config is consistent on both PCs. Start the tunnel later (PC2 first, then PC1):"
    echo "    ssh $SSH_TARGET 'cd $REMOTE_PC2 && sudo ./03_setup_ipsec_pc2_cert.sh'"
    echo "    cd $LOCAL_PC1 && sudo ./03_setup_ipsec_pc1_cert.sh"
    echo "  ...or just use the WebUI IPsec tab (both peers now agree on IPs)."
    exit 0
fi

# ── Step 4: start IPsec — PC2 (auto=add) BEFORE PC1 (auto=start) ──
hdr "Starting IPsec"
info "PC2 first (auto=add): 03_setup_ipsec_pc2_cert.sh ..."
ssh_run "cd $REMOTE_PC2 && sudo ./03_setup_ipsec_pc2_cert.sh" || die "PC2 IPsec start failed"
ok "PC2 IPsec configured"

info "PC1 (auto=start): 03_setup_ipsec_pc1_cert.sh ..."
( cd "$LOCAL_PC1" && sudo ./03_setup_ipsec_pc1_cert.sh ) || die "PC1 IPsec start failed"
ok "PC1 IPsec configured"

# ── Verify ──
hdr "Verification"
sleep 2
echo "── PC1 (VPLMN) ──"
sudo ipsec statusall 2>/dev/null | grep -E "ESTABLISHED|INSTALLED|bytes_" || warn "No SA shown on PC1"
echo "── PC2 (HPLMN) ──"
ssh_co "sudo ipsec statusall 2>/dev/null | grep -E 'ESTABLISHED|INSTALLED|bytes_'" || warn "No SA shown on PC2"

echo
ok "Done. Look for 'ESTABLISHED' + 'INSTALLED, TUNNEL' above."
echo "  Test HR data plane, then confirm bytes_* climb (encryption active):"
echo "    sudo docker exec packetrusher ip vrf exec vrf0000001001 ping -c4 -I 10.45.0.11 8.8.8.8"
echo "    sudo ipsec statusall | grep -E 'bytes|INSTALLED'"
