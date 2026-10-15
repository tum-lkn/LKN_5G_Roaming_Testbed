#!/bin/bash
# ============================================================================
# dongle_cp_setup.sh — control-plane half of the dongle measurement
# ============================================================================
# Cycles the dongle UE (-> re-registration) and measures how long the 5G
# control-plane setup takes, by capturing NGAP/SCTP on the VPLMN with tshark
# and parsing the resulting pcap.
#
# Two ways to cycle the UE (--mode):
#
#   reboot    (default) Reboots the whole dongle. Takes ~2 minutes: the modem
#             registers on its own at ~16s, the vendor connection manager then
#             takes it off the air for about a minute, and only after a SECOND
#             registration is the internet PDU session requested.
#   airplane  Switches the modem's radio off and on (AT+CFUN=4 / AT+CFUN=1).
#             The dongle's Linux side keeps running, so there is no boot to
#             wait for: ONE registration, PDU session back within ~1-3s.
#             Measured against reboot mode with and without a 50ms SEPP delay,
#             registration and PDU setup agree within a few percent.
#             dongle_cp_airplane.sh is this mode under its own name.
#
# Both modes deregister first, so the registration goes to the home network
# (UDM lookups over N32 in roaming). Neither guarantees authentication: the
# modem keeps its security context across an airplane toggle, and usually —
# not always — across a reboot.
#
# Split out of ping_pcap.sh, which is left untouched. The user-plane half
# (pinging + parsing) lives in dongle_ping.sh and is run separately.
#
# NOTHING IS WRITTEN TO A RESULTS FILE. Progress goes to stdout so the WebUI
# can stream it live, and the measurement is emitted as one final line:
#
#   RESULT_JSON {"ok":true,"ue_ip":"…","timing":{"total":…,
#                "registration_ms":…,"pdu_setup_ms":…}, …}
#
# The "timing" object deliberately uses the same keys the WebUI already
# renders for PacketRusher, so a dongle run shows up on the dashboard exactly
# like a PacketRusher run.
#
# PREREQUISITE: the gNB must already be up. This script only cycles the UE —
# it does not start the radio.
#
# Usage:
#   dongle_cp_setup.sh                  # full run (reboots the dongle)
#   dongle_cp_setup.sh --mode airplane  # full run, airplane toggle, no reboot
#   dongle_cp_setup.sh --parse-only F   # re-parse an existing pcap on the
#                                       # VPLMN, no reboot — for verification
# ============================================================================

set -u

# This host runs a German locale, where printf '%.0f' rejects a dot-decimal
# like 10304.87 and silently truncates. Everything here is machine-parsed, so
# pin the C locale for the whole script.
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${DONGLE_ENV_FILE:-$SCRIPT_DIR/dongle_env.sh}"

# Tunables (env-overridable)
RECONNECT_TIMEOUT="${RECONNECT_TIMEOUT:-300}"   # s to wait for the UE to come back
PREFLIGHT_TIMEOUT="${PREFLIGHT_TIMEOUT:-60}"    # s to wait for the UE before rebooting
POST_REBOOT_GRACE="${POST_REBOOT_GRACE:-10}"    # s to let the dongle actually go down
CAPTURE_SETTLE="${CAPTURE_SETTLE:-2}"           # s of trailing NGAP before stopping
KEEP_PCAP="${KEEP_PCAP:-1}"                     # 1 = leave the capture on the VPLMN
AIRPLANE_OFF_TIME="${AIRPLANE_OFF_TIME:-5}"     # s the radio stays off in airplane mode

MODE="${DONGLE_CP_MODE:-reboot}"
PARSE_ONLY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --parse-only) PARSE_ONLY="${2:-}"; shift 2 ;;
        --mode)       MODE="${2:-}"; shift 2 ;;
        -h|--help)    awk 'NR>1 && !/^#/{exit} NR>1' "$0"; exit 0 ;;   # the header comment
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
case "$MODE" in
    reboot|airplane) ;;
    *) echo "Invalid --mode: $MODE (reboot or airplane)" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# Output helpers — stdout is the WebUI's live log, so keep lines self-contained
