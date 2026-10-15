#!/bin/bash
# ============================================================================
# dongle_download.sh — HTTP(S) download half of the dongle measurement
# ============================================================================
# Downloads a URL ON the dongle, through the 5G bearer, and reports size, speed
# and the connection timing breakdown. Assumes the dongle is ALREADY up and
# registered — bring it up first with dongle_cp_setup.sh (or the WebUI).
#
# Sibling of dongle_ping.sh / dongle_iperf.sh and driven the same way: the
# WebUI SSHes here, this script SSHes on to the dongle, and the WebUI parses
# the prefixed lines.
#
# The dongle carries a real curl (7.84.0, OpenSSL), so https:// works and the
# full timing breakdown is available — same fields the PacketRusher path
# reports, so the dashboard renders both identically:
#
#   DL_JSON {"size_download":…,"speed_download":…,"time_connect":…,…}
#   RESULT_JSON {"ok":true}   or {"ok":false,"error":"…"} on failure
#
# NOTHING IS WRITTEN ON THE DONGLE: the body goes to /dev/null, so a large
# file cannot fill its small rootfs.
#
# Usage:
#   dongle_download.sh [-u url] [-m max_seconds]
# ============================================================================

set -u
# This host runs a German locale; pin C so numbers stay dot-decimal in JSON.
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${DONGLE_ENV_FILE:-$SCRIPT_DIR/dongle_env.sh}"

URL="${DOWNLOAD_URL:-}"
MAX_TIME="${DOWNLOAD_MAX_TIME:-300}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--url)      URL="${2:-}";      shift 2 ;;
        -m|--max-time) MAX_TIME="${2:-}"; shift 2 ;;
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

# Default to the perf server's 10MB object, derived from the same host the
# ping targets so one env change moves every dongle measurement together.
URL="${URL:-http://$REMOTE_TARGET:9000/10MB.bin}"

[[ "$MAX_TIME" =~ ^[0-9]+$ ]] || fail "Invalid max-time: $MAX_TIME"
# Only http/https, and no shell metacharacters — this string is passed through
# two SSH hops and ends up inside a remote shell command.
[[ "$URL" =~ ^https?://[A-Za-z0-9._~:/?#@!$\&\'\(\)*+,\;=%-]+$ ]] \
    || fail "Invalid or unsupported URL: $URL"
command -v sshpass >/dev/null 2>&1 || fail "'sshpass' is required on this host but is not installed"

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

dongle_ssh "command -v curl" >/dev/null 2>&1 \
    || fail "curl is not installed on the dongle"

# Same field set the WebUI already parses for the PacketRusher download, so
# both paths produce identical result objects.
CURL_FORMAT='{"size_download":%{size_download},"speed_download":%{speed_download},"time_namelookup":%{time_namelookup},"time_connect":%{time_connect},"time_appconnect":%{time_appconnect},"time_starttransfer":%{time_starttransfer},"time_total":%{time_total},"http_code":%{http_code},"remote_ip":"%{remote_ip}"}'
CURL_CMD="curl --silent --show-error --location --output /dev/null --max-time $MAX_TIME --connect-timeout 30 --write-out '$CURL_FORMAT' '$URL'"

log "⬇️  $URL  (from the dongle)"

BUDGET=$(( MAX_TIME + 30 ))
out=$(timeout "$BUDGET" sshpass -e ssh "${DONGLE_SSH_OPTS[@]}" \
          root@"$SSH_HOST" "$CURL_CMD" 2>&1)
rc=$?

(( rc == 124 )) && fail "download timed out after ${BUDGET}s without completing"

# curl writes the JSON last; anything before it is an error message from curl
# or from ssh, so pick the trailing line that actually looks like our object.
line=$(printf '%s\n' "$out" | tr -d '\r' | grep -o '{"size_download".*}' | tail -1)
if [[ -z "$line" ]]; then
    reason=$(printf '%s' "$out" | tr -d '\r' | tr '\n' ' ' | sed 's/  */ /g')
    fail "curl produced no result on the dongle (exit $rc): ${reason:0:200}"
fi

http_code=$(printf '%s' "$line" | sed -n 's/.*"http_code":\([0-9]*\).*/\1/p')
if [[ "$http_code" != "200" ]]; then
    fail "HTTP $http_code from $URL"
fi

printf 'DL_JSON %s\n' "$line"
printf 'RESULT_JSON {"ok":true,"url":"%s"}\n' "$(json_escape "$URL")"
