#!/bin/bash

# Certificate Installation Script for PC1 (VPLMN)
# Install IPsec certificates for certificate-based authentication

set -e

echo "=========================================="
echo "IPsec Certificate Installation for PC1"
echo "=========================================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "ERROR: Please run as root (use sudo)"
    exit 1
fi

# Check for required files
REQUIRED_FILES=("ca-cert.pem" "pc1-upf-cert.pem" "pc1-upf-key.pem")
MISSING_FILES=0

echo "Checking for required certificate files..."
for file in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        echo "❌ Missing: $file"
        MISSING_FILES=1
    else
        echo "✅ Found: $file"
    fi
done

if [ $MISSING_FILES -eq 1 ]; then
    echo ""
    echo "ERROR: Missing required certificate files!"
    echo "Please ensure all certificate files are in the current directory."
    exit 1
fi

# Create directories
CERT_DIR="/etc/ipsec.d"
CA_DIR="$CERT_DIR/cacerts"
CERT_OUT_DIR="$CERT_DIR/certs"
KEY_DIR="$CERT_DIR/private"

echo ""
echo "Creating directory structure..."
mkdir -p "$CA_DIR"
mkdir -p "$CERT_OUT_DIR"
mkdir -p "$KEY_DIR"

# Backup existing certificates if any
if [ -f "$CA_DIR/ca-cert.pem" ]; then
    echo "Backing up existing certificates..."
    BACKUP_DIR="/etc/ipsec.d/backup_$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    cp -r "$CA_DIR"/* "$BACKUP_DIR/" 2>/dev/null || true
    cp -r "$CERT_OUT_DIR"/* "$BACKUP_DIR/" 2>/dev/null || true
    cp -r "$KEY_DIR"/* "$BACKUP_DIR/" 2>/dev/null || true
fi

# Install certificates
echo ""
echo "Installing certificates..."

echo "  - Installing CA certificate..."
cp ca-cert.pem "$CA_DIR/"
chmod 644 "$CA_DIR/ca-cert.pem"

echo "  - Installing PC1 UPF certificate..."
cp pc1-upf-cert.pem "$CERT_OUT_DIR/"
chmod 644 "$CERT_OUT_DIR/pc1-upf-cert.pem"

echo "  - Installing PC1 UPF private key..."
cp pc1-upf-key.pem "$KEY_DIR/"
chmod 600 "$KEY_DIR/pc1-upf-key.pem"

# Verify certificates
echo ""
echo "Verifying certificate installation..."

if ipsec pki --verify --in "$CERT_OUT_DIR/pc1-upf-cert.pem" \
    --cacert "$CA_DIR/ca-cert.pem" > /dev/null 2>&1; then
    echo "✅ Certificate verification successful!"
else
    echo "❌ Certificate verification failed!"
    exit 1
fi

# Display certificate info
echo ""
echo "=========================================="
echo "Installed Certificate Information:"
echo "=========================================="
ipsec pki --print --in "$CERT_OUT_DIR/pc1-upf-cert.pem"

echo ""
echo "=========================================="
echo "✅ Certificate Installation Complete!"
echo "=========================================="
echo ""
echo "Installed files:"
echo "  CA Cert: $CA_DIR/ca-cert.pem"
echo "  UPF Cert: $CERT_OUT_DIR/pc1-upf-cert.pem"
echo "  UPF Key: $KEY_DIR/pc1-upf-key.pem"
echo ""
echo "Next step: Run ./03_setup_ipsec_pc1_cert.sh"
echo ""
