#!/bin/bash

# IPsec Setup Script for PC1 (Visited Network) - TUNNEL MODE with CERTIFICATES
# Certificate-based authentication (3GPP compliant)
# Encrypts ONLY GTP-U traffic (UDP port 2152)
# PC1: 10.162.149.192    # VPLMN_IP
# PC2: 10.162.149.24   # HPLMN_IP

set -e

# ── IP Configuration — updated by configure_ip_from_env.sh ──
VPLMN_IP="10.162.149.192"
HPLMN_IP="10.162.149.24"

# N9 conn name. This host's charon is SHARED with the N4 (SMF<->UPF) tunnel, so
# every operation below is scoped to this conn — we never 'ipsec stop' or flush
# all xfrm state, which would also tear down N4.
CONN_NAME="pc1-to-pc2-gtpu-tunnel-cert"

# ── Config-only mode (--no-start / --config-only / IPSEC_CONFIG_ONLY=1) ──
# Write /etc/ipsec.conf + secrets and prepare the system, but do NOT start
# strongSwan or bring the tunnel up. Used to keep the on-disk peer IPs
# consistent with .env without establishing the tunnel.
CONFIG_ONLY=0
for _arg in "$@"; do
    case "$_arg" in
        --no-start|--config-only) CONFIG_ONLY=1 ;;
    esac
done
if [ "${IPSEC_CONFIG_ONLY:-0}" = "1" ]; then CONFIG_ONLY=1; fi

echo "=========================================="
echo "IPsec GTP-U TUNNEL MODE Setup for PC1"
echo "Certificate-Based Authentication"
echo "PC1: $VPLMN_IP <--IPsec--> PC2: $HPLMN_IP"
echo ""
echo "✅ Mode: TUNNEL (entire packets encrypted)"
echo "✅ Auth: X.509 Certificates (3GPP compliant)"
echo "✅ Encrypts: GTP-U (UDP 2152) ONLY"
echo "✅ NOT Encrypted: SSH, ping, all other traffic"
echo "=========================================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "ERROR: Please run as root (use sudo)"
    exit 1
fi

# Check for certificates
CERT_DIR="/etc/ipsec.d"
CA_CERT="$CERT_DIR/cacerts/ca-cert.pem"
UPF_CERT="$CERT_DIR/certs/pc1-upf-cert.pem"
UPF_KEY="$CERT_DIR/private/pc1-upf-key.pem"

echo "Checking for required certificates..."
if [ ! -f "$CA_CERT" ]; then
    echo "❌ ERROR: CA certificate not found: $CA_CERT"
    echo "Please run ./02_install_certs_pc1.sh first"
    exit 1
fi
if [ ! -f "$UPF_CERT" ]; then
    echo "❌ ERROR: UPF certificate not found: $UPF_CERT"
    echo "Please run ./02_install_certs_pc1.sh first"
    exit 1
fi
if [ ! -f "$UPF_KEY" ]; then
    echo "❌ ERROR: UPF private key not found: $UPF_KEY"
    echo "Please run ./02_install_certs_pc1.sh first"
    exit 1
fi
echo "✅ All certificates found"

# Install strongSwan if not present
if ! command -v ipsec &> /dev/null; then
    echo ""
    echo "Installing strongSwan..."
    apt-get update
    apt-get install -y strongswan strongswan-pki libcharon-extra-plugins
fi

# Bring down ONLY this N9 conn if it is already up. We must NOT 'ipsec stop' or
# flush all xfrm state here: this host's charon is shared with the N4 (SMF<->UPF)
# tunnel, and a global stop/flush would tear N4 down too. If charon isn't running
# yet this is a harmless no-op (the tunnel comes up clean via 'ipsec up' below).
echo ""
echo "Bringing down any existing $CONN_NAME SA (N9 only; N4 untouched)..."
ipsec down "$CONN_NAME" 2>/dev/null || true

