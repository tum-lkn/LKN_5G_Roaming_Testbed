#!/usr/bin/env bash
# ============================================================================
# Open5GS Testbed WebUI — Setup Script
# Interactively configures IP addresses, paths, and credentials.
# Run this from the webui/ directory on PC1 (VPLMN).
#
# Updates:  backend/app.py, frontend/index.html, start.sh
# ============================================================================

set -e

# ── Run as the normal user, not root ─────────────────────────────────────────
# Run under sudo, this would write root-owned files/backups and evaluate all the
# user checks (docker group, passwordless sudo, SSH keys) against root instead of
# the real user — so it would wrongly report "passwordless sudo enabled" and skip
# setting it up for your account. Re-exec as the invoking user; refuse a bare
# root login. (setup_sudoers.sh, called later, invokes sudo itself where needed.)
if [ "$(id -u)" -eq 0 ]; then
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        echo "setup.sh: launched as root — re-executing as '$SUDO_USER' (setup must not run as root)."
        exec sudo -u "$SUDO_USER" -H bash "$0" "$@"
    fi
    echo "ERROR: Do not run setup as root. Run ./setup.sh as your normal user."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND="$SCRIPT_DIR/backend/app.py"
FRONTEND="$SCRIPT_DIR/frontend/index.html"

# ── Colors ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║       Open5GS Testbed WebUI — Interactive Setup          ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── Validate project structure ──
MISSING=()  
[[ ! -f "$BACKEND" ]]  && MISSING+=("backend/app.py")
[[ ! -f "$FRONTEND" ]] && MISSING+=("frontend/index.html")

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo -e "${RED}ERROR: Missing files in $SCRIPT_DIR:${NC}"
    for f in "${MISSING[@]}"; do echo -e "  ${RED}✗${NC} $f"; done
    echo ""
    echo "Expected directory layout:"
    echo "  webui/"
    echo "  ├── backend/app.py"
    echo "  ├── frontend/index.html"
    echo "  └── setup.sh   ← you are here"
    exit 1
fi

# ── Backup originals ──
TS=$(date +%Y%m%d_%H%M%S)
echo -e "${YELLOW}Creating backups...${NC}"
cp "$BACKEND"  "${BACKEND}.bak.${TS}"  && echo -e "  ${GREEN}✓${NC} backend/app.py.bak.${TS}"
cp "$FRONTEND" "${FRONTEND}.bak.${TS}" && echo -e "  ${GREEN}✓${NC} frontend/index.html.bak.${TS}"
echo ""

# ── Prompt helper ──
ask() {
    local prompt="$1" default="$2" result
    if [[ -n "$default" ]]; then
        read -rp "$(echo -e "  ${BOLD}${prompt}${NC} [${default}]: ")" result
        echo "${result:-$default}"
    else
        read -rp "$(echo -e "  ${BOLD}${prompt}${NC}: ")" result
        echo "$result"
    fi
}

# ── Detect current values from backend ──
cur_val() { grep -oP "$1" "$BACKEND" 2>/dev/null | head -1 || echo ""; }

CUR_PC1_IP=$(grep -oP '^VPLMN_IP\s*=\s*"\K[^"]+' "$BACKEND" | head -1)
CUR_PC2_IP=$(grep -oP '^HPLMN_IP\s*=\s*"\K[^"]+' "$BACKEND" | head -1)
CUR_USER=$(grep -oP '^VPLMN_USER\s*=\s*"\K[^"]+' "$BACKEND" | head -1)
CUR_PC2_USER=$(grep -oP '^HPLMN_USER\s*=\s*"\K[^"]+' "$BACKEND" | head -1)
CUR_VPLMN_PATH=$(grep '"local"' "$BACKEND" | grep -oP '"path":\s*"\K[^"]+' | head -1)
CUR_HPLMN_PATH=$(grep '"remote"' "$BACKEND" | grep -oP '"path":\s*"\K[^"]+' | head -1)
CUR_PR_IMAGE=$(grep '"packetrusher"' "$BACKEND" | grep -oP '"image":\s*"\K[^"]+' | head -1)
CUR_PR_NETWORK=$(grep '"packetrusher"' "$BACKEND" | grep -oP '"network":\s*"\K[^"]+' | head -1)
CUR_PR_IP=$(grep '"packetrusher"' "$BACKEND" | grep -oP '"ip":\s*"\K[^"]+' | head -1)
CUR_PR_CFGPATH=$(grep '"packetrusher"' "$BACKEND" | grep -oP '"config_path":\s*"\K[^"]+' | head -1)
CUR_HPLMN_PEER=$(grep 'HPLMN_PEER_IP' "$BACKEND" | grep -oP '"\K[\d.]+' | head -1)
CUR_VPLMN_PEER=$(grep 'VPLMN_PEER_IP' "$BACKEND" | grep -oP '"\K[\d.]+' | head -1)
CUR_SERVER_IP=$(grep -oP 'const SERVER_IP\s*=\s*"\K[^"]+' "$FRONTEND" | head -1)
CUR_SERVER_USER=$(grep -oP 'const SERVER_USER\s*=\s*"\K[^"]+' "$FRONTEND" | head -1)

