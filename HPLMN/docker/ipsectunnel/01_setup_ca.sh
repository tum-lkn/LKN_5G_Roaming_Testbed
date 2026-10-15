#!/bin/bash

# Certificate Authority Setup Script
# Run this ONCE on either PC1 or PC2, then copy certificates to both machines
# This creates a CA and generates certificates for both UPF endpoints

set -e

echo "=========================================="
echo "IPsec Certificate Authority Setup"
echo "For Open5GS N9 Interface (GTP-U)"
echo "=========================================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run as root (use sudo)"
    exit 1
fi

# Check for strongSwan (provides the 'ipsec pki' certificate tooling)
echo "[0/8] Checking for strongSwan..."
if command -v ipsec >/dev/null 2>&1 && ipsec pki --help >/dev/null 2>&1; then
    echo "  ✓ strongSwan is installed"
else
    echo "  strongSwan not found — attempting to install..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y strongswan strongswan-pki strongswan-starter
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y strongswan
    elif command -v yum >/dev/null 2>&1; then
        yum install -y strongswan
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm strongswan
    else
        echo "ERROR: No supported package manager found (apt-get/dnf/yum/pacman)."
        echo "       Please install strongSwan manually, then re-run this script."
        exit 1
    fi

    # Verify the certificate tool is now usable
    if command -v ipsec >/dev/null 2>&1 && ipsec pki --help >/dev/null 2>&1; then
        echo "  ✓ strongSwan installed successfully"
    else
        echo "ERROR: strongSwan installed but 'ipsec pki' is still unavailable."
        echo "       On newer strongSwan the legacy 'ipsec' wrapper may be dropped;"
        echo "       ensure the 'strongswan-starter' package (which provides it) is installed."
        exit 1
    fi
fi
echo ""

# Create directory structure
CERT_DIR="/etc/ipsec.d"
CA_DIR="$CERT_DIR/cacerts"
CERT_OUT_DIR="$CERT_DIR/certs"
KEY_DIR="$CERT_DIR/private"
OUTPUT_DIR="./ipsec_certificates"

echo "[1/8] Creating directory structure..."
mkdir -p "$CA_DIR"
mkdir -p "$CERT_OUT_DIR"
mkdir -p "$KEY_DIR"
mkdir -p "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/pc1"
mkdir -p "$OUTPUT_DIR/pc2"

# Set proper permissions
chmod 755 "$CERT_DIR"
chmod 755 "$CA_DIR"
chmod 755 "$CERT_OUT_DIR"
chmod 700 "$KEY_DIR"

echo ""
echo "[2/8] Generating certificates with 3GPP FQDNs..."
echo ""

# Fixed configuration - no prompts needed
COUNTRY="3G"
ORG="Open5GS"
CA_CN="Open5GS-N9-CA"

# Fixed validity periods
CA_DAYS=3650      # 10 years
CERT_DAYS=1825    # 5 years

# PC1 and PC2 details - 3GPP FQDN format
# IPs — update via configure_ip_from_env.sh
VPLMN_IP="10.162.149.192"   # VPLMN_IP
HPLMN_IP="10.162.149.24"  # HPLMN_IP
PC1_IP="$VPLMN_IP"
PC2_IP="$HPLMN_IP"
# VPLMN (Visited Network) - MCC=999, MNC=071
PC1_CN="upf.5gc.mnc071.mcc999.3gppnetwork.org"
PC1_SAN_DNS="upf.5gc.mnc071.mcc999.3gppnetwork.org"
PC1_SAN_ALIAS="upf.vplmn.local"
# HPLMN (Home Network) - MCC=001, MNC=001
PC2_CN="upf.5gc.mnc001.mcc001.3gppnetwork.org"
PC2_SAN_DNS="upf.5gc.mnc001.mcc001.3gppnetwork.org"
PC2_SAN_ALIAS="upf.hplmn.local"

echo ""
echo "=========================================="
echo "Certificate Configuration:"
echo "CA: $CA_CN (valid for $CA_DAYS days)"
echo "PC1 (VPLMN): $PC1_CN ($PC1_IP)"
echo "PC2 (HPLMN): $PC2_CN ($PC2_IP)"
echo "Validity: $CERT_DAYS days (5 years)"
echo "=========================================="
echo ""

echo ""
echo "[3/8] Generating CA private key..."
ipsec pki --gen --type rsa --size 4096 \
    --outform pem > "$KEY_DIR/ca-key.pem"
chmod 600 "$KEY_DIR/ca-key.pem"

echo "[4/8] Creating CA certificate..."
ipsec pki --self --ca --lifetime $CA_DAYS \
    --in "$KEY_DIR/ca-key.pem" \
    --type rsa \
    --dn "C=$COUNTRY, O=$ORG, CN=$CA_CN" \
    --outform pem > "$CA_DIR/ca-cert.pem"
chmod 644 "$CA_DIR/ca-cert.pem"

echo "[5/8] Generating private key for PC1 UPF..."
ipsec pki --gen --type rsa --size 2048 \
    --outform pem > "$KEY_DIR/pc1-upf-key.pem"
chmod 600 "$KEY_DIR/pc1-upf-key.pem"

echo "[6/8] Generating certificate for PC1 UPF (VPLMN)..."
ipsec pki --pub --in "$KEY_DIR/pc1-upf-key.pem" \
    --type rsa | \
