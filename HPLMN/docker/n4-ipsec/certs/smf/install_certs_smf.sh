#!/bin/bash

# ============================================================================
# install_certs_smf.sh — install the N4 IPsec certs INSIDE the SMF container.
#
# Runs in the open5gs-smf container's namespace (via `docker exec`). Copies the
# N4 cert package into /etc/ipsec.d so charon (running in the container) can use
# certificate-based authentication for the SMF end of the N4 tunnel.
#
# Expects ca-cert.pem, smf-n4-cert.pem, smf-n4-key.pem in the current directory.
# ============================================================================

set -e

echo "=========================================="
echo "N4 IPsec — install certs (SMF container)"
echo "=========================================="

REQUIRED=("ca-cert.pem" "smf-n4-cert.pem" "smf-n4-key.pem")
for f in "${REQUIRED[@]}"; do
    [ -f "$f" ] || { echo "❌ Missing: $f (run 01_setup_n4_ca.sh on the host first)"; exit 1; }
done

CERT_DIR="/etc/ipsec.d"
mkdir -p "$CERT_DIR/cacerts" "$CERT_DIR/certs" "$CERT_DIR/private"
chmod 700 "$CERT_DIR/private"

cp ca-cert.pem      "$CERT_DIR/cacerts/";  chmod 644 "$CERT_DIR/cacerts/ca-cert.pem"
cp smf-n4-cert.pem  "$CERT_DIR/certs/";    chmod 644 "$CERT_DIR/certs/smf-n4-cert.pem"
cp smf-n4-key.pem   "$CERT_DIR/private/";  chmod 600 "$CERT_DIR/private/smf-n4-key.pem"

if ipsec pki --verify --in "$CERT_DIR/certs/smf-n4-cert.pem" --cacert "$CERT_DIR/cacerts/ca-cert.pem" >/dev/null 2>&1; then
    echo "✅ SMF N4 certificate verifies against the CA"
else
    echo "❌ Certificate verification failed"; exit 1
fi
echo "✅ N4 certs installed in the SMF container"
