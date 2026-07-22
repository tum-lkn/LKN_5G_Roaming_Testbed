#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# lib/features/browsertime_5g.sh — Measure web performance through PacketRusher 5G UE
#
# Usage: ./lib/features/browsertime_5g.sh [options] <url> [url2 ...]
#
# Requires PacketRusher to be running with an active UE session.
# Traffic is routed through the GTP tunnel via policy routing.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PR_CONTAINER="packetrusher"
BT_IMAGE="sitespeedio/browsertime"

# Fixed container name, deliberately shared with the WebUI's browsertime run.
# Every run joins PacketRusher's network namespace, where the ip rules below are
# global rather than per-container, so two concurrent runs silently delete each
# other's routing. Reusing one name makes Docker refuse the second run outright.
BT_CONTAINER="roamingtb-browsertime"

# Resolvers for the browser, applied inside the container.
#
# The image otherwise inherits the host's resolvers, which are typically
# site-local (campus/corporate) addresses reachable only via the host's default
# route. Traffic to them is pushed into the tunnel by the routing rules below
# and never arrives, so every lookup hangs and no page ever loads. A public
# resolver is reachable through the tunnel, keeps DNS latency inside the
# measured 5G path, and carries no site-specific assumptions.
# Override with --dns "1.1.1.1 9.9.9.9" if these are blocked on your network.
DNS_SERVERS="8.8.8.8 1.1.1.1"

# Defaults
ITERATIONS=3
BROWSER="firefox"
VIDEO="false"
VISUAL_METRICS="false"
RUN_TS=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="$SCRIPT_DIR/browsertime-5g-results/$RUN_TS"

# ============================================================================
# Usage
# ============================================================================
usage() {
    echo "Usage: $0 [options] <url> [url2 ...]"
    echo ""
    echo "Options:"
    echo "  -n, --iterations N   Number of iterations per URL (default: 3)"
    echo "  -b, --browser NAME   Browser: firefox, chrome or edge (default: firefox)"
    echo "  -o, --output DIR     Output directory (default: ./browsertime-5g-results)"
    echo "  --dns \"IP [IP...]\"   Resolvers used inside the container"
    echo "                       (default: $DNS_SERVERS)"
    echo "  --video              Enable video and visual metrics recording"
    echo "  -h, --help           Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 https://www.example.com"
    echo "  $0 -n 5 https://www.google.com https://www.github.com"
    echo "  $0 --video -b firefox https://www.example.com"
    exit 0
}

# ============================================================================
# Argument parsing
# ============================================================================
URLS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--iterations) ITERATIONS="$2"; shift 2 ;;
        -b|--browser)    BROWSER="$2"; shift 2 ;;
        -o|--output)     OUTPUT_DIR="$2"; shift 2 ;;
        --dns)           DNS_SERVERS="$2"; shift 2 ;;
        --video)         VIDEO="true"; VISUAL_METRICS="true"; shift ;;
        -h|--help)       usage ;;
        http*)           URLS+=("$1"); shift ;;
        *)               echo "Unknown argument: $1"; usage ;;
    esac
done

