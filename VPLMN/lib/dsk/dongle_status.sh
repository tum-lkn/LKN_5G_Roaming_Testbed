#!/bin/bash
# ============================================================================
# dongle_status.sh — is the dongle UE attached right now?
# ============================================================================
# Cheap liveness probe for the WebUI dashboard, meant to be polled: no reboot,
# no pings, just one SSH to the dongle asking which source address it would
# use to reach the test target.
#
# That address is the PDU session address handed out by the core — it only
# exists while the UE is attached — so a single question answers both "is the
# dongle up?" and "what is its current IP?". (The IP is not stable: it
# alternates across the /30 on every re-registration, so it must be read
# fresh rather than remembered.)
#
# Prints exactly one line and nothing else:
#   RESULT_JSON {"ok":true,"attached":true,"ue_ip":"10.45.0.6"}
#   RESULT_JSON {"ok":true,"attached":false,"ue_ip":null}
#
# "ok" reports whether the probe itself ran; "attached" is the answer.
# ============================================================================

set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${DONGLE_ENV_FILE:-$SCRIPT_DIR/dongle_env.sh}"

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

if [[ ! -r "$ENV_FILE" ]]; then
    printf 'RESULT_JSON {"ok":false,"attached":false,"ue_ip":null,"error":"%s"}\n' \
        "$(json_escape "Missing config file: $ENV_FILE")"
    exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

if ! command -v sshpass >/dev/null 2>&1; then
    printf 'RESULT_JSON {"ok":false,"attached":false,"ue_ip":null,"error":"sshpass is not installed"}\n'
    exit 1
fi

# Move every dongle on the control host to USB 2 as soon as it shows up: at USB 3
# its data path stalls for good under the page-load test (see dongle_usb.sh).
# This probe is what the dashboard polls, so a freshly plugged dongle is
# switched within seconds, before any test can run, and every test measures
# over the same link. Costs a few sysfs reads when nothing needs switching.
# A switched dongle drops off USB for a few seconds while it re-attaches, so
# report it as away; the next poll sees it back.
# shellcheck source=/dev/null
# Runs on the control host, where the USB port is (dongle_env.sh: ctrl_force_usb2).
if ctrl_force_usb2 >/dev/null; then
    printf 'RESULT_JSON {"ok":true,"attached":false,"ue_ip":null,"iface":"","reachable":false,"usb":"switched to USB 2"}\n'
    exit 0
fi

# ICMP gate before the expensive part. This probe is polled continuously by the
# dashboard, and while the dongle is away — rebooting, or unplugged — every SSH
# handshake landing on its RNDIS link provokes the modem's IPA/tethering stack
# to reset the USB gadget, which lengthens the very outage being waited on.
# Measured on this bench across one reboot: 4 gadget resets and ~104s to a
# stable link with no contact, 9 resets and ~152s under ICMP polling, 11 resets
# and ~227s under SSH polling. ICMP is answered by the modem's kernel and costs
# it almost nothing, so it decides whether SSH is worth attempting at all.
#
# "reachable" distinguishes the two "not attached" cases for the caller: the
# dongle is absent from the link entirely, versus present but not registered.
if ! dongle_icmp "${PROBE_TIMEOUT:-2}"; then
    printf 'RESULT_JSON {"ok":true,"attached":false,"ue_ip":null,"iface":"","reachable":false}\n'
    exit 0
fi

# Short timeout: this is polled continuously by the dashboard, so an unplugged
# dongle must fail fast rather than stall the UI. The dongle sits on a local
# link (192.168.44.0/24) one hop away, so 2s is generous for a live one.
ROUTE=$(sshpass -e ssh \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR \
            -o ConnectTimeout="${PROBE_TIMEOUT:-2}" \
            -o BatchMode=no \
            "${DONGLE_JUMP_OPTS[@]}" -p "$SSH_PORT" root@"$SSH_HOST" \
            "ip -4 route get $REMOTE_TARGET 2>/dev/null" 2>/dev/null | tr -d '\r')

# The dongle has three addressed interfaces: rmnet_data0 (the 5G bearer),
# bridge0 (192.168.44.0/24, how we reach it) and rndis0 (203.0.113.0/24, USB).
# Only a route leaving through the modem means the PDU session is up — while
# the dongle is booting, a route via one of the others would otherwise be
# mistaken for an attached UE and make the dashboard flap.
UE_IFACE_PATTERN="${UE_IFACE_PATTERN:-rmnet_data}"
DEV=$(printf '%s' "$ROUTE" | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)
UE_IP=$(printf '%s' "$ROUTE" | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1)

if [[ -n "$UE_IP" && "$DEV" == *"$UE_IFACE_PATTERN"* ]]; then
    printf 'RESULT_JSON {"ok":true,"attached":true,"ue_ip":"%s","iface":"%s"}\n' \
        "$(json_escape "$UE_IP")" "$(json_escape "$DEV")"
else
    printf 'RESULT_JSON {"ok":true,"attached":false,"ue_ip":null,"iface":"%s"}\n' \
        "$(json_escape "$DEV")"
fi