# ---------------------------------------------------------------------------
log()  { printf '%s\n' "$*"; }
warn() { printf '⚠️  %s\n' "$*" >&2; }

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

emit_failure() {
    printf 'RESULT_JSON {"ok":false,"error":"%s"}\n' "$(json_escape "$1")"
}

fail() {
    printf '❌ %s\n' "$*" >&2
    emit_failure "$*"
    exit 1
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
[[ -r "$ENV_FILE" ]] || fail "Missing config file: $ENV_FILE"
# shellcheck source=/dev/null
source "$ENV_FILE"

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

dongle_ssh() { sshpass -e ssh "${DONGLE_SSH_OPTS[@]}" root@"$SSH_HOST" "$@"; }
# This script runs ON the VPLMN now, so the capture is local: no SSH and no
# stored VPLMN password. The names stay, so the code below reads as before.
vplmn_ssh()  { bash -c "$*"; }
# tshark needs root; sudo for bash is passwordless for this account here.
vplmn_sudo() { sudo -n bash -c "$*" 2>/dev/null; }

# ---------------------------------------------------------------------------
# Cleanup — we must not leave a root-owned tshark running on the VPLMN, neither
# when a WebUI "Stop" sends SIGINT to the process group nor when fail() exits
# (e.g. the dongle never comes back). Signals are turned into exits so the EXIT
# trap is the single place that stops the capture.
# ---------------------------------------------------------------------------
TSHARK_PID=""
cleanup() {
    local rc=$?
    if [[ -n "$TSHARK_PID" ]]; then
        log "🧹 Stopping tshark (PID $TSHARK_PID) on the VPLMN"
        vplmn_sudo "kill $TSHARK_PID 2>/dev/null || true" >/dev/null 2>&1 || true
        TSHARK_PID=""
    fi
    exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT HUP
trap 'exit 143' TERM

# ---------------------------------------------------------------------------
# pcap parsing
#
# What the dongle does after a reboot (seen in NGAP on the VPLMN): the modem
# registers on its own right away, but only brings up its default "ims"
# session, which this core rejects. About a minute later the vendor connection
# manager (xap_core) finishes booting, makes the modem start a SECOND initial
# registration, and only then requests the internet PDU session.
#
# The two registrations are not alike. The first one goes to the home network
# (several UDM round trips over N32 in roaming); the second is answered by the
# AMF straight from the context the first one left behind, with no N32 at all.
# Measuring the second one therefore reports a near-constant ~50 ms that no
# roaming delay can move. So:
#
#   registration  = FIRST registration that completed (Registration Request ->
#                   InitialContextSetupResponse, same procedure).
#   PDU setup     = the dongle's PDU Session Establishment Request ->
#                   PDUSessionResourceSetupResponse. It must start at the NAS
#                   request, not at PDUSessionResourceSetupRequest: everything
#                   the core does (SMF, N4, and vSMF<->hSMF over N32 in HR)
#                   happens between the two, so starting at the N2 request
#                   measures only the last radio leg.
#   total         = registration + PDU setup: the network's signalling time,
#                   comparable with PacketRusher, where the two follow each
#                   other within milliseconds. The dongle's own gap between
#                   them (vendor boot, re-registration) is reported separately.
# ---------------------------------------------------------------------------
# All matching timestamps, in capture (chronological) order.
ngap_times() {
    vplmn_ssh "tshark -r '$1' -Y '$2' -T fields -e frame.time_epoch 2>/dev/null" \
        | tr -d '\r' | grep -E '^[0-9]' || true
}

delta_ms() { printf '%.0f' "$(echo "scale=6; ($2 - $1) * 1000" | bc)"; }

first_at_or_after() { awk -v t="$1" '$1 >= t {print $1; exit}'; }
last_at_or_after()  { awk -v t="$1" '$1 >= t {v=$1} END{if(v!="") print v}'; }

parse_pcap() {
    local pcap="$1"

    local size
    size=$(vplmn_ssh "stat -c%s '$pcap' 2>/dev/null || echo 0" | tr -d '\r')
    [[ "${size:-0}" -ge 100 ]] || fail "Capture too small (${size:-0} bytes) — the capture likely never saw any NGAP traffic"
    log "📊 Parsing capture ($size bytes) for control-plane timing"

    # One attach produces SEVERAL NGAP procedures, each with its own UE context,
    # so every timestamp is located relative to the chosen registration rather
    # than taken independently (independent "last of each type" once paired a
    # registration with a context setup ten seconds later).
    local regs ics preqs presps ue_msgs ul_nas dl_nas
    regs=$(ngap_times    "$pcap" 'ngap.InitialUEMessage_element && nas_5gs.mm.message_type == 65')
    ics=$(ngap_times     "$pcap" 'ngap.InitialContextSetupResponse_element')
    preqs=$(ngap_times   "$pcap" 'ngap.PDUSessionResourceSetupRequest_element')
    presps=$(ngap_times  "$pcap" 'ngap.PDUSessionResourceSetupResponse_element')
    ue_msgs=$(ngap_times "$pcap" 'ngap.InitialUEMessage_element')
    ul_nas=$(ngap_times  "$pcap" 'ngap.UplinkNASTransport_element')
    dl_nas=$(ngap_times  "$pcap" 'ngap.DownlinkNASTransport_element')

    REG_ATTEMPTS=$(printf '%s\n' "$regs" | grep -c . || true)
    [[ "${REG_ATTEMPTS:-0}" -gt 0 ]] || fail "No NGAP Registration Request in the capture"

    # First registration that COMPLETED: its InitialContextSetupResponse
    # arrives before the next procedure starts (a new InitialUEMessage). An
    # attempt dropped mid-way never gets one and is skipped.
    local reg="" ctx_resp="" candidate ics_after next_ue
    for candidate in $regs; do
        ics_after=$(printf '%s\n' "$ics" | first_at_or_after "$candidate")
        [[ -n "$ics_after" ]] || continue
        next_ue=$(printf '%s\n' "$ue_msgs" | awk -v t="$candidate" '$1 > t {print $1; exit}')
        if [[ -z "$next_ue" ]] || awk -v a="$ics_after" -v b="$next_ue" 'BEGIN{exit !(a < b)}'; then
            reg="$candidate"; ctx_resp="$ics_after"
            break
        fi
    done
    [[ -n "$reg" ]] || fail "No registration in the capture completed (no InitialContextSetupResponse before the next attempt)"

    # The internet PDU session: the last N2 setup in the capture after it.
    local pdu_n2_req pdu_resp pdu_req
    pdu_n2_req=$(printf '%s\n' "$preqs" | last_at_or_after "$reg")
    [[ -n "$pdu_n2_req" ]] || fail "No PDUSessionResourceSetupRequest after the registration request"
    pdu_resp=$(printf '%s\n' "$presps" | first_at_or_after "$pdu_n2_req")
    [[ -n "$pdu_resp" ]] || fail "No PDUSessionResourceSetupResponse after the PDU session request"

    # The dongle's PDU Session Establishment Request. NAS is ciphered, so the
    # message type cannot be read; it is identified by behaviour instead: the
    # last UplinkNASTransport before the N2 setup that the AMF did not answer
    # on its own. Its answer (the accept) rides inside the N2 setup request,
    # whereas anything the AMF answers locally — like the dongle's rejected
    # "ims" requests every 16s — gets a DownlinkNASTransport first.
    pdu_req=$(printf '%s\n' "$ul_nas" | awk -v a="$reg" -v b="$pdu_n2_req" '$1 > a && $1 < b' | tac |
        while read -r u; do
            if ! printf '%s\n' "$dl_nas" | awk -v u="$u" -v b="$pdu_n2_req" '$1 > u && $1 < b {f=1} END{exit !f}'; then
                echo "$u"; break
            fi
        done)
    [[ -n "$pdu_req" ]] || fail "Could not find the PDU Session Establishment Request before the PDU session setup"

    REG_MS=$(delta_ms "$reg" "$ctx_resp")        # RegReq → ICS Response, same procedure
    PDU_MS=$(delta_ms "$pdu_req" "$pdu_resp")    # PDU request → N2 setup response
    SIGNALLING_MS=$((REG_MS + PDU_MS))
    TOTAL_MS=$SIGNALLING_MS                      # network time, see header
    # Wall clock from the measured registration to the session being up, and
    # the part of it the network was not working (dongle-side gaps).
    REG_OK_TO_PDU_MS=$(delta_ms "$reg" "$pdu_resp")
    IDLE_MS=$((REG_OK_TO_PDU_MS - SIGNALLING_MS))

    log "✅ Registration        : ${REG_MS} ms  (first completed registration)"
    log "✅ PDU session setup   : ${PDU_MS} ms  (PDU request → session set up)"
    log "✅ Total (registration + PDU session setup) : ${TOTAL_MS} ms"
    log "ℹ️  Wall clock, registration → PDU session up: ${REG_OK_TO_PDU_MS} ms, of which ${IDLE_MS} ms on the dongle's side"
    [[ "${REG_ATTEMPTS:-1}" -gt 1 ]] && log "ℹ️  ${REG_ATTEMPTS} registration requests seen (the dongle's connection manager re-registers before its data session); measured the first completed one"
    return 0
}

# Best effort: NAS is ciphered, so the PDU address cannot be read from the
# pcap — ask the dongle itself instead.
#
# Primary source is `ip route get <target>`, which reports the source address
# actually used to reach the ping target (10.45.0.5 on rmnet_data0 here) —
# i.e. the PDU session address, the dongle's equivalent of PacketRusher's UE
# IP. The addr-show fallback skips the dongle's own LAN (192.168.44.0/24) and
# the USB/rndis link (203.0.113.0/24), but depends on interface ordering, so
# it is only used if route lookup gives nothing.
get_ue_ip() {
    local ip
    ip=$(dongle_ssh "ip -4 route get $PING_TARGET 2>/dev/null" 2>/dev/null \
        | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1 | tr -d '\r')
    if [[ -z "$ip" ]]; then
        ip=$(dongle_ssh "ip -4 -o addr show 2>/dev/null" 2>/dev/null \
            | awk '{print $4}' | cut -d/ -f1 \
            | grep -vE '^(127\.|192\.168\.44\.|203\.0\.113\.)' | head -1 | tr -d '\r')
    fi
    printf '%s' "$ip"
}

wait_for_dongle() {
    local timeout="$1" label="$2" start now elapsed last_report=0
    start=$(date +%s)
    while true; do
        # ICMP first, SSH only if that answers. While the dongle is rebooting,
        # SSH handshakes landing on the RNDIS link are what provoke its
        # IPA/tethering stack to reset the USB gadget, and each reset extends
        # the very outage this loop is waiting on. Measured on this bench, one
        # reboot: 4 gadget resets and ~104s to a stable link with no contact,
        # 9 resets and ~152s under ICMP polling, 11 resets and ~227s under SSH
        # polling. ICMP is answered by the modem's kernel and costs it almost
        # nothing, so it decides when an SSH attempt is worth making at all.
        if dongle_icmp 2 \
           && dongle_ssh "ping -c 1 -W 1 $PING_TARGET" >/dev/null 2>&1; then
            now=$(date +%s)
            WAITED=$((now - start))
            return 0
        fi
        now=$(date +%s); elapsed=$((now - start))
        if (( elapsed >= timeout )); then
            WAITED=$elapsed
            return 1
        fi
        if (( elapsed - last_report >= 15 )); then
            last_report=$elapsed
            log "⏳ $label — still waiting (${elapsed}s / ${timeout}s)"
        fi
        # 5s rather than 1s: the cadence is what decides how much traffic hits
        # the link during the reboot. The cost is a few seconds of detection
        # latency on a wait that runs for minutes.
        sleep "$WAIT_INTERVAL"
    done
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
for tool in sshpass bc; do
    command -v "$tool" >/dev/null 2>&1 || fail "'$tool' is required on this host but is not installed"
done
# What the dongle pings to prove it is up: REMOTE_TARGET, or the fallback when
# that is down (see resolve_ping_target in dongle_env.sh).
PING_TARGET=$(resolve_ping_target)
[[ "$PING_TARGET" != "$REMOTE_TARGET" ]] && log "⚠️  $REMOTE_TARGET does not answer from this host — using $PING_TARGET instead"

WAITED=0
WAIT_INTERVAL=5      # s between "is it back" probes; 1 in airplane mode (see below)

# --parse-only: verify the parsing half against an existing capture, no reboot
if [[ -n "$PARSE_ONLY" ]]; then
    log "🔍 Parse-only mode — reusing $PARSE_ONLY, the dongle is not touched"
    parse_pcap "$PARSE_ONLY"
    printf 'RESULT_JSON {"ok":true,"ue_ip":null,"timing":{"total":%s,"registration_ms":%s,"pdu_setup_ms":%s},"reg_success_to_pdu_ms":%s,"signalling_ms":%s,"idle_ms":%s,"registration_attempts":%s,"pcap":"%s","reconnect_wait_s":0,"parse_only":true}\n' \
        "$TOTAL_MS" "$REG_MS" "$PDU_MS" "$REG_OK_TO_PDU_MS" "$SIGNALLING_MS" "$IDLE_MS" "${REG_ATTEMPTS:-1}" "$(json_escape "$PARSE_ONLY")"
    exit 0
fi

log "🔍 Checking the VPLMN ($VPLMN_HOST) is reachable and has tshark"
vplmn_ssh "command -v tshark >/dev/null 2>&1" \
    || fail "Cannot reach the VPLMN at $VPLMN_HOST, or tshark is not installed there"
log "✅ VPLMN reachable, tshark available"

log "🔍 Checking the dongle is up before cycling it (gNB must already be running)"
if ! wait_for_dongle "$PREFLIGHT_TIMEOUT" "Waiting for the dongle"; then
    fail "Dongle did not answer within ${PREFLIGHT_TIMEOUT}s — is the gNB up and the dongle attached?"
fi
log "✅ Dongle is up and can reach $PING_TARGET"

# ---------------------------------------------------------------------------
# Capture, cycle, measure
# ---------------------------------------------------------------------------
PCAP_FILE="/tmp/dongle_cp_$(date +%Y%m%d_%H%M%S)_$$.pcap"
ERR_LOG="${PCAP_FILE%.pcap}.tsharkerr"

# /tmp on purpose: root can always write there regardless of NFS root_squash.
# Filter on the gNB IP alone — the AMF container answers from its Docker IP,
# not from AMF_IP, so an AND filter would miss the AMF→gNB direction.
log "🎬 Starting tshark on the VPLMN -> $PCAP_FILE"
TSHARK_PID=$(vplmn_sudo "bash -c 'nohup tshark -i ${CAPTURE_IFACE} -n -s 0 -w ${PCAP_FILE} -f \"host ${GNB_IP} and not port 22\" </dev/null >${ERR_LOG} 2>&1 & echo \$!'" | grep -E '^[0-9]+$' | tail -1)
sleep 2
[[ -n "$TSHARK_PID" ]] || fail "tshark did not start on the VPLMN: $(vplmn_ssh "cat '$ERR_LOG' 2>/dev/null" | tr '\n' ' ')"
vplmn_sudo "kill -0 $TSHARK_PID" >/dev/null 2>&1 \
    || fail "tshark exited immediately on the VPLMN: $(vplmn_ssh "cat '$ERR_LOG' 2>/dev/null" | tr '\n' ' ')"
log "✅ tshark running on the VPLMN (PID $TSHARK_PID)"

if [[ "$MODE" == "airplane" ]]; then
    # Radio off and on. at_cmd must always be given a command — started bare
    # it spins forever on the dongle.
    log "✈️  Airplane mode on (radio off) to deregister the UE"
    dongle_ssh "at_cmd 'AT+CFUN=4' -t 5" >/dev/null 2>&1 \
        || fail "Could not send the airplane-mode command to the dongle"
    sleep "$AIRPLANE_OFF_TIME"
    # The PDU session address disappears with the radio; if it is still there
    # the command did not take, and the run would measure nothing.
    if [[ -n "$(dongle_ssh "ip -4 -o addr show 2>/dev/null" 2>/dev/null | awk '$2 ~ /rmnet_data/ {print $4}' | head -1)" ]]; then
        dongle_ssh "at_cmd 'AT+CFUN=1' -t 5" >/dev/null 2>&1 || true
        fail "Airplane mode did not take effect on the dongle (its PDU session stayed up)"
    fi
    log "✈️  Airplane mode off (radio on) — the UE registers again"
    dongle_ssh "at_cmd 'AT+CFUN=1' -t 5" >/dev/null 2>&1 \
        || fail "Could not switch the dongle's radio back on — run: at_cmd 'AT+CFUN=1' -t 5 on the dongle"
    # The dongle's Linux side never went down, so there are no USB gadget
    # resets to avoid: poll every second instead of every five.
    WAIT_INTERVAL=1
    log "⏳ Waiting for the dongle to re-register (up to ${RECONNECT_TIMEOUT}s) — normally a few seconds"
else
    # SSH returns non-zero because the connection is torn down mid-reboot — expected.
    log "🔄 Rebooting the dongle to force a fresh registration"
    dongle_ssh "reboot" >/dev/null 2>&1 || true
    sleep "$POST_REBOOT_GRACE"
    log "⏳ Waiting for the dongle to re-register (up to ${RECONNECT_TIMEOUT}s) — this normally takes a while"
fi
if ! wait_for_dongle "$RECONNECT_TIMEOUT" "Reconnecting"; then
    # Never leave the radio off behind a failed airplane run.
    [[ "$MODE" == "airplane" ]] && dongle_ssh "at_cmd 'AT+CFUN=1' -t 5" >/dev/null 2>&1
    fail "Dongle did not come back within ${RECONNECT_TIMEOUT}s"
fi
RECONNECT_WAIT=$WAITED
log "✅ Dongle reconnected after ${RECONNECT_WAIT}s"

sleep "$CAPTURE_SETTLE"
log "🛑 Stopping the capture"
vplmn_sudo "kill $TSHARK_PID 2>/dev/null || true" >/dev/null 2>&1 || true
TSHARK_PID=""
sleep 1
# root's umask may be 077 — make the pcap readable for the parsing pass.
vplmn_sudo "chmod a+r '$PCAP_FILE' 2>/dev/null || true" >/dev/null 2>&1 || true

parse_pcap "$PCAP_FILE"

UE_IP=$(get_ue_ip)
if [[ -n "$UE_IP" ]]; then
    log "📶 UE address: $UE_IP"
    UE_IP_JSON="\"$(json_escape "$UE_IP")\""
else
    warn "Could not read the UE address from the dongle (NAS is ciphered, so it is not in the pcap either)"
    UE_IP_JSON="null"
fi

if [[ "$KEEP_PCAP" != "1" ]]; then
    vplmn_sudo "rm -f '$PCAP_FILE' '$ERR_LOG'" >/dev/null 2>&1 || true
    PCAP_REPORT=""
else
    log "💾 Capture kept on the VPLMN at $PCAP_FILE"
    PCAP_REPORT="$PCAP_FILE"
fi

printf 'RESULT_JSON {"ok":true,"ue_ip":%s,"timing":{"total":%s,"registration_ms":%s,"pdu_setup_ms":%s},"reg_success_to_pdu_ms":%s,"signalling_ms":%s,"idle_ms":%s,"registration_attempts":%s,"pcap":"%s","reconnect_wait_s":%s,"method":"%s"}\n' \
    "$UE_IP_JSON" "$TOTAL_MS" "$REG_MS" "$PDU_MS" "$REG_OK_TO_PDU_MS" "$SIGNALLING_MS" "$IDLE_MS" "${REG_ATTEMPTS:-1}" "$(json_escape "$PCAP_REPORT")" "$RECONNECT_WAIT" "$MODE"