if [[ ${#URLS[@]} -eq 0 ]]; then
    echo "Error: No URLs specified."
    echo ""
    usage
fi

# ============================================================================
# Preflight checks
# ============================================================================
echo "======================================="
echo " Browsertime 5G Performance Test"
echo "======================================="
echo ""

# Check PacketRusher container is running
PR_STATUS=$(sudo docker inspect --format '{{.State.Status}}' "$PR_CONTAINER" 2>/dev/null || echo "not_found")
if [[ "$PR_STATUS" != "running" ]]; then
    echo "Error: PacketRusher container '$PR_CONTAINER' is not running (status: $PR_STATUS)."
    echo "Start it first with: ./lib/features/start_packetrusher.sh"
    exit 1
fi

# Detect VRF name (first VRF in the PacketRusher container)
VRF_NAME=$(sudo docker exec "$PR_CONTAINER" ip vrf show 2>/dev/null \
    | awk 'NR>1 && /^[a-z]/ {print $1; exit}')
if [[ -z "$VRF_NAME" ]]; then
    echo "Error: No VRF found inside PacketRusher container."
    echo "Is the UE registered? Check: sudo docker logs $PR_CONTAINER | tail -10"
    exit 1
fi

# Detect UE IP from PacketRusher logs
# Note: log lines contain ANSI color codes and a trailing \r, so no $ anchor
UE_IP=$(sudo docker logs "$PR_CONTAINER" 2>&1 \
    | grep "PDU address received:" \
    | tail -1 \
    | grep -oP '\d+\.\d+\.\d+\.\d+' \
    | head -1)
if [[ -z "$UE_IP" ]]; then
    echo "Error: Could not detect UE IP from PacketRusher logs."
    echo "Check: sudo docker logs $PR_CONTAINER | grep 'PDU address'"
    exit 1
fi

# Refuse to run concurrently. Runs share PacketRusher's network namespace, so a
# second run would delete the first one's ip rules on startup and again on exit,
# breaking both. The fixed container name is the lock.
BT_STATE=$(sudo docker inspect -f '{{.State.Status}}' "$BT_CONTAINER" 2>/dev/null || echo "absent")
if [[ "$BT_STATE" == "running" ]]; then
    echo "Error: a browsertime run is already in progress (container '$BT_CONTAINER')."
    echo "Concurrent runs corrupt each other's routing, so this run is refused."
    echo "Wait for it to finish, or stop it with:"
    echo "  sudo docker rm -f $BT_CONTAINER"
    exit 1
elif [[ "$BT_STATE" != "absent" ]]; then
    echo "Removing stale browsertime container from an earlier run..."
    sudo docker rm -f "$BT_CONTAINER" >/dev/null 2>&1 || true
fi

echo "PacketRusher VRF : $VRF_NAME"
echo "UE IP            : $UE_IP"
echo "Browser          : $BROWSER"
echo "Iterations       : $ITERATIONS"
echo "Video            : $VIDEO"
echo "Output dir       : $OUTPUT_DIR"
echo ""

mkdir -p "$OUTPUT_DIR"

# ============================================================================
# Enable VRF l3mdev socket acceptance in PacketRusher's network namespace
#
# Linux VRFs isolate socket lookups per L3 domain.  Without this sysctl,
# unbound sockets (Firefox, curl) cannot match TCP/UDP replies that arrive on
# the VRF slave interface (val0000000001), causing the kernel to send RST
# immediately after every SYN-ACK.  Setting tcp/udp_l3mdev_accept=1 allows
# any unbound socket to accept connections from any VRF.
# ============================================================================
PR_PID=$(sudo docker inspect -f '{{.State.Pid}}' "$PR_CONTAINER" 2>/dev/null || true)
if [[ -z "$PR_PID" ]]; then
    echo "Error: Could not get PacketRusher container PID."
    exit 1
fi

ORIG_TCP_L3MDEV=$(sudo nsenter --net=/proc/"$PR_PID"/ns/net -- \
    sysctl -n net.ipv4.tcp_l3mdev_accept 2>/dev/null || echo 0)
ORIG_UDP_L3MDEV=$(sudo nsenter --net=/proc/"$PR_PID"/ns/net -- \
    sysctl -n net.ipv4.udp_l3mdev_accept 2>/dev/null || echo 0)

_cleanup() {
    # Remove the container first: it lives in PacketRusher's netns and is still
    # using the l3mdev settings restored below. On Ctrl+C the shell gets the
    # signal directly, so without this the container would outlive the script.
    sudo docker rm -f "$BT_CONTAINER" >/dev/null 2>&1 || true
    # docker rm -f is a SIGKILL, so the container's own EXIT trap never runs and
    # its ip rules would stay behind in PacketRusher's namespace, sending
    # unrelated traffic into the tunnel. Remove them from out here too.
    for p in 5 6 50; do
        while sudo nsenter --net=/proc/"$PR_PID"/ns/net -- \
            ip rule del priority "$p" 2>/dev/null; do :; done
    done
    sudo nsenter --net=/proc/"$PR_PID"/ns/net -- \
        sysctl -w net.ipv4.tcp_l3mdev_accept="$ORIG_TCP_L3MDEV" >/dev/null 2>&1 || true
    sudo nsenter --net=/proc/"$PR_PID"/ns/net -- \
        sysctl -w net.ipv4.udp_l3mdev_accept="$ORIG_UDP_L3MDEV" >/dev/null 2>&1 || true
}
trap _cleanup EXIT

echo "  Enabling VRF l3mdev socket accept in PacketRusher netns (PID $PR_PID)..."
sudo nsenter --net=/proc/"$PR_PID"/ns/net -- \
    sysctl -w net.ipv4.tcp_l3mdev_accept=1 >/dev/null
sudo nsenter --net=/proc/"$PR_PID"/ns/net -- \
    sysctl -w net.ipv4.udp_l3mdev_accept=1 >/dev/null
echo "  l3mdev accept: enabled (was tcp=$ORIG_TCP_L3MDEV udp=$ORIG_UDP_L3MDEV)"
echo ""

# ============================================================================
# Build browser-specific flags
# ============================================================================
# Routing is handled at the kernel level (policy routing), not via browser prefs.
# Firefox gets one extra preference to avoid IPv6 DNS that may not traverse the tunnel.
EXTRA_ARGS=""
case "$BROWSER" in
    firefox) EXTRA_ARGS="--firefox.preference network.dns.disableIPv6:true" ;;
    chrome)  EXTRA_ARGS="--chrome.args no-sandbox --chrome.args disable-ipv6" ;;
    edge)    EXTRA_ARGS="--edge.args no-sandbox --edge.args disable-ipv6" ;;
