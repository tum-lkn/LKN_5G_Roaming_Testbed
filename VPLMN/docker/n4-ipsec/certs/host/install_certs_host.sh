#!/bin/bash

# ============================================================================
# install_certs_host.sh — install the N4 IPsec certs on the VPLMN host.
#
# The host-mode UPF terminates its N4 IPsec on the host's own strongSwan.
# Installs the UPF N4 cert package into /etc/ipsec.d. (01_setup_n4_ca.sh already
# writes these into /etc/ipsec.d during generation; this script lets you install
# from the host/ package on a machine where only the package was copied.)
#
# Expects ca-cert.pem, upf-n4-cert.pem, upf-n4-key.pem in the current directory.
# ============================================================================

set -e

echo "=========================================="
echo "N4 IPsec — install certs (VPLMN host / UPF)"
echo "=========================================="

if [ "$EUID" -ne 0 ]; then echo "ERROR: run as root (sudo)"; exit 1; fi

REQUIRED=("ca-cert.pem" "upf-n4-cert.pem" "upf-n4-key.pem")
for f in "${REQUIRED[@]}"; do
    [ -f "$f" ] || { echo "❌ Missing: $f (run 01_setup_n4_ca.sh first)"; exit 1; }
done

CERT_DIR="/etc/ipsec.d"
mkdir -p "$CERT_DIR/cacerts" "$CERT_DIR/certs" "$CERT_DIR/private"
chmod 700 "$CERT_DIR/private"

# Install the N4 trust anchor under a DISTINCT filename so we never overwrite the
# N9 tunnel's CA (/etc/ipsec.d/cacerts/ca-cert.pem), which is present on the HPLMN
# host. strongSwan loads every *.pem in cacerts/, so both CAs coexist.
cp ca-cert.pem     "$CERT_DIR/cacerts/n4-ca-cert.pem"; chmod 644 "$CERT_DIR/cacerts/n4-ca-cert.pem"
cp upf-n4-cert.pem "$CERT_DIR/certs/";   chmod 644 "$CERT_DIR/certs/upf-n4-cert.pem"
cp upf-n4-key.pem  "$CERT_DIR/private/"; chmod 600 "$CERT_DIR/private/upf-n4-key.pem"

# Verify against the CA in THIS package (not cacerts/ca-cert.pem, which on the
# HPLMN host is the unrelated N9 CA).
if ipsec pki --verify --in "$CERT_DIR/certs/upf-n4-cert.pem" --cacert ca-cert.pem >/dev/null 2>&1; then
    echo "✅ UPF N4 certificate verifies against the CA"
else
    echo "❌ Certificate verification failed"; exit 1
fi
echo "✅ N4 certs installed on the host"
