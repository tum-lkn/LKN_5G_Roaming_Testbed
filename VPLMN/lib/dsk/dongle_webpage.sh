#!/bin/bash
# ============================================================================
# dongle_webpage.sh — page-load half of the dongle measurement
# ============================================================================
# Runs Browsertime (a real Firefox/Chrome) against a URL with every packet
# routed through the dongle's 5G bearer, and prints the page timings.
#
# WHERE THE BROWSER RUNS: on THIS control host, not on the dongle. The dongle
# is a modem — 227MB RAM, one ARMv7 core, a read-only 52MB rootfs and no node,
# npm or browser — so it cannot host a browser. What it can do is route, which
# is exactly what it is for: ip_forward is on and it masquerades its LAN out
# rmnet_data0. So the browser runs here and the dongle carries its traffic,
# the same as tethering a laptop to a phone. Measured cost of that extra USB
# hop against the same target: 22.3ms tethered vs 22.5ms from the dongle
# itself — under the noise floor of the radio.
#
# HOW THE TRAFFIC IS PINNED: the container is attached to a macvlan network
# whose gateway is the dongle, so its ONLY route is through the radio. This
# matters because this host also has a direct wired path to the testbed and
# the lab; without the pinning a run would silently measure the LAN and return
# plausible, wrong numbers. There is no route out of that namespace that does
# not cross the radio, so it cannot leak by construction.
#
# Sibling of dongle_ping.sh / dongle_iperf.sh / dongle_download.sh and driven
# the same way — the WebUI SSHes here and parses the prefixed lines:
#
#   <plain lines>              browsertime progress, forwarded to the log view
#   WEBPAGE_JSON {...}         the extracted timings
#   RESULT_JSON {"ok":true}    or {"ok":false,"error":"…"} on failure
#
# Which dongle is used follows SSH_HOST from dongle_env.sh, so the WebUI's
# dongle selector steers this script exactly like the others.
#
# Usage:
#   dongle_webpage.sh -u URL [-b firefox|chrome] [-m max_seconds]
# ============================================================================

set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${DONGLE_ENV_FILE:-$SCRIPT_DIR/dongle_env.sh}"

# The browser has to run where the dongle is plugged in (see above). Called
# on the VPLMN, this script ships itself to the control host for the run
# and removes itself there afterwards (dongle_env.sh: ctrl_run_bundle);
# there, DONGLE_ON_CTRL=1 and everything below runs as before.
if [[ "${DONGLE_ON_CTRL:-0}" != 1 ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE" || { printf 'RESULT_JSON {"ok":false,"error":"Missing %s"}\n' "$ENV_FILE"; exit 1; }
    ctrl_run_bundle "$(basename "${BASH_SOURCE[0]}")" "$@"
    exit $?
fi

URL="${WEBPAGE_URL:-}"
BROWSER="${WEBPAGE_BROWSER:-firefox}"
MAX_TIME="${WEBPAGE_MAX_TIME:-180}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--url)      URL="${2:-}";      shift 2 ;;
        -b|--browser)  BROWSER="${2:-}";  shift 2 ;;
        -m|--max-time) MAX_TIME="${2:-}"; shift 2 ;;
        -h|--help)     sed -n '2,36p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

log() { printf '%s\n' "$*"; }
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
emit_failure() { printf 'RESULT_JSON {"ok":false,"error":"%s"}\n' "$(json_escape "$1")"; }

BT_IMAGE="sitespeedio/browsertime"
# Fixed name so a run is addressable and a second one cannot start on top of
# the first — same reasoning as the PacketRusher path.
BT_CONTAINER="roamingtb-browsertime-dongle"
# Public resolvers: the host's are lab-internal and unreachable through the
# radio, so every lookup would hang until browsertime's page timeout.
BT_DNS=(--dns 8.8.8.8 --dns 1.1.1.1)

NET_NAME=""
NET_CREATED=0
OUTPUT_DIR=""

