#!/bin/bash

# ============================================================================
# setup_ipsec_n4_host.sh — configure the UPF end of the N4 IPsec tunnel on the
# VPLMN host (the UPF runs network_mode: host, so its IPsec lives on the host).
#
# The host is the IKE responder (auto=add). The N4 conn is written to a SEPARATE
# file, /etc/ipsec.d/n4-smf-upf.conf, and pulled in via `include` so it COEXISTS
# with the N9 tunnel (which lives in /etc/ipsec.conf). We `ipsec reload` rather
# than restart, so bringing N4 up/down never disturbs N9.
#
#   setup_ipsec_n4_host.sh              write config + reload charon (N4 waits for SMF)
#   setup_ipsec_n4_host.sh --no-start   write config only (do not reload/start)
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
# AES-128-GCM so a bare deploy/start keeps the original behaviour.
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
echo "N4 IPsec — UPF/host side (responder)"
echo "  UPF(host) $VPLMN_IP  <--IPsec/PFCP--  SMF $SMF_N4_IP"
echo "  ESP cipher: $N4_ESP"
echo "=========================================="

if [ "$EUID" -ne 0 ]; then echo "ERROR: run as root (sudo)"; exit 1; fi

CERT_DIR="/etc/ipsec.d"
# The N4 trust anchor is either the dedicated n4-ca-cert.pem (HPLMN, or any host
# without the N9 CA key) or the shared N9 ca-cert.pem (VPLMN reuse). Accept either.
if [ ! -f "$CERT_DIR/cacerts/n4-ca-cert.pem" ] && [ ! -f "$CERT_DIR/cacerts/ca-cert.pem" ]; then
    echo "❌ No N4 CA in $CERT_DIR/cacerts (n4-ca-cert.pem or ca-cert.pem) — run install_certs_host.sh first"; exit 1
fi
for f in "$CERT_DIR/certs/upf-n4-cert.pem" "$CERT_DIR/private/upf-n4-key.pem"; do
    [ -f "$f" ] || { echo "❌ Missing $f — run 01_setup_n4_ca.sh / install_certs_host.sh first"; exit 1; }
done
command -v ipsec >/dev/null 2>&1 || { echo "❌ strongSwan not installed on host"; exit 1; }

# ── Ensure /etc/ipsec.conf pulls in the ipsec.d/*.conf drop-ins ──
# N9's 03 script writes a monolithic /etc/ipsec.conf; if it exists we just make
# sure it includes our drop-in. If it doesn't exist yet, create a minimal one.
if [ -f /etc/ipsec.conf ]; then
    if ! grep -qE '^\s*include\s+/etc/ipsec\.d/\*\.conf' /etc/ipsec.conf; then
        printf '\n# N4 drop-in tunnels (added by setup_ipsec_n4_host.sh)\ninclude /etc/ipsec.d/*.conf\n' >> /etc/ipsec.conf
        echo "  + added 'include /etc/ipsec.d/*.conf' to /etc/ipsec.conf"
    fi
else
    cat > /etc/ipsec.conf << 'EOF'
config setup
    charondebug="ike 1, knl 1, cfg 0"
    uniqueids=yes
    strictcrlpolicy=no

include /etc/ipsec.d/*.conf
EOF
    echo "  + created minimal /etc/ipsec.conf with include"
fi

# ── Write the N4 conn drop-in (host is 'right' -> uses rightcert) ──
cat > "$CERT_DIR/n4-smf-upf.conf" << EOF
# N4 (PFCP) IPsec — UPF/host side. TUNNEL mode, cert auth, encrypts UDP 8805 only.
conn n4-smf-upf
    type=tunnel
    authby=pubkey
    keyexchange=ikev2
    left=$SMF_N4_IP
    leftid="C=3G, O=Open5GS, CN=smf.5gc.mnc071.mcc999.3gppnetwork.org"
    leftsubnet=$SMF_N4_IP/32[udp/8805]
    right=$VPLMN_IP
    rightid="C=3G, O=Open5GS, CN=upf.5gc.mnc071.mcc999.3gppnetwork.org"
    rightcert=upf-n4-cert.pem
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
    auto=add
EOF
echo "  ✓ wrote $CERT_DIR/n4-smf-upf.conf"

# ── Ensure the UPF N4 key is loaded (coexists with N9's pc1-upf key) ──
touch /etc/ipsec.secrets; chmod 600 /etc/ipsec.secrets
grep -qE '^\s*:\s*RSA\s+upf-n4-key\.pem' /etc/ipsec.secrets \
    || echo ': RSA upf-n4-key.pem' >> /etc/ipsec.secrets

sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null

if [ "$CONFIG_ONLY" -eq 1 ]; then
    echo "Config-only: drop-in written; charon NOT (re)started."
    exit 0
fi

# Reload if charon is already running (keeps N9 up); otherwise start it.
if ipsec status >/dev/null 2>&1; then
    echo "charon running — reloading (N9 stays up)..."
    ipsec reload
    ipsec rereadall 2>/dev/null || true
else
    echo "charon not running — starting..."
    ipsec start
    sleep 2
fi
echo "✅ N4 responder ready on host (waiting for the SMF to initiate)."
