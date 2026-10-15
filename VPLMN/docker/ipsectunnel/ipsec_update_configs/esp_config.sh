#!/bin/bash

# ============================================================================
# ESP Configuration Update Script - Unified Version
# Updates ESP line in /etc/ipsec.conf on both PC1 (local) and PC2 (remote)
#
# Usage: sudo ./esp_config.sh <config_number>
#
# Config Options:
#   1 = AES-128-GCM (AEAD)
#   2 = AES-256-GCM (AEAD)
#   3 = AES-128-CBC + HMAC-SHA256
#   4 = AES-256-CBC + HMAC-SHA256
#   5 = NULL + HMAC-SHA256 (Integrity Only - NO ENCRYPTION)
#   6 = NULL + GMAC-AES128 (Integrity Only - NO ENCRYPTION)
#
# Examples:
#   sudo ./esp_config.sh 1    # Set to AES-128-GCM
#   sudo ./esp_config.sh 5    # Set to NULL + SHA256 (no encryption)
# ============================================================================

set -e

# Remote PC (PC2 / HPLMN) settings — sourced from .env so they follow the
# operator's environment (falls back to the templated values if .env is absent).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../../../.env"        # .../VPLMN/.env
get_env() { [ -f "$ENV_FILE" ] || return 0; grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d'=' -f2 | tr -d '[:space:]'; }
HPLMN_IP="$(get_env HPLMN_IP)";          HPLMN_IP="${HPLMN_IP:-10.162.149.24}"
REMOTE_PC_USER="$(get_env HPLMN_USER)";  REMOTE_PC_USER="${REMOTE_PC_USER:-wassim}"

# This script runs under sudo (root) so it can edit /etc/ipsec.conf and restart
# strongSwan locally. But its SSH to PC2 must NOT run as root: root's ~/.ssh has
# no known_hosts entry or key for PC2, which fails with "Host key verification
# failed". Re-drop to the login user ($SUDO_USER) — the same identity that set up
# passwordless SSH to PC2 — and disable strict host-key prompting (matches the
# WebUI backend's own SSH). Falls back to a plain ssh when not run via sudo.
SSH_OPTS="-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no"
ssh_pc2() {
    if [ "${EUID:-$(id -u)}" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
        sudo -u "$SUDO_USER" ssh $SSH_OPTS "$REMOTE_PC_USER@$HPLMN_IP" "$@"
    else
        ssh $SSH_OPTS "$REMOTE_PC_USER@$HPLMN_IP" "$@"
    fi
}

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================================
# ESP Configuration Definitions
# ============================================================================
declare -A ESP_CONFIGS
ESP_CONFIGS[1]="aes128gcm16"
ESP_CONFIGS[2]="aes256gcm16"
ESP_CONFIGS[3]="aes128-sha256"
ESP_CONFIGS[4]="aes256-sha256"
ESP_CONFIGS[5]="null-sha256"
ESP_CONFIGS[6]="null-aes128gmac"

declare -A ESP_NAMES
ESP_NAMES[1]="AES-128-GCM (AEAD)"
ESP_NAMES[2]="AES-256-GCM (AEAD)"
ESP_NAMES[3]="AES-128-CBC + HMAC-SHA256-128"
ESP_NAMES[4]="AES-256-CBC + HMAC-SHA256-128"
ESP_NAMES[5]="NULL + HMAC-SHA256-128 (Integrity Only)"
ESP_NAMES[6]="NULL + GMAC-AES128 (Integrity Only)"

declare -A ESP_TYPES
ESP_TYPES[1]="AEAD"
ESP_TYPES[2]="AEAD"
ESP_TYPES[3]="Separate Enc+Auth"
ESP_TYPES[4]="Separate Enc+Auth"
ESP_TYPES[5]="Integrity Only"
ESP_TYPES[6]="Integrity Only"

# ============================================================================
# Functions
# ============================================================================

show_usage() {
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE} ESP Configuration Update Script${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo ""
    echo -e "${CYAN}Usage:${NC} sudo $0 <config_number>"
    echo ""
    echo -e "${CYAN}Available Configurations:${NC}"
    echo ""
    echo "  1 = AES-128-GCM          (AEAD, fast, hardware accelerated)"
    echo "  2 = AES-256-GCM          (AEAD, stronger key)"
    echo "  3 = AES-128-CBC + SHA256 (Separate encryption + integrity)"
    echo "  4 = AES-256-CBC + SHA256 (Separate, stronger key)"
    echo -e "  5 = NULL + SHA256        ${RED}(⚠️  NO ENCRYPTION - Integrity only)${NC}"
    echo -e "  6 = NULL + GMAC          ${RED}(⚠️  NO ENCRYPTION - Integrity only)${NC}"
    echo ""
    echo -e "${CYAN}Examples:${NC}"
    echo "  sudo $0 1    # Set ESP to AES-128-GCM"
    echo "  sudo $0 3    # Set ESP to AES-128-CBC + SHA256"
    echo "  sudo $0 5    # Set ESP to NULL + SHA256 (no encryption)"
    echo ""
    echo -e "${CYAN}Quick Reference Table:${NC}"
    echo "  ┌────────┬──────────────────┬─────────────────┬──────────────┐"
    echo "  │ Config │ Encryption       │ Integrity       │ Type         │"
    echo "  ├────────┼──────────────────┼─────────────────┼──────────────┤"
    echo "  │   1    │ AES-128-GCM      │ Built-in (GCM)  │ AEAD         │"
    echo "  │   2    │ AES-256-GCM      │ Built-in (GCM)  │ AEAD         │"
    echo "  │   3    │ AES-128-CBC      │ HMAC-SHA256-128 │ Separate     │"
    echo "  │   4    │ AES-256-CBC      │ HMAC-SHA256-128 │ Separate     │"
    echo "  │   5    │ NULL (none)      │ HMAC-SHA256-128 │ Integrity    │"
    echo "  │   6    │ NULL (none)      │ GMAC-AES128     │ Integrity    │"
    echo "  └────────┴──────────────────┴─────────────────┴──────────────┘"
    echo ""
}

show_config_table() {
    echo ""
    echo -e "${CYAN}All ESP Configurations:${NC}"
    echo "  ┌────────┬─────────────────────┬──────────────────────────────────────┐"
    echo "  │ Config │ strongSwan ESP      │ Description                          │"
    echo "  ├────────┼─────────────────────┼──────────────────────────────────────┤"
    echo "  │   1    │ aes128gcm16!        │ AES-128-GCM (AEAD)                   │"
    echo "  │   2    │ aes256gcm16!        │ AES-256-GCM (AEAD)                   │"
    echo "  │   3    │ aes128-sha256!      │ AES-128-CBC + HMAC-SHA256-128        │"
    echo "  │   4    │ aes256-sha256!      │ AES-256-CBC + HMAC-SHA256-128        │"
    echo "  │   5    │ null-sha256!        │ NULL + HMAC-SHA256-128 (NO ENCRYPT)  │"
    echo "  │   6    │ null-aes128gmac!    │ NULL + GMAC-AES128 (NO ENCRYPT)      │"
    echo "  └────────┴─────────────────────┴──────────────────────────────────────┘"
    echo ""
}

update_esp_config() {
    local file=$1
    local esp_value=$2
    
    if [ ! -f "$file" ]; then
        echo "ERROR: $file not found!"
        return 1
    fi
    
    if grep -q "^\s*esp=" "$file"; then
        sed -i "s|^\(\s*\)esp=.*|\\1esp=${esp_value}!|" "$file"
        return 0
    else
        echo "WARNING: No ESP line found in $file"
        return 1
    fi
}

# ============================================================================
# Main Script
# ============================================================================

# Check if config number provided
if [ -z "$1" ]; then
    show_usage
    exit 1
fi

CONFIG_NUM="$1"

# Validate config number
if ! [[ "$CONFIG_NUM" =~ ^[1-6]$ ]]; then
    echo -e "${RED}ERROR: Invalid configuration number '$CONFIG_NUM'${NC}"
    echo "       Please provide a number between 1 and 6."
    echo ""
    show_usage
    exit 1
fi

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}ERROR: Please run as root (use sudo)${NC}"
    echo "       Example: sudo $0 $CONFIG_NUM"
    exit 1