cleanup() {
    docker rm -f "$BT_CONTAINER" >/dev/null 2>&1 || true
    # Only tear the network down if this run created it, so a concurrent run
    # (or a pre-existing one someone else made) is left alone.
    if (( NET_CREATED )) && [[ -n "$NET_NAME" ]]; then
        docker network rm "$NET_NAME" >/dev/null 2>&1 || true
    fi
    # Results are transient: the WebUI has already parsed what it needs, and
    # the dongle scripts deliberately leave nothing behind on disk.
    [[ -n "$OUTPUT_DIR" && -d "$OUTPUT_DIR" ]] && rm -rf "$OUTPUT_DIR"
}
trap cleanup EXIT

fail() { printf '❌ %s\n' "$*" >&2; emit_failure "$*"; exit 1; }

[[ -r "$ENV_FILE" ]] || fail "Missing config file: $ENV_FILE"
# shellcheck source=/dev/null
source "$ENV_FILE"

[[ -n "$URL" ]] || fail "No URL given (-u)"
[[ "$URL" =~ ^https?://[A-Za-z0-9._~:/?#@!$\&\'\(\)*+,\;=%-]+$ ]] || fail "Invalid URL: $URL"
[[ "$BROWSER" =~ ^(firefox|chrome)$ ]] || fail "Invalid browser: $BROWSER (firefox or chrome)"
[[ "$MAX_TIME" =~ ^[0-9]+$ ]] || fail "Invalid max-time: $MAX_TIME"
command -v docker  >/dev/null 2>&1 || fail "docker is not available on this host"
command -v python3 >/dev/null 2>&1 || fail "python3 is required on this host but is not installed"

# ── Find the link to the selected dongle ────────────────────────────────
# Derived from SSH_HOST rather than hardcoded, so switching dongles in the
# WebUI moves this to the other USB interface with no config change.
IFACE=$(ip -o route get "$SSH_HOST" 2>/dev/null | grep -oP 'dev \K\S+' | head -1)
[[ -n "$IFACE" ]] || fail "No route to the dongle at $SSH_HOST — is it plugged in and up?"
CIDR=$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | head -1)
[[ -n "$CIDR" ]] || fail "Interface $IFACE has no IPv4 address"
PREFIX="${CIDR#*/}"
SUBNET=$(python3 -c "import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1], strict=False))" "$CIDR")

log "🔍 Dongle $SSH_HOST is on $IFACE ($SUBNET, host $CIDR)"

ping -c1 -W3 -I "$IFACE" "$SSH_HOST" >/dev/null 2>&1 \
    || fail "The dongle at $SSH_HOST does not answer on $IFACE — is it up and registered?"
log "✅ Dongle reachable and forwarding"

# ── Keep the dongle's USB link at USB 2 ─────────────────────────────────
# This is the one dongle test whose traffic crosses the USB link, and at USB 3
# that link stalls under it for good (see dongle_usb.sh for the measurements).
# dongle_status.sh already switches every dongle to USB 2 as soon as it shows
# up; this is the safety net for a run started before that happened.
# shellcheck source=/dev/null
source "$SCRIPT_DIR/dongle_usb.sh" || fail "Missing $SCRIPT_DIR/dongle_usb.sh"
USB_SPEED=$(usb_speed_of "$IFACE")
if [[ "${DONGLE_ALLOW_SUPERSPEED:-0}" != 1 && "$USB_SPEED" =~ ^[0-9]+$ ]] && (( USB_SPEED >= 5000 )); then
    log "⚠️  Dongle is on a USB 3 link (${USB_SPEED} Mbps), whose data path stalls under a page load"
    if ! docker image inspect "$BT_IMAGE" >/dev/null 2>&1; then
        log "⬇️  Pulling $BT_IMAGE (first run only, ~1GB)..."
        docker pull -q "$BT_IMAGE" >/dev/null 2>&1 || fail "Could not pull $BT_IMAGE"
    fi
    switched=$(DONGLE_USB_IMAGE="$BT_IMAGE" dongle_force_usb2)
    [[ -n "$switched" ]] \
        || fail "The dongle is on a USB 3 link (${USB_SPEED} Mbps), which stalls under this test, and its port could not be switched to USB 2 from here. Plug it in through a USB 2 port or hub."
    log "🔌 Switched $(echo $switched) to USB 2 — waiting for the dongle to re-attach..."

    # Wait for it back on the link, then for its PDU session: the modem keeps
    # its registration, but nothing may be measured before the bearer is up.
    back=0
    for _ in $(seq 1 30); do
        sleep 2
        ping -c1 -W1 "$SSH_HOST" >/dev/null 2>&1 && { back=1; break; }
    done
    (( back )) || fail "The dongle did not come back after switching to USB 2 — check it, then retry."
    IFACE=$(ip -o route get "$SSH_HOST" 2>/dev/null | grep -oP 'dev \K\S+' | head -1)
    log "✅ Dongle back on USB 2 ($(usb_speed_of "$IFACE")Mbps)"
    attached=0
    for _ in $(seq 1 30); do
        "$SCRIPT_DIR/dongle_status.sh" 2>/dev/null | grep -q '"attached":true' && { attached=1; break; }
        sleep 2
    done
    (( attached )) || fail "The dongle is back on USB 2 but its PDU session is not up yet — retry in a moment."
    log "✅ PDU session up"
fi

# ── Pin a container network to the dongle ───────────────────────────────
NET_NAME="dongle-net-${SSH_HOST//./-}"

# Reuse ANY macvlan network already bound to this interface, whatever it is
# called. Docker refuses a second network whose subnet overlaps an existing
# one, so a leftover from an interrupted run — or from another tool — blocks
# every subsequent run. That used to surface as "does the link accept multiple
# MACs?", which points at the hardware and sends you down the wrong path; the
# real cause is almost always a stale network holding the subnet.
EXISTING=""
while read -r id; do
    [[ -z "$id" ]] && continue
    if [[ "$(docker network inspect "$id" --format '{{index .Options "parent"}}' 2>/dev/null)" == "$IFACE" ]]; then
        EXISTING=$(docker network inspect "$id" --format '{{.Name}}' 2>/dev/null)
        EXISTING_GW=$(docker network inspect "$id" --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)
        break
    fi
done < <(docker network ls -q --filter driver=macvlan)

if [[ -n "$EXISTING" ]]; then
    # Only usable if it points at the dongle we are actually measuring through.
    if [[ "$EXISTING_GW" != "$SSH_HOST" ]]; then
        fail "The macvlan network '$EXISTING' is already bound to $IFACE but its gateway is '$EXISTING_GW', not the dongle ($SSH_HOST). Remove it and retry: docker network rm $EXISTING"
    fi
    NET_NAME="$EXISTING"
    log "♻️  Reusing macvlan network $NET_NAME (gateway $SSH_HOST via $IFACE)"
else
    # .16/28 keeps well clear of the dongle (.1) and this host (.2), and of
    # any DHCP range the dongle hands out to real tethered clients.
    IP_RANGE=$(python3 -c "
import ipaddress,sys
net = ipaddress.ip_network(sys.argv[1])
print(f'{list(net.hosts())[15]}/28')" "$SUBNET")
    err=$(docker network create -d macvlan \
            --subnet="$SUBNET" --gateway="$SSH_HOST" --ip-range="$IP_RANGE" \
            -o parent="$IFACE" "$NET_NAME" 2>&1 >/dev/null)
    if [[ -n "$err" ]]; then
        # Tell the two failures apart: a subnet already spoken for is a stale
        # network you can delete, whereas anything else really is the link or
        # the driver refusing macvlan.
        case "$err" in
            *overlap*|*Pool*|*pool*|*already*exists*|*already*in*use*|*failed*to*allocate*)
                fail "Docker refused the macvlan network: something already covers $SUBNET. This is usually a stale network from an interrupted run — list them with 'docker network ls' and remove the offender with 'docker network rm <name>'. Docker said: $err" ;;
            *)
                fail "Could not create the macvlan network on $IFACE — the link or driver may not accept multiple MAC addresses. Docker said: $err" ;;
        esac
    fi
    NET_CREATED=1
    log "🔗 Created macvlan network $NET_NAME (gateway $SSH_HOST via $IFACE)"