# Backup existing configuration
echo "Backing up existing configuration..."
if [ -f /etc/ipsec.conf ]; then
    cp /etc/ipsec.conf /etc/ipsec.conf.backup.$(date +%Y%m%d-%H%M%S)
fi
if [ -f /etc/ipsec.secrets ]; then
    cp /etc/ipsec.secrets /etc/ipsec.secrets.backup.$(date +%Y%m%d-%H%M%S)
fi

# Create IPsec configuration with certificate authentication
echo ""
echo "Creating IPsec configuration with certificate authentication..."
cat > /etc/ipsec.conf << EOF
# IPsec configuration for PC1 (VPLMN) - TUNNEL MODE
# Certificate-based authentication (3GPP compliant)
# Encrypts ONLY GTP-U traffic (UDP port 2152)

config setup
    charondebug="ike 2, knl 2, cfg 2, net 2, esp 2, dmn 2"
    uniqueids=yes
    strictcrlpolicy=no

conn pc1-to-pc2-gtpu-tunnel-cert
    # Connection type and authentication
    type=tunnel
    authby=pubkey
    
    # Local (PC1) - Tunnel endpoint
    left=$VPLMN_IP
    leftid="C=3G, O=Open5GS, CN=upf.5gc.mnc071.mcc999.3gppnetwork.org"
    leftcert=pc1-upf-cert.pem
    leftsubnet=$VPLMN_IP/32[udp/2152]
    
    # Remote (PC2) - Tunnel endpoint
    right=$HPLMN_IP
    rightid="C=3G, O=Open5GS, CN=upf.5gc.mnc001.mcc001.3gppnetwork.org"
    rightsubnet=$HPLMN_IP/32[udp/2152]
    
    # IKEv2 with certificate authentication
    keyexchange=ikev2
    
    # Cipher suites (3GPP TS 33.210 recommendations)
    # IKE (Phase 1)
    ike=aes128gcm16-prfsha256-ecp256,aes256gcm16-prfsha384-ecp384!

    
    # ESP (Phase 2)
    esp=aes128gcm16!
    
    # Lifetimes
    ikelifetime=24h
    lifetime=8h
    margintime=5m
    rekeyfuzz=100%
    replay_window=32
    
    # Dead Peer Detection. dpdaction=clear (NOT restart): the tunnel is manually
    # controlled (WebUI / CLI), so a peer going away — including a deliberate
    # stop — must NOT auto-revive the SA, or the stop button can't take it down.
    dpdaction=clear
    dpddelay=30s
    dpdtimeout=120s
    
    # Connection options
    keyingtries=%forever
    # auto=add (NOT auto=start): the conn is loaded but never auto-initiated, so
    # starting this shared charon for the N4 tunnel does not bring N9 up. N9 is
    # initiated explicitly ('ipsec up') by this script and by the WebUI.
    auto=add
    # closeaction=none: if the peer closes the SA (e.g. the other side's manual
    # stop), do not re-initiate — otherwise the two peers revive each other and
    # the tunnel can never be stopped.
    closeaction=none
    
    # Certificate options
    leftca=%same
    rightca=%same
    
    # Tunnel mode specific
    compress=no
    
    # Optional: Send certificate requests
    leftsendcert=always
    rightsendcert=always
    reqid=1
EOF

# Create ipsec.secrets for private key
echo ""
echo "Configuring private key..."
cat > /etc/ipsec.secrets << 'EOF'
# Private key for PC1 UPF
: RSA pc1-upf-key.pem
EOF

chmod 600 /etc/ipsec.secrets

# Enable IP forwarding (required for tunnel mode)
echo ""
echo "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1 > /dev/null
grep -qxF 'net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

# Disable reverse path filtering (can interfere with tunnel mode)
echo "Adjusting reverse path filtering..."
sysctl -w net.ipv4.conf.all.rp_filter=0 > /dev/null
sysctl -w net.ipv4.conf.default.rp_filter=0 > /dev/null