# Try to auto-detect local IP and testbed path
AUTO_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[\d.]+' || echo "")
AUTO_TESTBED=$(dirname "$SCRIPT_DIR")

# ════════════════════════════════════════════════════════════════════════════
# Gather input
# ════════════════════════════════════════════════════════════════════════════

echo -e "${CYAN}── PC1 (VPLMN — This Machine) ─────────────────────────────${NC}"
echo ""
PC1_IP=$(ask "PC1 IP address" "${CUR_PC1_IP:-$AUTO_IP}")
PC1_USER=$(ask "SSH username on PC1" "${CUR_USER:-$(whoami)}")
PC1_TESTBED=$(ask "VPLMN testbed path on PC1" "${CUR_VPLMN_PATH:-$AUTO_TESTBED}")

echo ""
echo -e "${CYAN}── PC2 (HPLMN — Remote Machine) ────────────────────────────${NC}"
echo ""
PC2_IP=$(ask "PC2 IP address" "${CUR_PC2_IP}")
PC2_USER=$(ask "SSH username on PC2" "${CUR_PC2_USER:-$PC1_USER}")
PC2_TESTBED=$(ask "HPLMN testbed path on PC2" "${CUR_HPLMN_PATH:-${AUTO_TESTBED/VPLMN/HPLMN}}")

echo ""
echo -e "${CYAN}── PacketRusher Configuration ───────────────────────────────${NC}"
echo ""
PR_IMAGE=$(ask "Docker image name or tag" "${CUR_PR_IMAGE:-packetrusher:20250225}")
PR_NETWORK=$(ask "Docker network name" "${CUR_PR_NETWORK:-my_second_network}")
PR_IP=$(ask "Container IP on Docker network" "${CUR_PR_IP:-192.168.70.190}")
PR_CFGPATH=$(ask "PacketRusher configs directory" "${CUR_PR_CFGPATH:-${PC1_TESTBED}/configs/Packetrusher_Configs}")

echo ""
echo -e "${CYAN}── IPsec Configuration ──────────────────────────────────────${NC}"
echo -e "  ${YELLOW}(Peer IPs may differ from machine IPs if using separate tunnel interfaces.${NC}"
echo -e "  ${YELLOW} Press Enter to use the machine IP.)${NC}"
echo ""
IPSEC_VPLMN=$(ask "PC1 IPsec peer IP" "${CUR_VPLMN_PEER:-$PC1_IP}")
IPSEC_HPLMN=$(ask "PC2 IPsec peer IP" "${CUR_HPLMN_PEER:-$PC2_IP}")

echo ""
echo -e "${CYAN}── Performance / Automation Server ─────────────────────────${NC}"
echo ""
SERVER_IP=$(ask "Server IP (iperf3 / automation)" "${CUR_SERVER_IP:-10.0.0.30}")
SERVER_USER=$(ask "SSH username on server" "${CUR_SERVER_USER:-roaming}")

# ════════════════════════════════════════════════════════════════════════════
# Summary
# ════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Configuration Summary${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}PC1 (VPLMN):${NC}"
echo -e "    IP:           ${GREEN}${PC1_IP}${NC}"
echo -e "    User:         ${PC1_USER}"
echo -e "    Testbed:      ${PC1_TESTBED}"
echo ""
echo -e "  ${BOLD}PC2 (HPLMN):${NC}"
echo -e "    IP:           ${GREEN}${PC2_IP}${NC}"
echo -e "    User:         ${PC2_USER}"
echo -e "    Testbed:      ${PC2_TESTBED}"
echo ""
echo -e "  ${BOLD}PacketRusher:${NC}"
echo -e "    Image:        ${PR_IMAGE}"
echo -e "    Network:      ${PR_NETWORK}"
echo -e "    Container IP: ${PR_IP}"
echo -e "    Config path:  ${PR_CFGPATH}"
echo ""
echo -e "  ${BOLD}IPsec Peers:${NC}  ${IPSEC_VPLMN}  ↔  ${IPSEC_HPLMN}"
echo -e "  ${BOLD}Server IP:${NC}    ${SERVER_IP}"
echo -e "  ${BOLD}Server User:${NC}  ${SERVER_USER}"
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""