fi

# ── Refuse to run two at once ───────────────────────────────────────────
state=$(docker inspect -f '{{.State.Status}}' "$BT_CONTAINER" 2>/dev/null)
if [[ "$state" == "running" ]]; then
    NET_CREATED=0   # not ours to remove
    fail "A browsertime run is already in progress on this host. Wait for it to finish, then retry."
fi
[[ -n "$state" ]] && docker rm -f "$BT_CONTAINER" >/dev/null 2>&1

if ! docker image inspect "$BT_IMAGE" >/dev/null 2>&1; then
    log "⬇️  Pulling $BT_IMAGE (first run only, ~1GB)..."
    docker pull -q "$BT_IMAGE" >/dev/null 2>&1 || fail "Could not pull $BT_IMAGE"
fi

# Results land beside the other dongle scripts, and are removed on exit.
OUTPUT_DIR=$(mktemp -d "$SCRIPT_DIR/webpage_results.XXXXXX")
chmod 777 "$OUTPUT_DIR"

case "$BROWSER" in
    firefox) BROWSER_ARGS=(--firefox.preference network.dns.disableIPv6:true) ;;
    chrome)  BROWSER_ARGS=(--chrome.args no-sandbox --chrome.args disable-ipv6) ;;
esac

log "🌐 Loading $URL in $BROWSER through the dongle — this may take 30–90 seconds..."

