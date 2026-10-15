#!/bin/bash

# ============================================================================
# 01_setup_n4_ca.sh — Certificates for the N4 (PFCP) IPsec tunnel: SMF <-> UPF
#
# The N4 interface is intra-VPLMN:
#   SMF  = Docker container on my_custom_network, 192.168.50.193 (PFCP client)
#   UPF  = network_mode: host, PFCP server bound to VPLMN_IP:8805
#
# strongSwan therefore terminates IPsec in TWO different network namespaces on
# the SAME host: inside the SMF container (192.168.50.193) and on the host for
# the host-mode UPF (VPLMN_IP). This script issues one leaf certificate per
# endpoint, signed by the SAME CA the N9 tunnel already uses when that CA is
# present (single trust anchor for the whole testbed), or a fresh N4 CA if not.
#
# Run this ONCE on the VPLMN host (as root). It writes two packages:
#   certs/smf/   -> installed INSIDE the SMF container
#   certs/host/  -> installed on the VPLMN host (for the host-mode UPF)
#
# IPs: SMF is a fixed Docker-network address (operator-independent). Only the
# UPF/host address is operator-specific and is templated from .env by
# lib/setup/configure_ip_from_env.sh (the VPLMN_IP line below).
# ============================================================================

set -e

# ── IP Configuration — VPLMN_IP updated by configure_ip_from_env.sh ──
VPLMN_IP="10.162.149.192"          # UPF (host-mode) N4 endpoint  # VPLMN_IP
SMF_N4_IP="192.168.50.193"         # SMF container N4 endpoint (fixed docker net)

echo "=========================================="
echo "IPsec Certificate Setup — N4 (PFCP) SMF<->UPF"
echo "  SMF: $SMF_N4_IP   UPF(host): $VPLMN_IP"
echo "=========================================="
echo ""

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run as root (use sudo)"
    exit 1
fi

# strongSwan provides the 'ipsec pki' tooling
if ! ( command -v ipsec >/dev/null 2>&1 && ipsec pki --help >/dev/null 2>&1 ); then
    echo "strongSwan not found — installing..."
    apt-get update && apt-get install -y strongswan strongswan-pki strongswan-starter
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/certs"
SMF_PKG="$OUTPUT_DIR/smf"
HOST_PKG="$OUTPUT_DIR/host"
mkdir -p "$SMF_PKG" "$HOST_PKG"

# Where the shared/host CA material lives (installed by N9's 01_setup_ca.sh)
CERT_DIR="/etc/ipsec.d"
CA_DIR="$CERT_DIR/cacerts"
KEY_DIR="$CERT_DIR/private"
mkdir -p "$CA_DIR" "$KEY_DIR" "$CERT_DIR/certs"
chmod 700 "$KEY_DIR"

# N9 tunnel's shared CA. On the host that GENERATED it (PC1) both the cert and
# the key are present, so we can reuse it as the N4 trust anchor. On the OTHER
# PC the N9 CA *cert* is present but its *key* is not — there we must NOT
# regenerate ca-cert.pem (that would break the N9 tunnel). We then fall back to a
# DEDICATED N4 CA under a distinct filename that never touches the N9 CA.
# A key merely being present is not enough: deploy_ipsec.sh can install a reused
# (committed) N9 ca-cert.pem next to a stale ca-key.pem from an older CA, so a
# CA is only reused when its key actually matches its cert.
N9_CA_CERT="$CA_DIR/ca-cert.pem"
N9_CA_KEY="$KEY_DIR/ca-key.pem"
N4_CA_CERT="$CA_DIR/n4-ca-cert.pem"
N4_CA_KEY="$KEY_DIR/n4-ca-key.pem"

COUNTRY="3G"
ORG="Open5GS"
CA_DAYS=3650
CERT_DAYS=1825

# true if <cert> and <key> both exist and hold the same public key
ca_pair_ok() {
    [ -f "$1" ] && [ -f "$2" ] || return 1
    local c k
    c="$(ipsec pki --pub --in "$1" --type x509 --outform pem 2>/dev/null)" || return 1
    k="$(ipsec pki --pub --in "$2" --type rsa  --outform pem 2>/dev/null)" || return 1
    [ -n "$c" ] && [ "$c" = "$k" ]
}

if ca_pair_ok "$N9_CA_CERT" "$N9_CA_KEY"; then
    echo "[CA] Reusing the shared N9 CA (cert+key match) as the N4 trust anchor"
    SIGN_CERT="$N9_CA_CERT"; SIGN_KEY="$N9_CA_KEY"