read -rp "$(echo -e "  ${BOLD}Apply this configuration? [Y/n]:${NC} ")" confirm
if [[ "$confirm" =~ ^[Nn]$ ]]; then
    echo -e "\n  ${YELLOW}Aborted. No changes made. Backups kept.${NC}"
    exit 0
fi

echo ""
echo -e "${YELLOW}Applying configuration...${NC}"

# ════════════════════════════════════════════════════════════════════════════
# 1. Update backend/app.py
# ════════════════════════════════════════════════════════════════════════════
echo -e "  Updating ${BOLD}backend/app.py${NC}..."

python3 - "$BACKEND" "$PC1_IP" "$PC1_USER" "$PC1_TESTBED" "$PC2_IP" "$PC2_USER" "$PC2_TESTBED" \
    "$PR_IMAGE" "$PR_NETWORK" "$PR_IP" "$PR_CFGPATH" "$IPSEC_VPLMN" "$IPSEC_HPLMN" \
    "$SERVER_IP" "$SERVER_USER" << 'PYEOF'
import re, sys

backend_path = sys.argv[1]
pc1_ip       = sys.argv[2]
pc1_user     = sys.argv[3]
pc1_testbed  = sys.argv[4]
pc2_ip       = sys.argv[5]
pc2_user     = sys.argv[6]
pc2_testbed  = sys.argv[7]
pr_image     = sys.argv[8]
pr_network   = sys.argv[9]
pr_ip        = sys.argv[10]
pr_cfgpath   = sys.argv[11]
ipsec_vplmn  = sys.argv[12]
ipsec_hplmn  = sys.argv[13]
server_ip    = sys.argv[14]
server_user  = sys.argv[15]

with open(backend_path, "r") as f:
    content = f.read()

# Update IP variable declarations (configure_ip_from_env.sh targets these same lines)
content = re.sub(r'^VPLMN_IP\s*=\s*"[\d.]+"', f'VPLMN_IP = "{pc1_ip}"', content, flags=re.MULTILINE)
content = re.sub(r'^HPLMN_IP\s*=\s*"[\d.]+"', f'HPLMN_IP = "{pc2_ip}"', content, flags=re.MULTILINE)
content = re.sub(r'^VPLMN_USER\s*=\s*"[^"]*"', f'VPLMN_USER = "{pc1_user}"', content, flags=re.MULTILINE)
content = re.sub(r'^HPLMN_USER\s*=\s*"[^"]*"', f'HPLMN_USER = "{pc2_user}"', content, flags=re.MULTILINE)
print("    ✓ VPLMN_IP / HPLMN_IP / VPLMN_USER / HPLMN_USER declarations updated")

# The perf/iperf server the "Server IP" answer refers to. The frontend's
# const SERVER_IP is updated below; without these the backend kept a stale
# PERF_SERVER_IP and the two halves disagreed — and since the ping targets
# default to it, pings would go to the previous operator's server.
content = re.sub(r'^(PERF_SERVER_IP\s*=\s*")[^"]*(")',
                 rf'\g<1>{server_ip}\g<2>', content, flags=re.MULTILINE)
content = re.sub(r'^(PERF_SERVER_USER\s*=\s*")[^"]*(")',
                 rf'\g<1>{server_user}\g<2>', content, flags=re.MULTILINE)
print(f"    ✓ PERF_SERVER_IP → {server_ip} / PERF_SERVER_USER → {server_user}")

# ── CONFIG: patch individual values, never regenerate the block ──
#
# This used to regex out the whole `CONFIG = { ... }` block and replace it with a
# literal template written here. That silently deleted every key the template did
# not know about. When app.py's CONFIG gained "post_quantum", the next setup run
# erased it — while the CONFIG["post_quantum"] lookups elsewhere in app.py
# survived, because only the dict was rewritten. Those lookups live inside
# functions, so the backend still imported and started fine, and the damage only
# surfaced as a KeyError when someone opened the PQ tab. Every key added upstream
# met the same fate on the next setup run.
#
# Patching values in place means unknown and future keys pass through untouched.
#
# Only values that cannot be derived are written. app.py computes its local paths
# from VPLMN_DIR (its own location on disk), which is correct for every user on
# every machine; the old template overwrote those with literals baked from one
# developer's home directory, which is what broke setup on a second VM with
# "PermissionError: '/home/<other-user>'".
def sub_value(pattern, repl, label):
    global content
    new, n = re.subn(pattern, repl, content)
    if n:
        content = new
        print(f"    ✓ {label}")
    else:
        print(f"    - {label}: pattern not found, left unchanged")