fi

# Get ESP config and name
ESP_CONFIG="${ESP_CONFIGS[$CONFIG_NUM]}"
ESP_NAME="${ESP_NAMES[$CONFIG_NUM]}"
ESP_TYPE="${ESP_TYPES[$CONFIG_NUM]}"

# ============================================================================
# Display Header
# ============================================================================
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE} ESP Configuration Update Script${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
echo -e "${CYAN}Selected Configuration:${NC}"
echo -e "  Config Number: ${GREEN}$CONFIG_NUM${NC}"
echo -e "  ESP String:    ${GREEN}${ESP_CONFIG}!${NC}"
echo -e "  Description:   ${GREEN}${ESP_NAME}${NC}"
echo -e "  Type:          ${GREEN}${ESP_TYPE}${NC}"
echo ""

# Warning for NULL encryption configs
if [ "$CONFIG_NUM" -eq 5 ] || [ "$CONFIG_NUM" -eq 6 ]; then
    echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ⚠️  WARNING: NO ENCRYPTION - INTEGRITY ONLY!              ║${NC}"
    echo -e "${RED}║  Data will be readable by anyone who captures traffic.     ║${NC}"
    echo -e "${RED}║  Use only for testing/research purposes.                   ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
fi

# ============================================================================
# Update PC1 (Local)
# ============================================================================
echo -e "${YELLOW}[PC1 - Local]${NC} Updating ESP configuration..."

if update_esp_config "/etc/ipsec.conf" "$ESP_CONFIG"; then
    echo -e "${GREEN}  ✅ PC1: ESP updated to ${ESP_CONFIG}!${NC}"
else
    echo -e "${RED}  ❌ PC1: Failed to update ESP configuration${NC}"
    exit 1
fi

# ============================================================================
# Update PC2 (Remote via SSH)
# ============================================================================
echo ""
echo -e "${YELLOW}[PC2 - Remote]${NC} Updating ESP configuration via SSH..."

REMOTE_CMD="sudo sed -i 's|^\(\s*\)esp=.*|\\1esp=${ESP_CONFIG}!|' /etc/ipsec.conf"

if ssh_pc2 "$REMOTE_CMD"; then
    echo -e "${GREEN}  ✅ PC2: ESP updated to ${ESP_CONFIG}!${NC}"
else
    echo -e "${RED}  ❌ PC2: Failed to update ESP configuration${NC}"
    exit 1
fi

# ============================================================================
# Re-establish ONLY the N9 tunnel with the new cipher
# ============================================================================
# esp_config runs on PC1 (VPLMN, initiator). The host's single charon ALSO
# serves the N4 (SMF<->UPF) tunnel, so we must NOT 'ipsec stop' or flush XFRM
# globally — that would tear down N4 as collateral. Instead: bring ONLY the N9
# conn down on each side, 'ipsec reload' so charon picks up the new esp= (charon
# and the N4 SA stay up), then 'ipsec up' the N9 conn (it is auto=add, i.e. never
# self-initiates, so it MUST be brought up explicitly). PC1 initiates; PC2 just
# needs the reloaded config to respond.
PC1_CONN="pc1-to-pc2-gtpu-tunnel-cert"     # local  (VPLMN, initiator)
PC2_CONN="pc2-to-pc1-gtpu-tunnel-cert"     # remote (HPLMN, responder)

echo ""
echo -e "${YELLOW}Re-establishing the N9 tunnel with the new cipher (N4 left untouched)...${NC}"

# charon usually stays up (N4 and/or N9 keep it running); start it only if down.
if ! pgrep -x charon >/dev/null 2>&1; then
    echo "  PC1: charon not running — starting it..."; ipsec start; sleep 2
fi
ssh_pc2 "pgrep -x charon >/dev/null 2>&1 || { sudo ipsec start; sleep 2; }" 2>/dev/null || true

echo "  Bringing the N9 conn DOWN on both PCs (charon + N4 stay up)..."
ipsec down "$PC1_CONN" 2>/dev/null || true
ssh_pc2 "sudo ipsec down $PC2_CONN 2>/dev/null; true" || true

echo "  Reloading strongSwan config on both PCs (loads the new esp=)..."
ipsec rereadall 2>/dev/null || true
ipsec reload 2>/dev/null || true
ssh_pc2 "sudo ipsec rereadall 2>/dev/null; sudo ipsec reload 2>/dev/null; true" || true
sleep 2

echo "  Bringing the N9 conn UP (PC1 initiates, PC2 responds)..."
ipsec up "$PC1_CONN" || true

sleep 3

# ============================================================================
# Verify Configuration
# ============================================================================
echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE} Verification${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

echo -e "${YELLOW}[PC1]${NC} Current ESP configuration:"
echo -n "  "
grep "^\s*esp=" /etc/ipsec.conf | head -1

echo ""
echo -e "${YELLOW}[PC2]${NC} Current ESP configuration:"
echo -n "  "
ssh_pc2 "grep '^\s*esp=' /etc/ipsec.conf | head -1"

echo ""
echo -e "${YELLOW}Tunnel Status:${NC}"
if ipsec status 2>/dev/null | grep -q "ESTABLISHED"; then
    echo -e "${GREEN}  ✅ IPsec tunnel ESTABLISHED${NC}"
    echo ""
    ipsec status | grep -E "ESTABLISHED|ESP:" | sed 's/^/  /'
else
    echo -e "${YELLOW}  ⏳ Waiting for tunnel establishment...${NC}"
    sleep 5
    if ipsec status 2>/dev/null | grep -q "ESTABLISHED"; then
        echo -e "${GREEN}  ✅ IPsec tunnel ESTABLISHED${NC}"
        echo ""
        ipsec status | grep -E "ESTABLISHED|ESP:" | sed 's/^/  /'
    else
        echo -e "${YELLOW}  ⚠️  Tunnel not yet established. Check with: sudo ipsec statusall${NC}"
    fi
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN} Configuration Complete${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "  Config:  ${CYAN}$CONFIG_NUM${NC} - ${ESP_NAME}"
echo -e "  ESP:     ${CYAN}${ESP_CONFIG}!${NC}"
echo ""

# Final warning reminder for NULL configs
if [ "$CONFIG_NUM" -eq 5 ] || [ "$CONFIG_NUM" -eq 6 ]; then
    echo -e "${RED}  ⚠️  REMINDER: Traffic is NOT encrypted!${NC}"
    echo ""
fi

echo -e "${CYAN}Useful commands:${NC}"
echo "  sudo ipsec statusall         # Check tunnel details"
echo "  sudo ip xfrm state           # View negotiated algorithms"
echo "  sudo tcpdump -i eth0 esp     # Monitor ESP packets"
echo ""