elif ca_pair_ok "$N4_CA_CERT" "$N4_CA_KEY"; then
    echo "[CA] Reusing the existing dedicated N4 CA"
    SIGN_CERT="$N4_CA_CERT"; SIGN_KEY="$N4_CA_KEY"
else
    [ -f "$N9_CA_KEY" ] && echo "[CA] N9 ca-key.pem does not match ca-cert.pem (stale key) — not reusing it"
    echo "[CA] No usable CA key found — creating a dedicated N4 CA (N9 CA left untouched)"
    ipsec pki --gen --type rsa --size 4096 --outform pem > "$N4_CA_KEY"
    chmod 600 "$N4_CA_KEY"
    ipsec pki --self --ca --lifetime $CA_DAYS \
        --in "$N4_CA_KEY" --type rsa \
        --dn "C=$COUNTRY, O=$ORG, CN=Open5GS-N4-CA" \
        --outform pem > "$N4_CA_CERT"
    chmod 644 "$N4_CA_CERT"
    SIGN_CERT="$N4_CA_CERT"; SIGN_KEY="$N4_CA_KEY"
fi

# ── Endpoint identities (3GPP FQDNs, VPLMN = MCC=999 MNC=071) ──
SMF_CN="smf.5gc.mnc071.mcc999.3gppnetwork.org"
UPF_CN="upf.5gc.mnc071.mcc999.3gppnetwork.org"

gen_leaf() {   # <name> <ip> <cn> <alias>
    local name="$1" ip="$2" cn="$3" alias="$4"
    echo "[cert] $name  ($cn  @ $ip)"
    ipsec pki --gen --type rsa --size 2048 --outform pem > "$KEY_DIR/${name}-key.pem"
    chmod 600 "$KEY_DIR/${name}-key.pem"
    ipsec pki --pub --in "$KEY_DIR/${name}-key.pem" --type rsa | \
    ipsec pki --issue --lifetime $CERT_DAYS \
        --cacert "$SIGN_CERT" --cakey "$SIGN_KEY" \
        --dn "C=$COUNTRY, O=$ORG, CN=$cn" \
        --san "$ip" --san "$cn" --san "$alias" \
        --flag serverAuth --flag ikeIntermediate \
        --outform pem > "$CERT_DIR/certs/${name}-cert.pem"
    chmod 644 "$CERT_DIR/certs/${name}-cert.pem"
}

echo ""
echo "Generating N4 endpoint certificates..."
gen_leaf "smf-n4" "$SMF_N4_IP" "$SMF_CN" "smf.vplmn.local"
gen_leaf "upf-n4" "$VPLMN_IP"  "$UPF_CN" "upf.vplmn.local"

# ── Package for the SMF container (ca-cert.pem = the CA that signed these) ──
cp "$SIGN_CERT"                    "$SMF_PKG/ca-cert.pem"
cp "$CERT_DIR/certs/smf-n4-cert.pem" "$SMF_PKG/"
cp "$KEY_DIR/smf-n4-key.pem"      "$SMF_PKG/"
# ── Package for the host (host-mode UPF) ──
cp "$SIGN_CERT"                    "$HOST_PKG/ca-cert.pem"
cp "$CERT_DIR/certs/upf-n4-cert.pem" "$HOST_PKG/"
cp "$KEY_DIR/upf-n4-key.pem"      "$HOST_PKG/"

cat > "$SMF_PKG/README.txt" << EOF
N4 IPsec certificates for the SMF container (installed INSIDE open5gs-smf)
  ca-cert.pem       CA (public)
  smf-n4-cert.pem   SMF N4 certificate (public)
  smf-n4-key.pem    SMF N4 private key (KEEP SECRET)
Identity : $SMF_CN   IP: $SMF_N4_IP
Installed by install_certs_smf.sh, configured by setup_ipsec_smf.sh.
EOF
cat > "$HOST_PKG/README.txt" << EOF
N4 IPsec certificates for the VPLMN host (host-mode UPF)
  ca-cert.pem       CA (public)
  upf-n4-cert.pem   UPF N4 certificate (public)
  upf-n4-key.pem    UPF N4 private key (KEEP SECRET)
Identity : $UPF_CN   IP: $VPLMN_IP
Installed by install_certs_host.sh, configured by setup_ipsec_n4_host.sh.
EOF

echo ""
echo "=========================================="
echo "✅ N4 certificate generation complete"
echo "  SMF package : $SMF_PKG/"
echo "  Host package: $HOST_PKG/"
echo "=========================================="
