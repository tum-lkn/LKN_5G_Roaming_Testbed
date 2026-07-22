#!/bin/bash

# ============================================================================
# Open5GS HPLMN — Comprehensive IP Update Script
# Reads HPLMN_IP and VPLMN_IP from .env and updates every file where they
# appear. After applying, updates its own OLD_* values for the next run.
#
# Files updated:
#   Open5GS configs : upf-docker/{upf,upf_tls}.yaml     (# HPLMN_IP tagged)
#                     smf-docker/{smf,smf_tls}.yaml      (# HPLMN_IP tagged)
#                     sepp-docker/sepp.yaml              (# VPLMN_IP tagged)
#                     docker-compose.yml                 (# VPLMN_IP tagged)
#   IPsec scripts   : docker/ipsectunnel/01_setup_ca.sh
#                     docker/ipsectunnel/ipsec_certificates/pc1/03_setup_ipsec_pc1_cert.sh
#                     docker/ipsectunnel/ipsec_certificates/pc2/03_setup_ipsec_pc2_cert.sh
# ============================================================================

echo "=========================================="
echo "  Open5GS HPLMN — IP Update (from .env)"
echo "=========================================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# .env lives in the project root (parent of lib/setup/)
ENV_FILE="$PROJECT_DIR/.env"
[[ ! -f "$ENV_FILE" ]] && ENV_FILE="$SCRIPT_DIR/.env"

# ── Current IPs in config files (auto-updated after each run) ──
OLD_HPLMN_IP="10.162.149.24"
OLD_VPLMN_IP="10.162.149.192"

# ── Read new IPs from .env ──
[[ ! -f "$ENV_FILE" ]] && { echo "ERROR: .env not found at $ENV_FILE"; exit 1; }

NEW_HPLMN_IP=$(grep -E '^HPLMN_IP=' "$ENV_FILE" | cut -d'=' -f2 | cut -d'#' -f1 | tr -d '[:space:]')
NEW_VPLMN_IP=$(grep -E '^VPLMN_IP=' "$ENV_FILE" | cut -d'=' -f2 | cut -d'#' -f1 | tr -d '[:space:]')

[[ -z "$NEW_HPLMN_IP" ]] && { echo "ERROR: HPLMN_IP not set in $ENV_FILE"; exit 1; }
[[ -z "$NEW_VPLMN_IP" ]] && { echo "ERROR: VPLMN_IP not set in $ENV_FILE"; exit 1; }

echo "Read from .env:"
echo "  HPLMN_IP = $NEW_HPLMN_IP"
echo "  VPLMN_IP = $NEW_VPLMN_IP"
echo ""
echo "Changes:"
echo "  HPLMN: $OLD_HPLMN_IP → $NEW_HPLMN_IP"
echo "  VPLMN: $OLD_VPLMN_IP → $NEW_VPLMN_IP"
echo ""
read -p "Proceed? (y/n): " confirm
[[ ! $confirm =~ ^[Yy]$ ]] && { echo "Cancelled."; exit 0; }

echo ""
echo "Updating files..."

# ── Helpers ──
# Anchors on the trailing # HPLMN_IP / # VPLMN_IP comment — replaces whatever
# IPv4 is currently there, so the script is robust against manual IP changes.
do_sed_hplmn() {
    local file="$PROJECT_DIR/$1"
    [[ -f "$file" ]] || { echo "  SKIP (not found): $1"; return; }
    sed -i -E "s/([0-9]{1,3}\.){3}[0-9]{1,3}(.*# HPLMN_IP)/$NEW_HPLMN_IP\2/g" "$file"
    echo "  ✓ $1"
}

do_sed_vplmn() {
    local file="$PROJECT_DIR/$1"
    [[ -f "$file" ]] || { echo "  SKIP (not found): $1"; return; }
    sed -i -E "s/([0-9]{1,3}\.){3}[0-9]{1,3}(.*# VPLMN_IP)/$NEW_VPLMN_IP\2/g" "$file"
    echo "  ✓ $1"
}