esac

# ============================================================================
# Run Browsertime for each URL
# ============================================================================
TOTAL=${#URLS[@]}
COUNT=0

for URL in "${URLS[@]}"; do
    COUNT=$((COUNT + 1))
    echo "[$COUNT/$TOTAL] Testing: $URL"

    sudo docker run --rm \
        --name "$BT_CONTAINER" \
        --net container:"$PR_CONTAINER" \
        --cap-add NET_ADMIN \
        -v "$OUTPUT_DIR":/browsertime \
        --entrypoint /bin/sh \
        "$BT_IMAGE" \
        -c "
            VRF_TABLE=\$(ip -d link show $VRF_NAME | grep -oP 'table \K[0-9]+')
            VAL_IFACE=\$(ip link show master $VRF_NAME 2>/dev/null | grep -oP '^\\d+: \K[^@: ]+' | head -1)
            echo \"  VRF: $VRF_NAME (table \$VRF_TABLE)  tunnel: \$VAL_IFACE\"
            TX_BEFORE=\$(cat /sys/class/net/\$VAL_IFACE/statistics/tx_bytes 2>/dev/null || echo 0)
            RX_BEFORE=\$(cat /sys/class/net/\$VAL_IFACE/statistics/rx_bytes 2>/dev/null || echo 0)
            # Point the browser at a resolver that is reachable through the
            # tunnel. Without this the container keeps the host's site-local
            # resolvers, whose traffic the priority-50 rule below sends into the
            # tunnel, where they do not exist — every lookup then hangs until
            # browsertime's 120s page timeout and no page ever loads.
            : > /etc/resolv.conf
            for ns in $DNS_SERVERS; do
                echo \"nameserver \$ns\" >> /etc/resolv.conf
            done
            echo \"  DNS: $DNS_SERVERS (via tunnel)\"
            # Drop anything left at our priorities by an interrupted run. Deleting
            # by priority also clears rules written by older versions of this
            # script, which used a different (hardcoded-subnet) form. Priorities
            # 5, 6 and 50 are used only here; the defaults are 0/32766/32767.
            # This runs before the address lookup below, so that lookup sees the
            # unmodified main-table routing.
            for p in 5 6 50; do
                while ip rule del priority \$p 2>/dev/null; do :; done
            done
            cleanup() {
                for p in 5 6 50; do
                    while ip rule del priority \$p 2>/dev/null; do :; done
                done
            }
            trap cleanup EXIT

            # PacketRusher's GTP-U source address — never hardcoded, since every
            # deployment addresses its gNB differently.
            #
            # Read from the live GTP-U socket bind (we share PacketRusher's
            # network namespace, so its sockets are visible here). That is the
            # exact source address the encapsulated packets will carry, so it
            # stays correct even if the gNB is multi-homed or configured with an
            # N3 address that is not on the default-route interface.
            PR_SRC=\$(ss -unaH 2>/dev/null | awk '\$4 ~ /:2152\$/ {sub(/:2152\$/,\"\",\$4); print \$4; exit}')
            # Reject a wildcard bind (0.0.0.0), an IPv6 bind, or no ss at all.
            case \"\$PR_SRC\" in
                \"\"|0.0.0.0|*[!0-9.]*) PR_SRC=\"\" ;;
            esac
            if [ -z \"\$PR_SRC\" ]; then
                # Fallback: the address on the interface holding the default route.
                PR_IFACE=\$(ip -o route show table main default | grep -oP 'dev \K\S+' | head -1)
                PR_SRC=\$(ip -4 -o addr show dev \"\$PR_IFACE\" 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -1)
            fi
            if [ -z \"\$PR_SRC\" ]; then
                echo 'ERROR: could not determine the gNB GTP-U source address.' >&2
                echo 'Without it the tunnel encapsulation would be routed into' >&2
                echo 'the tunnel itself. Refusing to continue.' >&2
                exit 1
            fi

            # Split routing, deriving every value at runtime:
            #
            #   priority 5   PacketRusher's own traffic — the GTP-U it sends to
            #                the UPF and its NGAP to the AMF — is sourced from
            #                \$PR_SRC and must keep using the host network. The
            #                UPF's N3 endpoint is typically reachable only via
            #                this namespace's default route, so without this the
            #                next rule would route the tunnel's own encapsulation
            #                back into the tunnel: a loop that shows up as TX
            #                errors on the val interface and passes no traffic.
            #   priority 6   anything with a specific route (link subnets, docker
            #                bridges) stays local; main's default route is
            #                suppressed so it cannot swallow internet traffic.
            #   priority 50  everything else — the internet — goes to the VRF
            #                table and out through the val tunnel into the 5G
            #                core. The browser's sockets are unbound, so they
            #                have no source address at lookup time, miss the
            #                priority 5 rule, and land here as intended.
            echo \"  Routing: \$PR_SRC via \$PR_IFACE (host), internet via tunnel\"
            ip rule add from \$PR_SRC lookup main priority 5
            ip rule add from all lookup main suppress_prefixlength 0 priority 6
            ip rule add from all lookup \$VRF_TABLE priority 50
            /start.sh \
                --browser $BROWSER \
                $EXTRA_ARGS \
                --iterations $ITERATIONS \
                --video $VIDEO \
                --visualMetrics $VISUAL_METRICS \
                $URL
            TX_AFTER=\$(cat /sys/class/net/\$VAL_IFACE/statistics/tx_bytes 2>/dev/null || echo 0)
            RX_AFTER=\$(cat /sys/class/net/\$VAL_IFACE/statistics/rx_bytes 2>/dev/null || echo 0)
            TX_DELTA=\$(( TX_AFTER - TX_BEFORE ))
            RX_DELTA=\$(( RX_AFTER - RX_BEFORE ))
            echo \"\"
            echo \"  [5G traffic check] \$VAL_IFACE: sent \${TX_DELTA} bytes, received \${RX_DELTA} bytes via GTP tunnel\"
            if [ \"\$TX_DELTA\" -gt 0 ] && [ \"\$RX_DELTA\" -gt 0 ]; then
                echo \"  [5G traffic check] PASS — traffic routed through 5G core\"
            else
                echo \"  [5G traffic check] WARN — no tunnel traffic detected\"
            fi
        "
    echo ""
done

# ============================================================================
# Summary
# ============================================================================
echo "======================================="
echo " Done. Results saved to:"
echo " $OUTPUT_DIR"
echo "======================================="
echo ""
echo "Quick summary (TTFB / Load):"
find "$OUTPUT_DIR" -name "browsertime.json" | sort | while read -r f; do
    DIR=$(dirname "$f")
    DOMAIN=$(basename "$(dirname "$DIR")")
    TTFB=$(python3 -c "
import json, sys
d = json.load(open('$f'))
stats = d[0].get('statistics', {}).get('timings', {})
ttfb = stats.get('ttfb', {}).get('median', 'n/a')
# Page Load = standard loadEventEnd (pageLoadTime); fullyLoaded only as fallback
load = stats.get('pageTimings', {}).get('pageLoadTime', stats.get('fullyLoaded', {})).get('median', 'n/a')
print(f'TTFB={ttfb}ms  Load={load}ms')
" 2>/dev/null || echo "(parse error)")
    echo "  $DOMAIN : $TTFB"
done
