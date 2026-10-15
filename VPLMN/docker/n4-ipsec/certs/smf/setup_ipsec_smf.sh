#!/bin/bash

# ============================================================================
# setup_ipsec_smf.sh — configure & start the SMF end of the N4 IPsec tunnel.
#
# Runs INSIDE the open5gs-smf container (via `docker exec`). The SMF is the
# IKE initiator (auto=start). Protects ONLY PFCP (UDP 8805) between the SMF
# container and the host-mode UPF, in TUNNEL mode with X.509 certs — the same
# 3GPP NDS/IP profile as the N9 tunnel.
#
#   setup_ipsec_smf.sh              write config, start charon, bring N4 up
#   setup_ipsec_smf.sh --no-start   write config only (do not start)
#
# IPs: SMF is a fixed docker-net address; UPF/host is templated from .env.
# ============================================================================

set -e

# ── IP Configuration — VPLMN_IP updated by configure_ip_from_env.sh ──
VPLMN_IP="10.162.149.192"          # UPF (host-mode) N4 endpoint  # VPLMN_IP
SMF_N4_IP="192.168.50.193"         # SMF container N4 endpoint (fixed docker net)

CONFIG_ONLY=0
# ESP cipher proposal for this N4 tunnel. Overridable per-run with --esp <val>
# (n4_ipsec.sh threads the operator's chosen mode through here); defaults to
# AES-128-GCM so a bare deploy/start keeps the original behaviour. Must match
# the host/UPF side's esp for the SA to negotiate.
N4_ESP="aes128gcm16"
while [ $# -gt 0 ]; do
    case "$1" in
        --no-start|--config-only) CONFIG_ONLY=1 ;;
        --esp) shift; N4_ESP="${1:-aes128gcm16}" ;;
        --esp=*) N4_ESP="${1#--esp=}" ;;
    esac
    shift
done
[ "${IPSEC_CONFIG_ONLY:-0}" = "1" ] && CONFIG_ONLY=1
N4_ESP="${N4_ESP:-aes128gcm16}"

echo "=========================================="
echo "N4 IPsec — SMF side (initiator)"
echo "  SMF $SMF_N4_IP  --IPsec/PFCP-->  UPF(host) $VPLMN_IP"
echo "  ESP cipher: $N4_ESP"
echo "=========================================="

CERT_DIR="/etc/ipsec.d"
for f in "$CERT_DIR/cacerts/ca-cert.pem" "$CERT_DIR/certs/smf-n4-cert.pem" "$CERT_DIR/private/smf-n4-key.pem"; do
    [ -f "$f" ] || { echo "❌ Missing $f — run install_certs_smf.sh first"; exit 1; }
done

# strongSwan must be present in the image (added in Dockerfile.smf)
command -v ipsec >/dev/null 2>&1 || { echo "❌ strongSwan not installed in this container"; exit 1; }

# Fresh charon state
ipsec stop 2>/dev/null || true
ip xfrm state flush 2>/dev/null || true
ip xfrm policy flush 2>/dev/null || true

cat > /etc/ipsec.conf << EOF
# N4 (PFCP) IPsec — SMF side. TUNNEL mode, cert auth, encrypts UDP 8805 only.
config setup
    charondebug="ike 1, knl 1, cfg 0"
    uniqueids=yes
    strictcrlpolicy=no

conn n4-smf-upf
    type=tunnel
    authby=pubkey
    keyexchange=ikev2
    # Local: SMF container
    left=$SMF_N4_IP
    leftid="C=3G, O=Open5GS, CN=smf.5gc.mnc071.mcc999.3gppnetwork.org"
    leftcert=smf-n4-cert.pem
    leftsubnet=$SMF_N4_IP/32[udp/8805]
    # Remote: host-mode UPF
    right=$VPLMN_IP
    rightid="C=3G, O=Open5GS, CN=upf.5gc.mnc071.mcc999.3gppnetwork.org"
    rightsubnet=$VPLMN_IP/32[udp/8805]
    ike=aes128gcm16-prfsha256-ecp256,aes256gcm16-prfsha384-ecp384!
    esp=${N4_ESP}!
    ikelifetime=24h
    lifetime=8h
    margintime=5m
    rekeyfuzz=100%
    replay_window=32
    # Manually controlled tunnel: dpdaction=clear + closeaction=none so a stop
    # (or the peer going away) never auto-revives the SA and no stray CONNECTING
    # attempt is left behind.
    dpdaction=clear
    dpddelay=30s
    dpdtimeout=120s
    keyingtries=%forever
    closeaction=none
    leftca=%same
    rightca=%same
    leftsendcert=always
    rightsendcert=always
    compress=no
    reqid=2
    auto=start
EOF

cat > /etc/ipsec.secrets << 'EOF'
: RSA smf-n4-key.pem
EOF
chmod 600 /etc/ipsec.secrets

# Tunnel mode inside the container netns needs forwarding + relaxed rp_filter
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true

if [ "$CONFIG_ONLY" -eq 1 ]; then
    echo "Config-only: /etc/ipsec.conf written; N4 tunnel NOT started."
    exit 0
fi

echo "Starting charon in the SMF container..."
ipsec start
sleep 3
# 'auto=start' already initiates the conn when charon starts; only nudge it if,
# for some reason, no SA came up (avoids creating a duplicate CHILD_SA).
if ! ipsec status n4-smf-upf 2>/dev/null | grep -q ESTABLISHED; then
    ipsec up n4-smf-upf || true
fi
echo ""
ipsec statusall 2>/dev/null | grep -E "n4-smf-upf|ESTABLISHED|INSTALLED" || echo "(no SA yet — check the UPF/host side is up)"
