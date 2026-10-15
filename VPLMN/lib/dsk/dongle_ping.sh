#!/bin/bash
# ============================================================================
# dongle_ping.sh — user-plane half of the dongle measurement
# ============================================================================
# Pings from the dongle to a target behind the 5G core and reports the RTTs.
# Assumes the dongle is ALREADY up and registered — bring it up first with
# dongle_cp_setup.sh (or the WebUI's dongle button).
#
# Split out of ping_pcap.sh, which is left untouched.
#
# NOTHING IS WRITTEN TO A RESULTS FILE. Each reply is streamed as it arrives,
# both human-readable and as a machine-readable line:
#
#   PING_JSON {"seq":1,"ttl":52,"time_ms":23.4}
#
# and the run ends with a single summary line:
#
#   RESULT_JSON {"ok":true,"target":"…","statistics":{"total":…,
#                "successful":…,"failed":…,"packet_loss":…,
#                "min_ms":…,"avg_ms":…,"max_ms":…}}
#
# The "statistics" object uses the same keys the WebUI already renders for the
# PacketRusher ping panel, so the dashboard can show these results unchanged.
#
# Usage:
#   dongle_ping.sh [-t target] [-c count] [-i interval] [-s payload_bytes]
# ============================================================================

set -u

# This host runs a German locale, where printf '%.2f' rejects a dot-decimal
# like 23.4 and awk would emit comma decimals into the JSON. Pin the C locale.
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${DONGLE_ENV_FILE:-$SCRIPT_DIR/dongle_env.sh}"

COUNT="${PING_COUNT:-10}"
INTERVAL="${PING_INTERVAL:-1}"
PAYLOAD="${PING_SIZE:-}"
TARGET_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--target)   TARGET_OVERRIDE="${2:-}"; shift 2 ;;
        -c|--count)    COUNT="${2:-}";           shift 2 ;;
        -i|--interval) INTERVAL="${2:-}";        shift 2 ;;
        -s|--size)     PAYLOAD="${2:-}";         shift 2 ;;
        -h|--help)     sed -n '2,28p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

log()  { printf '%s\n' "$*"; }
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
emit_failure() { printf 'RESULT_JSON {"ok":false,"error":"%s"}\n' "$(json_escape "$1")"; }
fail() { printf '❌ %s\n' "$*" >&2; emit_failure "$*"; exit 1; }

[[ -r "$ENV_FILE" ]] || fail "Missing config file: $ENV_FILE"
# shellcheck source=/dev/null
source "$ENV_FILE"

# An explicit -t (the WebUI always passes one) is used as given. Without one,
# ping REMOTE_TARGET, or the fallback when it is down (dongle_env.sh).
if [[ -n "$TARGET_OVERRIDE" ]]; then
    REMOTE_TARGET="$TARGET_OVERRIDE"
else
    target=$(resolve_ping_target)
    [[ "$target" != "$REMOTE_TARGET" ]] && log "⚠️  $REMOTE_TARGET does not answer from this host — pinging $target instead"
    REMOTE_TARGET="$target"
fi

[[ "$COUNT"    =~ ^[0-9]+$        ]] || fail "Invalid count: $COUNT"
[[ "$INTERVAL" =~ ^[0-9]+(\.[0-9]+)?$ ]] || fail "Invalid interval: $INTERVAL"
[[ -z "$PAYLOAD" || "$PAYLOAD" =~ ^[0-9]+$ ]] || fail "Invalid payload size: $PAYLOAD"
command -v sshpass >/dev/null 2>&1 || fail "'sshpass' is required on this host but is not installed"

# LogLevel=ERROR: with UserKnownHostsFile=/dev/null every single connection
# re-announces "Permanently added …", which would drown the WebUI log.
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
# -tt: give ping a pty on the dongle so its output is line-buffered and the
# replies stream out one by one instead of arriving in one block at the end.
dongle_ssh_tty() { sshpass -e ssh -tt "${DONGLE_SSH_OPTS[@]}" root@"$SSH_HOST" "$@"; }
dongle_ssh()     { sshpass -e ssh      "${DONGLE_SSH_OPTS[@]}" root@"$SSH_HOST" "$@"; }

log "🔍 Checking the dongle is reachable at $SSH_HOST:$SSH_PORT"
dongle_ssh "true" >/dev/null 2>&1 \
    || fail "Cannot reach the dongle at $SSH_HOST:$SSH_PORT — is it up and registered? Run the dongle (control-plane) step first."