# The HPLMN path lives on the other machine, so it cannot be derived here.
sub_value(r'("remote"\s*:\s*\{[^}]*?"path":\s*")[^"]*(")',
          rf'\g<1>{pc2_testbed}\g<2>', 'CONFIG["remote"]["path"]')

# PacketRusher deployment values — real per-deployment configuration.
sub_value(r'("packetrusher"\s*:\s*\{[^}]*?"image":\s*")[^"]*(")',
          rf'\g<1>{pr_image}\g<2>', 'CONFIG["packetrusher"]["image"]')
sub_value(r'("packetrusher"\s*:\s*\{[^}]*?"network":\s*")[^"]*(")',
          rf'\g<1>{pr_network}\g<2>', 'CONFIG["packetrusher"]["network"]')
sub_value(r'("packetrusher"\s*:\s*\{[^}]*?"ip":\s*")[^"]*(")',
          rf'\g<1>{pr_ip}\g<2>', 'CONFIG["packetrusher"]["ip"]')

# config_path defaults to <testbed>/configs/Packetrusher_Configs, which app.py
# already derives from VPLMN_DIR. Only write a literal when the operator pointed
# it somewhere else — otherwise leave the portable derived form alone.
default_cfgpath = f"{pc1_testbed.rstrip('/')}/configs/Packetrusher_Configs"
if pr_cfgpath and pr_cfgpath.rstrip('/') != default_cfgpath:
    sub_value(r'("packetrusher"\s*:\s*\{[^}]*?"config_path":\s*)(?:"[^"]*"|os\.path\.join\([^)]*\))',
              rf'\g<1>"{pr_cfgpath}"', 'CONFIG["packetrusher"]["config_path"]')
else:
    print('    - CONFIG["packetrusher"]["config_path"]: left derived from VPLMN_DIR')

# CONFIG["local"]["path"], results_dir, configs_dir, testbed_dir and the script
# paths are intentionally NOT written: app.py derives them all from VPLMN_DIR.
print('    - CONFIG["local"] / results_dir / testbed_dir: left derived from VPLMN_DIR')

# Replace IPsec peer IPs
content = re.sub(r'HPLMN_PEER_IP\s*=\s*"[^"]*"', f'HPLMN_PEER_IP = "{ipsec_hplmn}"', content)
content = re.sub(r'VPLMN_PEER_IP\s*=\s*"[^"]*"', f'VPLMN_PEER_IP = "{ipsec_vplmn}"', content)
print("    ✓ IPsec peer IPs updated")

with open(backend_path, "w") as f:
    f.write(content)
PYEOF

# ════════════════════════════════════════════════════════════════════════════
# 2. Update frontend/index.html
# ════════════════════════════════════════════════════════════════════════════
echo -e "  Updating ${BOLD}frontend/index.html${NC}..."

python3 - "$FRONTEND" "$PC1_IP" "$PC2_IP" "$SERVER_IP" "$SERVER_USER" << 'PYEOF'
import re, sys

frontend_path = sys.argv[1]
pc1_ip      = sys.argv[2]
pc2_ip      = sys.argv[3]
server_ip   = sys.argv[4]
server_user = sys.argv[5] if len(sys.argv) > 5 else ''

with open(frontend_path, "r") as f:
    content = f.read()

changes = 0

# Update const VPLMN_IP / HPLMN_IP declarations (same anchor used by configure_ip_from_env.sh)
new_content = re.sub(r'(const VPLMN_IP\s*=\s*")[\d.]+"', rf'\g<1>{pc1_ip}"', content)
if new_content != content:
    changes += 1
    print(f"    ✓ const VPLMN_IP → {pc1_ip}")
content = new_content

new_content = re.sub(r'(const HPLMN_IP\s*=\s*")[\d.]+"', rf'\g<1>{pc2_ip}"', content)
if new_content != content:
    changes += 1
    print(f"    ✓ const HPLMN_IP → {pc2_ip}")
content = new_content

# Update const SERVER_IP declaration
new_content = re.sub(r'(const SERVER_IP\s*=\s*")[\d.]+"', rf'\g<1>{server_ip}"', content)
if new_content != content:
    changes += 1
    print(f"    ✓ const SERVER_IP → {server_ip}")
content = new_content

# Update const SERVER_USER declaration
if server_user:
    new_content = re.sub(r'(const SERVER_USER\s*=\s*")[^"]*"', rf'\g<1>{server_user}"', content)
    if new_content != content:
        changes += 1
        print(f"    ✓ const SERVER_USER → {server_user}")
    content = new_content