timeout "$MAX_TIME" docker run --rm \
    --name "$BT_CONTAINER" \
    --network "$NET_NAME" \
    "${BT_DNS[@]}" \
    --shm-size 1gb \
    -v "$OUTPUT_DIR:/browsertime" \
    "$BT_IMAGE" \
    --browser "$BROWSER" "${BROWSER_ARGS[@]}" \
    --iterations 1 --video false --visualMetrics false \
    "$URL" 2>&1
rc=$?

(( rc == 124 )) && fail "browsertime timed out after ${MAX_TIME}s"

BT_JSON=$(find "$OUTPUT_DIR" -name browsertime.json -print -quit 2>/dev/null)
[[ -n "$BT_JSON" ]] || fail "No results file — the browser may have failed to load the page (exit $rc)"

# Same median field paths the PacketRusher path uses, so both produce the
# identical metric set and the dashboard renders them the same way.
out=$(python3 - "$BT_JSON" <<'PY'
import json, sys
try:
    doc = json.load(open(sys.argv[1]))
except Exception as e:
    print("PARSE_ERROR " + str(e)); raise SystemExit
entry = doc[0] if doc else {}
if entry.get("markedAsFailure"):
    msgs = entry.get("failureMessages") or ["Page failed to load"]
    print("FAILED " + str(msgs[0])); raise SystemExit
s  = (entry.get("statistics") or {}).get("timings") or {}
pt = s.get("pageTimings") or {}
def med(d, *path):
    for k in path:
        d = (d or {}).get(k) or {}
    return (d or {}).get("median") or 0
ttfb = med(s, "ttfb")
fcp  = med(s, "paintTiming", "first-contentful-paint") or med(s, "timeToContentfulPaint")
lcp  = med(s, "largestContentfulPaint", "renderTime") or med(s, "largestContentfulPaint", "loadTime")
dcl  = med(pt, "domContentLoadedTime")
# Each field carries only its own metric: substituting another one when it is
# missing would report a page whose load event never fired as if it had loaded.
page = med(pt, "pageLoadTime")
total = med(s, "fullyLoaded")
if not page:
    print("FAILED Page did not finish loading — no load event within the timeout"); raise SystemExit
print("WEBPAGE_JSON " + json.dumps({
    "ttfb_ms": round(ttfb), "fcp_ms": round(fcp), "lcp_ms": round(lcp),
    "dcl_ms": round(dcl), "page_load_ms": round(page), "total_time_ms": round(total),
}, separators=(",", ":")))
PY
)

case "$out" in
    PARSE_ERROR*) fail "Could not parse browsertime output: ${out#PARSE_ERROR }" ;;
    FAILED*)      fail "${out#FAILED }" ;;
esac

printf '%s\n' "$out"
printf 'RESULT_JSON {"ok":true,"url":"%s","browser":"%s"}\n' "$(json_escape "$URL")" "$BROWSER"