log "✅ Dongle reachable"

PING_CMD="ping -c $COUNT -i $INTERVAL"
[[ -n "$PAYLOAD" ]] && PING_CMD+=" -s $PAYLOAD"
PING_CMD+=" $REMOTE_TARGET"

log "📡 $PING_CMD  (from the dongle)"

# Overall guard so a wedged ping cannot hang the WebUI job forever.
BUDGET=$(printf '%.0f' "$(echo "$COUNT * $INTERVAL + 30" | bc)")

times=()
seqs_seen=0
summary_line=""
ping_rc=0

# Process substitution, not a pipe: a pipe would put the loop in a subshell
# and the collected RTTs would be lost when it exits.
#
# ssh is spelled out here rather than reusing dongle_ssh_tty() because
# `timeout` execs a binary and cannot run a shell function.
while IFS= read -r raw; do
    line="${raw%$'\r'}"
    # Sentinel appended below so the ping's exit status survives the subshell:
    # without it a failure to even launch looks identical to 100% packet loss.
    if [[ "$line" == __PING_EXIT__:* ]]; then
        ping_rc="${line#__PING_EXIT__:}"
        continue
    fi
    # busybox prints "seq=", iputils prints "icmp_seq=" — accept both.
    if [[ "$line" =~ (icmp_)?seq=([0-9]+).*ttl=([0-9]+).*time=([0-9.]+) ]]; then
        seq="${BASH_REMATCH[2]}"; ttl="${BASH_REMATCH[3]}"; t="${BASH_REMATCH[4]}"
        times+=("$t")
        seqs_seen=$((seqs_seen + 1))
        printf '  ↳ seq=%s ttl=%s time=%s ms\n' "$seq" "$ttl" "$t"
        printf 'PING_JSON {"seq":%s,"ttl":%s,"time_ms":%s}\n' "$seq" "$ttl" "$t"
    elif [[ "$line" =~ (round-trip|rtt)\ min ]]; then
        summary_line="$line"
    elif [[ -n "$line" ]]; then
        log "$line"
    fi
done < <(timeout "$BUDGET" sshpass -e ssh -tt "${DONGLE_SSH_OPTS[@]}" \
             root@"$SSH_HOST" "$PING_CMD" 2>&1; echo "__PING_EXIT__:$?")

successful=$seqs_seen
failed=$((COUNT - successful))
(( failed < 0 )) && failed=0

if (( successful == 0 )); then
    case "$ping_rc" in
        0)   reason="No replies from $REMOTE_TARGET — the UE is attached but the target is unreachable" ;;
        124) reason="ping timed out after ${BUDGET}s without completing" ;;
        *)   reason="ping could not be run on the dongle (exit $ping_rc)" ;;
    esac
    printf 'RESULT_JSON {"ok":false,"error":"%s","target":"%s","statistics":{"total":%s,"successful":0,"failed":%s,"packet_loss":100,"min_ms":0,"avg_ms":0,"max_ms":0}}\n' \
        "$(json_escape "$reason")" "$(json_escape "$REMOTE_TARGET")" "$COUNT" "$COUNT"
    printf '❌ %s\n' "$reason" >&2
    exit 1
fi

stats=$(printf '%s\n' "${times[@]}" | awk '
    NR==1 { min=$1; max=$1 }
    { sum+=$1; if($1<min) min=$1; if($1>max) max=$1 }
    END { printf "%.2f %.2f %.2f", min, sum/NR, max }')
min_ms=$(echo "$stats" | cut -d' ' -f1)
avg_ms=$(echo "$stats" | cut -d' ' -f2)
max_ms=$(echo "$stats" | cut -d' ' -f3)
loss=$(printf '%.2f' "$(echo "scale=4; $failed * 100 / $COUNT" | bc)")

[[ -n "$summary_line" ]] && log "📋 dongle reported: $summary_line"
log "✅ $successful/$COUNT replies, ${loss}% loss — min/avg/max = ${min_ms}/${avg_ms}/${max_ms} ms"

printf 'RESULT_JSON {"ok":true,"target":"%s","statistics":{"total":%s,"successful":%s,"failed":%s,"packet_loss":%s,"min_ms":%s,"avg_ms":%s,"max_ms":%s}}\n' \
    "$(json_escape "$REMOTE_TARGET")" "$COUNT" "$successful" "$failed" "$loss" "$min_ms" "$avg_ms" "$max_ms"
