#!/bin/bash
# ============================================================================
# dongle_iperf.sh — throughput half of the dongle measurement
# ============================================================================
# Runs iperf3 ON the dongle against a server behind the 5G core and prints the
# run as one machine-readable line. Assumes the dongle is ALREADY up and
# registered — bring it up first with dongle_cp_setup.sh (or the WebUI).
#
# Sibling of dongle_ping.sh and driven the same way: the WebUI SSHes here, this
# script SSHes on to the dongle, and the WebUI parses the prefixed lines.
#
# The dongle carries a real iperf3 (3.1.3), so nothing is installed or copied.
# iperf3 -J buffers its JSON until the run ends, so there is no per-second
# streaming to forward; the whole document is emitted once, on one line:
#
#   IPERF_JSON {...}          the unmodified iperf3 -J document
#   RESULT_JSON {"ok":true}   or {"ok":false,"error":"…"} if the run failed
#
# The WebUI reads IPERF_JSON with exactly the same code path it uses for
# PacketRusher's iperf3, so the dashboard renders both identically.
#
# Usage:
#   dongle_iperf.sh [-s server] [-p port] [-t seconds] [-P streams] [-R] [-u]
# ============================================================================

set -u
# This host runs a German locale; pin C so numbers stay dot-decimal in JSON.
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${DONGLE_ENV_FILE:-$SCRIPT_DIR/dongle_env.sh}"

SERVER="${IPERF_SERVER:-}"
PORT="${IPERF_PORT:-5201}"
DURATION="${IPERF_TIME:-10}"
PARALLEL="${IPERF_PARALLEL:-1}"
REVERSE=""
UDP=""
BANDWIDTH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--server)   SERVER="${2:-}";   shift 2 ;;
        -p|--port)     PORT="${2:-}";     shift 2 ;;
        -t|--time)     DURATION="${2:-}"; shift 2 ;;
        -P|--parallel) PARALLEL="${2:-}"; shift 2 ;;
        -R|--reverse)  REVERSE="-R";      shift ;;
        -u|--udp)      UDP="-u";          shift ;;
        -b|--bandwidth) BANDWIDTH="${2:-}"; shift 2 ;;
        -h|--help)     sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

log() { printf '%s\n' "$*"; }
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
emit_failure() { printf 'RESULT_JSON {"ok":false,"error":"%s"}\n' "$(json_escape "$1")"; }
fail() { printf '❌ %s\n' "$*" >&2; emit_failure "$*"; exit 1; }

[[ -r "$ENV_FILE" ]] || fail "Missing config file: $ENV_FILE"
# shellcheck source=/dev/null
source "$ENV_FILE"

# REMOTE_TARGET is the ping destination; it doubles as the default iperf server.
SERVER="${SERVER:-$REMOTE_TARGET}"

[[ "$PORT"     =~ ^[0-9]+$ ]] || fail "Invalid port: $PORT"
[[ "$DURATION" =~ ^[0-9]+$ ]] || fail "Invalid duration: $DURATION"
[[ "$PARALLEL" =~ ^[0-9]+$ ]] || fail "Invalid parallel stream count: $PARALLEL"
(( DURATION >= 1 && DURATION <= 300 )) || fail "Duration out of range (1-300): $DURATION"
[[ -z "$BANDWIDTH" || "$BANDWIDTH" =~ ^[0-9]+(\.[0-9]+)?[KMG]?$ ]] || fail "Invalid bandwidth: $BANDWIDTH (e.g. 50M)"
command -v sshpass  >/dev/null 2>&1 || fail "'sshpass' is required on this host but is not installed"
command -v python3  >/dev/null 2>&1 || fail "'python3' is required on this host but is not installed"

DONGLE_SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=5
    -p "$SSH_PORT"
)
# Reach the dongle through the control host (dongle_env.sh): the dongle is a
# USB device there and only reachable on its USB network.
DONGLE_SSH_OPTS+=("${DONGLE_JUMP_OPTS[@]}")
dongle_ssh() { sshpass -e ssh "${DONGLE_SSH_OPTS[@]}" root@"$SSH_HOST" "$@"; }

log "🔍 Checking the dongle is reachable at $SSH_HOST:$SSH_PORT"
dongle_ssh "true" >/dev/null 2>&1 \
    || fail "Cannot reach the dongle at $SSH_HOST:$SSH_PORT — is it up and registered? Run the dongle (control-plane) step first."
log "✅ Dongle reachable"

dongle_ssh "command -v iperf3" >/dev/null 2>&1 \
    || fail "iperf3 is not installed on the dongle"

IPERF_CMD="iperf3 -c $SERVER -p $PORT -t $DURATION -i 1 -J"
(( PARALLEL > 1 )) && IPERF_CMD+=" -P $PARALLEL"
[[ -n "$REVERSE" ]] && IPERF_CMD+=" $REVERSE"
[[ -n "$UDP"     ]] && IPERF_CMD+=" $UDP"
[[ -n "$BANDWIDTH" ]] && IPERF_CMD+=" -b $BANDWIDTH"

log "📶 $IPERF_CMD  (from the dongle)"

# Budget: the transfer plus handshake/teardown slack, so a wedged run cannot
# hang the WebUI job forever.
BUDGET=$(( DURATION + 30 ))

raw=$(timeout "$BUDGET" sshpass -e ssh "${DONGLE_SSH_OPTS[@]}" \
          root@"$SSH_HOST" "$IPERF_CMD" 2>/dev/null)
rc=$?

if (( rc == 124 )); then
    fail "iperf3 timed out after ${BUDGET}s without completing"
fi
if [[ -z "$raw" ]]; then
    fail "iperf3 produced no output on the dongle (exit $rc)"
fi

# Collapse to a single line and surface iperf3's own error field, which it
# reports inside the JSON with a zero-ish exit rather than on stderr.
compact=$(printf '%s' "$raw" | python3 -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except Exception as e:
    print("PARSE_ERROR " + str(e))
    sys.exit(0)
err = doc.get("error")
if err:
    print("IPERF_ERROR " + str(err))
    sys.exit(0)
print("IPERF_JSON " + json.dumps(doc, separators=(",", ":")))
')

case "$compact" in
    PARSE_ERROR*) fail "Could not parse iperf3 output: ${compact#PARSE_ERROR }" ;;
    IPERF_ERROR*) fail "iperf3: ${compact#IPERF_ERROR }" ;;
esac

printf '%s\n' "$compact"
printf 'RESULT_JSON {"ok":true,"server":"%s","port":%s,"duration":%s}\n' \
    "$(json_escape "$SERVER")" "$PORT" "$DURATION"