# ── Open5GS configs — HPLMN IP (this machine) ──
echo ""
echo "[ Open5GS configs — HPLMN IP ]"
do_sed_hplmn "docker/upf-docker/upf.yaml"
do_sed_hplmn "docker/upf-docker/upf_tls.yaml"
do_sed_hplmn "docker/smf-docker/smf.yaml"
do_sed_hplmn "docker/smf-docker/smf_tls.yaml"

# ── Open5GS configs — VPLMN IP (remote peer) ──
echo ""
echo "[ Open5GS configs — VPLMN IP ]"
do_sed_vplmn "docker-compose.yml"
do_sed_vplmn "docker/sepp-docker/sepp.yaml"

# ── IPsec scripts (hardcoded IP variables) ──
echo ""
echo "[ IPsec scripts ]"
for f in \
    docker/ipsectunnel/01_setup_ca.sh \
    docker/ipsectunnel/ipsec_certificates/pc1/03_setup_ipsec_pc1_cert.sh \
    docker/ipsectunnel/ipsec_certificates/pc2/03_setup_ipsec_pc2_cert.sh; do
    file="$PROJECT_DIR/$f"
    [[ -f "$file" ]] || { echo "  SKIP (not found): $f"; continue; }
    sed -i "s/^VPLMN_IP=\"[^\"]*\"/VPLMN_IP=\"$NEW_VPLMN_IP\"/" "$file"
    sed -i "s/^HPLMN_IP=\"[^\"]*\"/HPLMN_IP=\"$NEW_HPLMN_IP\"/" "$file"
    sed -i "s/^# PC1: [0-9.]\+\(.*# VPLMN_IP\)/# PC1: $NEW_VPLMN_IP\1/" "$file"
    sed -i "s/^# PC2: [0-9.]\+\(.*# HPLMN_IP\)/# PC2: $NEW_HPLMN_IP\1/" "$file"
    echo "  ✓ $f"
done

# ── Verification (must run BEFORE self-update so OLD_* still hold old values) ──
echo ""
echo "=========================================="
echo "  Verification"
echo "=========================================="
# Escape dots and use (?!\d) lookahead to avoid false positives when old IP is a
# substring of new IP (e.g. 10.162.149.1 inside 10.162.149.15).
HPLMN_ESC=$(printf '%s' "$OLD_HPLMN_IP" | sed 's/\./\\./g')
VPLMN_ESC=$(printf '%s' "$OLD_VPLMN_IP" | sed 's/\./\\./g')
HPLMN_REMAIN=$(grep -rlP "${HPLMN_ESC}(?!\d)" \
    "$PROJECT_DIR/docker/upf-docker" "$PROJECT_DIR/docker/smf-docker" \
    "$PROJECT_DIR/docker-compose.yml" "$PROJECT_DIR/docker/sepp-docker" \
    "$PROJECT_DIR/docker/ipsectunnel" \
    2>/dev/null | grep -v ".bak." | wc -l)
VPLMN_REMAIN=$(grep -rlP "${VPLMN_ESC}(?!\d)" \
    "$PROJECT_DIR/docker/upf-docker" "$PROJECT_DIR/docker/smf-docker" \
    "$PROJECT_DIR/docker-compose.yml" "$PROJECT_DIR/docker/sepp-docker" \
    "$PROJECT_DIR/docker/ipsectunnel" \
    2>/dev/null | grep -v ".bak." | wc -l)
echo "  Files still containing old HPLMN IP ($OLD_HPLMN_IP): $HPLMN_REMAIN"
echo "  Files still containing old VPLMN IP ($OLD_VPLMN_IP): $VPLMN_REMAIN"

# ── Update this script's OLD_* values for next run ──
echo ""
echo "[ Updating OLD IPs in this script ]"
SELF="$SCRIPT_DIR/configure_ip_from_env.sh"
sed -i "s/^OLD_HPLMN_IP=\"[^\"]*\"/OLD_HPLMN_IP=\"$NEW_HPLMN_IP\"/" "$SELF"
sed -i "s/^OLD_VPLMN_IP=\"[^\"]*\"/OLD_VPLMN_IP=\"$NEW_VPLMN_IP\"/" "$SELF"
echo "  ✓ configure_ip_from_env.sh"

echo ""
echo "✓ Done! Next steps:"
echo "  1. Restart services: docker compose up"
echo ""
