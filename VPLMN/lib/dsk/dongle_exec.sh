#!/bin/bash
# ============================================================================
# dongle_exec.sh — run ONE command on the selected dongle and pass its output
# ============================================================================
# The automation on the VPLMN (lib/automation/dsk.sh) runs its ping / curl /
# iperf3 tests ON the dongle, exactly as it runs them inside PacketRusher.
# This is the hop that gets a command there, through the control host (see
# dongle_env.sh); the dongle's password comes from webui/dongle.env, so the
# caller never needs it.
#
# The command is passed base64-encoded so it crosses the caller and this
# shell untouched; only the dongle's shell parses it. stdout, stderr and the
# exit status are the command's own.
#
# Which dongle follows SSH_HOST / SSH_PORT, like every other dongle script.
#
# Usage:
#   dongle_exec.sh --b64 <base64 of the command line>
#   dongle_exec.sh <command> [args...]        # simple commands, for use by hand
# ============================================================================

set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${DONGLE_ENV_FILE:-$SCRIPT_DIR/dongle_env.sh}"
[[ -r "$ENV_FILE" ]] || { echo "Missing config file: $ENV_FILE" >&2; exit 2; }
# shellcheck source=/dev/null
source "$ENV_FILE"
command -v sshpass >/dev/null 2>&1 || { echo "sshpass is not installed on this host" >&2; exit 2; }

if [[ "${1:-}" == "--b64" ]]; then
    CMD=$(printf '%s' "${2:-}" | base64 -d 2>/dev/null) || { echo "Invalid base64 command" >&2; exit 2; }
else
    CMD="$*"
fi
# at_cmd started without a command spins forever on the dongle — never let an
# empty command through.
[[ -n "${CMD// /}" ]] || { echo "No command given" >&2; exit 2; }

# One multiplexed connection per dongle: a ping test is one call per ping, and
# a fresh handshake for each would cost more than the ping itself.
exec sshpass -e ssh \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o ConnectTimeout=5 \
    -o ControlMaster=auto -o ControlPersist=120 -o ControlPath="/tmp/dongle-exec-%r@%h-%p" \
    "${DONGLE_JUMP_OPTS[@]}" -p "$SSH_PORT" root@"$SSH_HOST" "$CMD"