if changes == 0:
    print("    ✓ No IP changes needed (already correct)")

with open(frontend_path, "w") as f:
    f.write(content)
PYEOF

# ════════════════════════════════════════════════════════════════════════════
# Done — verify
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅ Configuration applied successfully!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Backups saved with suffix ${BOLD}.bak.${TS}${NC}"
echo ""

# ── Verify SSH ──
echo -e "${CYAN}Running verification checks...${NC}"
echo ""
if ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no "${PC2_USER}@${PC2_IP}" "echo ok" &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} SSH to ${PC2_USER}@${PC2_IP} — connected"
else
    echo -e "  ${RED}✗${NC} SSH to ${PC2_USER}@${PC2_IP} — failed"
    echo -e "    ${YELLOW}Fix with:${NC}  ssh-keygen -t ed25519 && ssh-copy-id ${PC2_USER}@${PC2_IP}"
fi

# ── Verify Docker ──
if docker --version &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} Docker — available"
else
    echo -e "  ${RED}✗${NC} Docker — not found"
fi

# ── Verify user is in the 'docker' group (backend runs docker without sudo) ──
if id -nG "$(whoami)" | tr ' ' '\n' | grep -qx docker; then
    echo -e "  ${GREEN}✓${NC} User in 'docker' group"
else
    echo -e "  ${YELLOW}⚠${NC} User not in 'docker' group"
    echo -e "    ${YELLOW}Fix with:${NC}  sudo usermod -aG docker $(whoami)   (then log out and back in)"
fi

# ── Verify / set up passwordless sudo ──
# Batch runs apply delays with `sudo tc` / `sudo docker` non-interactively; without
# passwordless sudo they fail ("Failed to apply N6 delay on local UPF").
SETUP_SUDOERS="$(dirname "$SCRIPT_DIR")/lib/setup/setup_sudoers.sh"
if sudo -n true 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} Passwordless sudo — enabled"
elif [[ -f "$SETUP_SUDOERS" ]]; then
    echo -e "  ${YELLOW}⚠${NC} Passwordless sudo — not enabled (required for batch delay commands)"
    read -rp "    Set it up now for $(whoami)? [Y/n]: " _sudo_ans
    if [[ ! "$_sudo_ans" =~ ^[Nn]$ ]]; then
        bash "$SETUP_SUDOERS" || echo -e "    ${YELLOW}setup_sudoers.sh did not complete — run it manually later.${NC}"
    else
        echo -e "    ${YELLOW}Skipped.${NC} Run later:  $SETUP_SUDOERS"
    fi
else
    echo -e "  ${YELLOW}⚠${NC} Passwordless sudo — not enabled, and setup_sudoers.sh not found at $SETUP_SUDOERS"
fi

# ── Verify Python packages ──
PYMISSING=""
for pkg in flask flask_cors flask_socketio matplotlib numpy; do
    python3 -c "import $pkg" 2>/dev/null || PYMISSING="$PYMISSING $pkg"
done
if [[ -z "$PYMISSING" ]]; then
    echo -e "  ${GREEN}✓${NC} Python packages — all installed"
else
    echo -e "  ${YELLOW}⚠${NC} Missing Python packages:${PYMISSING}"
    echo -e "    ${YELLOW}Will be auto-installed by start.sh, or run manually:${NC}"
    echo -e "    cd backend && source venv/bin/activate && pip install -r requirements.txt"
fi

# ── Check testbed scripts ──
TESTBED_EXPANDED=$(eval echo "$PC1_TESTBED")
if [[ -f "${TESTBED_EXPANDED}/testbed_automation.sh" ]]; then
    echo -e "  ${GREEN}✓${NC} testbed_automation.sh — found"
else
    echo -e "  ${YELLOW}⚠${NC} testbed_automation.sh — not found at ${TESTBED_EXPANDED}/"
fi
if [[ -f "${TESTBED_EXPANDED}/batch_runner.sh" ]]; then
    echo -e "  ${GREEN}✓${NC} batch_runner.sh — found"
else
    echo -e "  ${YELLOW}⚠${NC} batch_runner.sh — not found at ${TESTBED_EXPANDED}/"
fi

echo ""
echo -e "${BOLD}  To start the WebUI:${NC}"
echo -e "    cd $(dirname "$SCRIPT_DIR")/webui"
echo -e "    ./start.sh start"
echo ""
echo -e "${BOLD}  Then open in browser:${NC}"
echo -e "    http://${PC1_IP}:9091"
echo ""