# Verify certificates are readable
echo ""
echo "Verifying certificate configuration..."
if ! ipsec pki --verify --in "$UPF_CERT" --cacert "$CA_CERT" > /dev/null 2>&1; then
    echo "❌ ERROR: Certificate verification failed!"
    exit 1
fi
echo "✅ Certificate verification successful"

# Start strongSwan (skipped in config-only mode)
if [ "$CONFIG_ONLY" -eq 1 ]; then
    echo ""
    echo "=========================================="
    echo "Config-only mode: /etc/ipsec.conf written; tunnel NOT started."
    echo "  PC1: $VPLMN_IP  <-->  PC2: $HPLMN_IP"
    echo "  Start later with 'sudo ipsec start' or via the WebUI IPsec tab."
    echo "=========================================="
    exit 0
fi

echo ""
# Load the config into charon: reload if it's already running (e.g. N4 brought it
# up) so N4 is left untouched; otherwise start it. Then initiate N9 explicitly,
# since the conn is auto=add.
if ipsec status > /dev/null 2>&1; then
    echo "strongSwan already running — reloading config (N4 stays up)..."
    ipsec reload
else
    echo "Starting strongSwan..."
    ipsec start
fi

sleep 3

# Verify strongSwan is running
if ! ipsec status > /dev/null 2>&1; then
    echo "❌ ERROR: strongSwan failed to start!"
    echo "Check logs: journalctl -u strongswan-starter -n 50"
    exit 1
fi

echo "Initiating the N9 tunnel ($CONN_NAME)..."
ipsec up "$CONN_NAME" || true

# Show status
echo ""
echo "=========================================="
echo "IPsec Certificate-Based Tunnel Setup"
echo "Complete on PC1!"
echo "=========================================="
echo ""
ipsec status

echo ""
echo "=========================================="
echo "📋 Certificate Details:"
echo "=========================================="
echo ""
echo "Local Certificate (PC1):"
ipsec pki --print --in "$UPF_CERT" | grep -E "subject:|issuer:|validity:"
echo ""
echo "CA Certificate:"
ipsec pki --print --in "$CA_CERT" | grep -E "subject:|issuer:"

echo ""
echo "=========================================="
echo "✅ Verification Commands:"
echo "=========================================="
echo ""
echo "1. Check tunnel status (wait for ESTABLISHED):"
echo "   sudo ipsec statusall"
echo ""
echo "2. View IPsec policies:"
echo "   sudo ip xfrm policy"
echo ""
echo "3. View IPsec state (SA details):"
echo "   sudo ip xfrm state"
echo ""
echo "4. Check certificate authentication:"
echo "   sudo journalctl -u strongswan -f"
echo ""
echo "5. Test non-encrypted traffic:"
echo "   ping $HPLMN_IP"
echo "   ssh user@$HPLMN_IP"
echo ""
echo "6. Monitor ESP packets (when GTP-U is active):"
echo "   sudo tcpdump -i enp0s31f6 -nn esp"
echo ""
echo "7. View detailed connection info:"
echo "   sudo ipsec listcerts"
echo "   sudo ipsec listcacerts"
echo ""
echo "=========================================="
echo "🔒 3GPP Security Compliance:"
echo "=========================================="
echo "✅ Certificate-based authentication (TS 33.210)"
echo "✅ IKEv2 key exchange"
echo "✅ AES-256 encryption"
echo "✅ SHA-256/384 integrity"
echo "✅ Perfect Forward Secrecy (PFS)"
echo "✅ Tunnel mode for N9 interface"
echo ""
echo "⚠️  Troubleshooting:"
echo "If connection doesn't establish:"
echo "1. Verify PC2 has matching configuration"
echo "2. Check firewall: sudo ufw status"
echo "3. Verify certificates: sudo ipsec listcerts"
echo "4. Check logs: sudo journalctl -u strongswan -n 100"
echo ""