ipsec pki --issue --lifetime $CERT_DAYS \
    --cacert "$CA_DIR/ca-cert.pem" \
    --cakey "$KEY_DIR/ca-key.pem" \
    --dn "C=$COUNTRY, O=$ORG, CN=$PC1_CN" \
    --san "$PC1_IP" \
    --san "$PC1_CN" \
    --san "$PC1_SAN_DNS" \
    --san "$PC1_SAN_ALIAS" \
    --flag serverAuth --flag ikeIntermediate \
    --outform pem > "$CERT_OUT_DIR/pc1-upf-cert.pem"
chmod 644 "$CERT_OUT_DIR/pc1-upf-cert.pem"

echo "[7/8] Generating private key for PC2 UPF..."
ipsec pki --gen --type rsa --size 2048 \
    --outform pem > "$KEY_DIR/pc2-upf-key.pem"
chmod 600 "$KEY_DIR/pc2-upf-key.pem"

echo "[8/8] Generating certificate for PC2 UPF (HPLMN)..."
ipsec pki --pub --in "$KEY_DIR/pc2-upf-key.pem" \
    --type rsa | \
ipsec pki --issue --lifetime $CERT_DAYS \
    --cacert "$CA_DIR/ca-cert.pem" \
    --cakey "$KEY_DIR/ca-key.pem" \
    --dn "C=$COUNTRY, O=$ORG, CN=$PC2_CN" \
    --san "$PC2_IP" \
    --san "$PC2_CN" \
    --san "$PC2_SAN_DNS" \
    --san "$PC2_SAN_ALIAS" \
    --flag serverAuth --flag ikeIntermediate \
    --outform pem > "$CERT_OUT_DIR/pc2-upf-cert.pem"
chmod 644 "$CERT_OUT_DIR/pc2-upf-cert.pem"

# Copy certificates to output directory for distribution
echo ""
echo "Preparing certificate packages for distribution..."

# Package for PC1
cp "$CA_DIR/ca-cert.pem" "$OUTPUT_DIR/pc1/"
cp "$CERT_OUT_DIR/pc1-upf-cert.pem" "$OUTPUT_DIR/pc1/"
cp "$KEY_DIR/pc1-upf-key.pem" "$OUTPUT_DIR/pc1/"

# Package for PC2
cp "$CA_DIR/ca-cert.pem" "$OUTPUT_DIR/pc2/"
cp "$CERT_OUT_DIR/pc2-upf-cert.pem" "$OUTPUT_DIR/pc2/"
cp "$KEY_DIR/pc2-upf-key.pem" "$OUTPUT_DIR/pc2/"

# Create README files
cat > "$OUTPUT_DIR/pc1/README.txt" << EOF
IPsec Certificates for PC1 (VPLMN UPF)
========================================

Files:
- ca-cert.pem: Certificate Authority certificate (public)
- pc1-upf-cert.pem: PC1 UPF certificate (public)
- pc1-upf-key.pem: PC1 UPF private key (KEEP SECRET!)

Installation on PC1:
1. Copy all files to PC1
2. Run: sudo ./02_install_certs_pc1.sh
3. Run: sudo ./03_setup_ipsec_pc1_cert.sh

Identity: $PC1_CN
IP Address: $PC1_IP
EOF

cat > "$OUTPUT_DIR/pc2/README.txt" << EOF
IPsec Certificates for PC2 (HPLMN UPF)
========================================

Files:
- ca-cert.pem: Certificate Authority certificate (public)
- pc2-upf-cert.pem: PC2 UPF certificate (public)
- pc2-upf-key.pem: PC2 UPF private key (KEEP SECRET!)

Installation on PC2:
1. Copy all files to PC2
2. Run: sudo ./02_install_certs_pc2.sh
3. Run: sudo ./03_setup_ipsec_pc2_cert.sh

Identity: $PC2_CN
IP Address: $PC2_IP
EOF

# Display certificate information
echo ""
echo "=========================================="
echo "✅ Certificate Generation Complete!"
echo "=========================================="
echo ""
echo "CA Certificate:"
ipsec pki --print --in "$CA_DIR/ca-cert.pem"
echo ""
echo "PC1 UPF Certificate:"
ipsec pki --print --in "$CERT_OUT_DIR/pc1-upf-cert.pem"
echo ""
echo "PC2 UPF Certificate:"
ipsec pki --print --in "$CERT_OUT_DIR/pc2-upf-cert.pem"
echo ""
echo "=========================================="
echo "📦 Certificate Packages Created:"
echo "=========================================="
echo ""
echo "PC1 package: $OUTPUT_DIR/pc1/"
echo "  - ca-cert.pem"
echo "  - pc1-upf-cert.pem"
echo "  - pc1-upf-key.pem"
echo "  - README.txt"
echo ""
echo "PC2 package: $OUTPUT_DIR/pc2/"
echo "  - ca-cert.pem"
echo "  - pc2-upf-cert.pem"
echo "  - pc2-upf-key.pem"
echo "  - README.txt"
echo ""
echo "=========================================="
echo "📋 Next Steps:"
echo "=========================================="
echo ""
echo "1. Transfer PC1 package to PC1:"
echo "   scp -r $OUTPUT_DIR/pc1/* user@$PC1_IP:~/ipsec_certs/"
echo ""
echo "2. Transfer PC2 package to PC2:"
echo "   scp -r $OUTPUT_DIR/pc2/* user@$PC2_IP:~/ipsec_certs/"
echo ""
echo "3. On each PC, install certificates and configure IPsec"
echo ""
echo "⚠️  SECURITY WARNING:"
echo "Keep private keys (*-key.pem) secure!"
echo "Only transmit over secure channels (scp, USB drive, etc.)"
echo ""
