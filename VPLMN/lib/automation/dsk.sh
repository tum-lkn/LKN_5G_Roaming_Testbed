#!/usr/bin/env bash
# lib/automation/dsk.sh — the commercial RAN (DSK gNB + USB dongle) as the UE
#
# Sourced by testbed_automation.sh. Active when the config sets UE_TYPE=dsk;
# with UE_TYPE=packetrusher (the default) nothing here runs.
#
# The automation was written around PacketRusher: per iteration it starts a
# fresh PacketRusher container, reads the registration / PDU timings from its
# log, runs ping / curl / iperf3 / Browsertime through its VRF, and removes it.
# This file gives the same steps for a real dongle behind a real gNB:
#
#   PacketRusher                          DSK
#   ------------------------------------  ------------------------------------
#   start container, timings from log     dongle_cp_setup.sh (lib/dsk, on
#                                         this host): airplane toggle or
#                                         reboot, timings from the NGAP capture
#   ping / curl / iperf3 in its VRF       the SAME commands, run on the dongle
#                                         (ue_exec) — the test functions in
#                                         tests.sh are shared
#   Browsertime in its network namespace  dongle_webpage.sh, shipped to the
#                                         control host for the run
#   video test                            not available (skipped)
#   stop container                        nothing: the next iteration cycles
#                                         the UE again
#
# What a real RAN adds: the gNB does not reconnect on its own when the AMF
# restarts, and it can crash. So after every core (re)start the gNB is
# restarted and the dongle is waited for (dsk_bring_up_ran), and before every
# iteration the RAN is checked and recovered if needed (dsk_ensure_ran_ready).
# Within a run the dongle is never restarted — only waited for.
#
# The O-RU's timing drifts after some hours (2026-10-08 and -09): the uplink
# degrades, then the dongle cannot attach at all, and stays stuck even after
# the RU is fixed. After every iteration the run is checked for that
# (dsk_iteration_degraded); a degraded run stops and exits
# DSK_EXIT_RAN_DEGRADED, and batch_runner.sh discards it and the runs before
# it, then has testbed_automation.sh --recover-ran reboot the RU, wait, restart
# the gNB and reboot the dongle (dsk_recover_ran) before measuring them again.
# That reboot is recovery only, never a way to take a measurement.
#
# The dongle's registration is NOT comparable one-to-one with PacketRusher's:
# it re-registers the same subscriber with its stored 5G-GUTI and keys, so it
# carries no authentication. See docs/COMMERCIAL_RAN.md.
#
# Host settings (control host, gNB host) come from webui/dongle.env, the file
# lib/features/set-dongle-mode.sh writes — the same one the WebUI uses.

UE_TYPE="${UE_TYPE:-packetrusher}"        # packetrusher | dsk
DSK_DONGLE="${DSK_DONGLE:-a}"             # which dongle: a | b
DSK_CYCLE="${DSK_CYCLE:-airplane}"        # how an iteration re-registers the UE: airplane | reboot
DSK_DONGLE_HOST="${DSK_DONGLE_HOST:-}"    # override the dongle's address (default from DSK_DONGLE)
DSK_DONGLE_PORT="${DSK_DONGLE_PORT:-8822}"
# dongle_*.sh, run on this host; they reach the dongle through the control host.
DSK_SCRIPT_DIR="${DSK_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../dsk" && pwd)}"
DSK_GNB_READY_TIMEOUT="${DSK_GNB_READY_TIMEOUT:-240}"   # s for the gNB to reach the AMF after a restart
DSK_ATTACH_TIMEOUT="${DSK_ATTACH_TIMEOUT:-300}"         # s for the dongle to attach after the gNB is up
DSK_GNB_STABLE_WAIT="${DSK_GNB_STABLE_WAIT:-30}"        # s the gNB must stay up after connecting to the AMF
DSK_RU_MIN_ON_TIME_PCT="${DSK_RU_MIN_ON_TIME_PCT:-90}"  # % of U-plane packets the RU must get on time meanwhile
DSK_RU_COUNTER_WAIT="${DSK_RU_COUNTER_WAIT:-120}"      # s at most to wait for the RU's pm-data counters to move
DSK_RECOVERY_ATTEMPTS="${DSK_RECOVERY_ATTEMPTS:-3}"     # RU reboot → gNB → dongle attempts per RAN recovery
DSK_AMF_CONTAINER="${DSK_AMF_CONTAINER:-open5gs-amf}"

# Exit status of testbed_automation.sh when the SIM in the dongle does not fit
# the config's roaming mode. batch_runner.sh stops on it instead of failing
# every remaining config one by one.
DSK_EXIT_WRONG_SIM=42

# Exit status when the run was stopped because the RAN degraded (an iteration
# failed, or showed the uplink symptoms below). batch_runner.sh recovers the
# RAN on it and measures the run again.
DSK_EXIT_RAN_DEGRADED=43

# An iteration counts as degraded when BOTH its setup time and its iperf
# (uplink) loss are above these. Healthy runs: setup ≤ 271 ms, and loss
# spikes up to 93% with normal setup; RU-drift iterations: setup 304-1178 ms
# with 84-96% loss (all DSK data up to 2026-10-10).
DSK_DEGRADED_SETUP_MS="${DSK_DEGRADED_SETUP_MS:-300}"
DSK_DEGRADED_LOSS_PCT="${DSK_DEGRADED_LOSS_PCT:-50}"
DSK_RU_COOLDOWN="${DSK_RU_COOLDOWN:-600}"         # s to leave the RU alone after its reboot
DSK_RU_READY_TIMEOUT="${DSK_RU_READY_TIMEOUT:-300}"  # s more for its CLI to report RF Ready
DSK_DONGLE_BOOT_TIME="${DSK_DONGLE_BOOT_TIME:-150}"  # s a rebooting dongle needs before AT commands make sense

is_dsk() { [ "${UE_TYPE:-packetrusher}" = "dsk" ]; }

# ── Settings ────────────────────────────────────────────────────────────────

_dsk_env() {   # value of KEY in webui/dongle.env, or empty
    local f="$SCRIPT_DIR/webui/dongle.env"
    [ -r "$f" ] || return 0
    sed -n "s/^$1=//p" "$f" | tail -1
}

# Same flag the WebUI uses (DONGLE_ENABLED, set by lib/features/set-dongle-mode.sh)
dsk_enabled() {
    case "$(_dsk_env DONGLE_ENABLED | tr -d '"' | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

dsk_load_settings() {
    # Off = this testbed has no commercial RAN: stop before anything touches
    # the gNB, the RU or the control host.
    dsk_enabled || error_exit "UE_TYPE=dsk but commercial RAN support is disabled (DONGLE_ENABLED in webui/dongle.env). Enable it with lib/features/set-dongle-mode.sh on."
    DSK_RU_HOST="${DSK_RU_HOST:-$(_dsk_env RU_HOST)}"
    DSK_RU_USER="${DSK_RU_USER:-$(_dsk_env RU_USER)}"
    DSK_CTRL_HOST="${DSK_CTRL_HOST:-$(_dsk_env DONGLE_HOST)}"
    DSK_CTRL_USER="${DSK_CTRL_USER:-$(_dsk_env DONGLE_USER)}"
    DSK_CTRL_PORT="${DSK_CTRL_PORT:-$(_dsk_env DONGLE_PORT)}"; DSK_CTRL_PORT="${DSK_CTRL_PORT:-22}"
    DSK_GNB_HOST="${DSK_GNB_HOST:-$(_dsk_env GNB_HOST)}"
    DSK_GNB_USER="${DSK_GNB_USER:-$(_dsk_env GNB_USER)}"
    DSK_GNB_PORT="${DSK_GNB_PORT:-$(_dsk_env GNB_PORT)}"; DSK_GNB_PORT="${DSK_GNB_PORT:-22}"
    DSK_GNB_CONTAINER="${DSK_GNB_CONTAINER:-$(_dsk_env GNB_CONTAINER)}"
    DSK_GNB_COMPOSE_FILE="${DSK_GNB_COMPOSE_FILE:-$(_dsk_env GNB_COMPOSE_FILE)}"
    if [ -z "$DSK_DONGLE_HOST" ]; then
        # Same two dongles the WebUI knows (webui/backend/app.py, "dongles").
        case "$DSK_DONGLE" in
            a|A) DSK_DONGLE_HOST="192.168.44.1" ;;
            b|B) DSK_DONGLE_HOST="192.168.43.1" ;;
            *)   error_exit "DSK_DONGLE must be a or b (got '$DSK_DONGLE'), or set DSK_DONGLE_HOST" ;;
        esac
    fi
    case "$DSK_CYCLE" in airplane|reboot) ;; *) error_exit "DSK_CYCLE must be airplane or reboot (got '$DSK_CYCLE')" ;; esac
    local missing=""
    for v in DSK_CTRL_HOST DSK_CTRL_USER DSK_GNB_HOST DSK_GNB_USER DSK_GNB_COMPOSE_FILE DSK_GNB_CONTAINER; do
        [ -n "${!v}" ] || missing+=" $v"
    done
    [ -z "$missing" ] || error_exit "UE_TYPE=dsk but the commercial-RAN hosts are not configured (missing:$missing). Run lib/features/set-dongle-mode.sh on."
}

# DSK results are kept apart from PacketRusher's: the WebUI plots read results/
# and the two UE types are not to be mixed in one chart.
dsk_apply_results_dir() {
    [ "$RESULTS_DIR" = "$SCRIPT_DIR/results" ] && RESULTS_DIR="$SCRIPT_DIR/results_dsk"
    mkdir -p "$RESULTS_DIR"
    BATCH_RESULTS_FILE="$RESULTS_DIR/$(basename "$BATCH_RESULTS_FILE")"
}

# ── SSH to the two RAN hosts ────────────────────────────────────────────────
# One multiplexed connection per host: a test issues many short commands
# (every single ping is one), and a fresh handshake for each would dominate.
_dsk_ssh() {   # _dsk_ssh <user> <host> <port> <command>
    ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
        -o ControlMaster=auto -o ControlPersist=300 -o ControlPath="/tmp/dsk-auto-%r@%h-%p" \
        -o ServerAliveInterval=15 -p "$3" "$1@$2" "$4"
}
dsk_ctrl() { _dsk_ssh "$DSK_CTRL_USER" "$DSK_CTRL_HOST" "$DSK_CTRL_PORT" "$1"; }
dsk_gnb()  { _dsk_ssh "$DSK_GNB_USER"  "$DSK_GNB_HOST"  "$DSK_GNB_PORT"  "$1"; }

# Run one of the dongle_*.sh scripts (lib/dsk, on this host) against our
# dongle. The arguments are one shell-quoted string, as before when they were
# parsed by the control host's shell. The control host is passed on, so a
# DSK_CTRL_* override reaches the scripts' jump host too.
dsk_script() {   # dsk_script <script> [args as one string]
    bash -c "cd $(printf '%q' "$DSK_SCRIPT_DIR") && \
        CTRL_HOST=$(printf '%q' "$DSK_CTRL_HOST") CTRL_USER=$(printf '%q' "$DSK_CTRL_USER") CTRL_PORT=$(printf '%q' "$DSK_CTRL_PORT") \
        SSH_HOST=$(printf '%q' "$DSK_DONGLE_HOST") SSH_PORT=$(printf '%q' "$DSK_DONGLE_PORT") bash ./$1 ${2:-}"
}

# Run a command ON the dongle. Arguments are single-quoted for the dongle's
# shell and travel base64-encoded, so nothing in between re-parses them.
dsk_dongle_exec() {
    local cmd="" a
    for a in "$@"; do cmd+="'$(printf '%s' "$a" | sed "s/'/'\\\\''/g")' "; done
    dsk_script dongle_exec.sh "--b64 $(printf '%s' "$cmd" | base64 -w0)"
}

# Where a UE-side test command runs. The test functions in tests.sh call this
# instead of addressing PacketRusher directly.
ue_exec() {   # ue_exec <vrf> <command> [args...]
    local vrf="$1"; shift
    if is_dsk; then
        dsk_dongle_exec "$@"
    else
        sudo docker exec "$PR_CONTAINER" ip vrf exec "$vrf" "$@"
    fi
}

# Bring the UE up for one iteration and take its control-plane timings.
ue_start_with_timing() {
    if is_dsk; then dsk_start_ue_with_timing "$1"; else start_packetrusher_with_timing "$1"; fi
}

# ── Preflight ───────────────────────────────────────────────────────────────

dsk_preflight() {
    log "   Checking the commercial RAN (UE_TYPE=dsk)..."
    dsk_ctrl "true" 2>/dev/null \
        || error_exit "Cannot SSH to the dongle control host $DSK_CTRL_USER@$DSK_CTRL_HOST"
    local s
    for s in dongle_env.sh dongle_cp_setup.sh dongle_exec.sh dongle_status.sh dongle_webpage.sh dongle_usb.sh; do
        [ -f "$DSK_SCRIPT_DIR/$s" ] || error_exit "$s is missing in $DSK_SCRIPT_DIR"
    done
    for s in sshpass tshark bc; do
        command -v "$s" >/dev/null 2>&1 || error_exit "'$s' is needed by the dongle scripts but not installed (sudo apt-get install $s)"
    done
    [ -n "$(_dsk_env DONGLE_SSH_PASS)" ] \
        || error_exit "DONGLE_SSH_PASS (the dongles' root password) is not set in webui/dongle.env — run lib/features/set-dongle-mode.sh on"
    sudo -n bash -c 'tshark -v' >/dev/null 2>&1 \
        || error_exit "The NGAP capture needs passwordless 'sudo bash' on this host (tshark runs as root)"
    dsk_gnb "test -f '$DSK_GNB_COMPOSE_FILE'" 2>/dev/null \
        || error_exit "Cannot SSH to the gNB host $DSK_GNB_USER@$DSK_GNB_HOST, or $DSK_GNB_COMPOSE_FILE is missing there"
    log "   ✅ Control host, dongle scripts and gNB host OK (dongle $DSK_DONGLE @ $DSK_DONGLE_HOST, cycle: $DSK_CYCLE)"
    dsk_check_sim
}

# The roaming mode is decided by the SUBSCRIBER, and a dongle has one SIM. So
# the SIM in the dongle must be the one the config's mode needs; the ranges
# are the ones the two cores seed (docker/mongodb-docker/start_services.sh).
dsk_check_sim() {
    local imsi="" want lo hi try
    # The AT channel is shared with the dongle's own connection manager and
    # occasionally answers nothing — ask a few times before giving up.
    for try in 1 2 3 4 5; do
        imsi=$(dsk_dongle_exec at_cmd AT+CIMI -t 3 2>/dev/null | tr -d '\r' | grep -E '^[0-9]{15}$' | head -1) || true
        [ -n "$imsi" ] && break
        sleep 2
    done
    [ -n "$imsi" ] || error_exit "Could not read the IMSI from dongle $DSK_DONGLE ($DSK_DONGLE_HOST) — is it plugged in and reachable from the control host?"
    case "$ROAMING_MODE" in
        hr|hr-remote-upf) want="Home-Routed";  lo=001010000001001; hi=001010000001101 ;;
        lbo)              want="LBO";          lo=001010000000001; hi=001010000000101 ;;
        non-roaming)      want="non-roaming";  lo=999710000000001; hi=999710000000101 ;;
        *) log "   ⚠️  Unknown roaming mode '$ROAMING_MODE' — not checking the SIM"; return 0 ;;
    esac
    if [ "$((10#$imsi))" -ge "$((10#$lo))" ] && [ "$((10#$imsi))" -le "$((10#$hi))" ]; then
        log "   ✅ SIM in dongle $DSK_DONGLE: IMSI $imsi — a $want subscriber, as this config needs"
        return 0
    fi
    log "❌ Wrong SIM for this config."
    log "   The dongle's SIM has IMSI $imsi, but mode '$ROAMING_MODE' needs a $want subscriber"
    log "   (IMSI $lo – $hi). Insert that SIM, wait for the dongle to come back, and run again."
    exit "$DSK_EXIT_WRONG_SIM"
}

# ── gNB and dongle state ────────────────────────────────────────────────────

dsk_gnb_running() {
    [ "$(dsk_gnb "docker inspect -f '{{.State.Running}}' '$DSK_GNB_CONTAINER' 2>/dev/null" 2>/dev/null)" = "true" ]
}

# Is a gNB associated with the AMF right now? The AMF logs the count on every
# change, so the last such line is the current state. With a timestamp, only
# lines logged since then count — after restarting the gNB, the "1" from
# before the restart must not be mistaken for the reconnect.
dsk_amf_has_gnb() {   # dsk_amf_has_gnb [since: docker --since timestamp]
    local n
    n=$(sudo docker logs ${1:+--since "$1"} "$DSK_AMF_CONTAINER" 2>&1 | grep -oE "Number of gNBs is now [0-9]+" | tail -1 | grep -oE "[0-9]+$") || true
    [ "${n:-0}" -ge 1 ]
}

# Has the AMF set up a PDU session since <timestamp>? This is the core's own
# evidence that a UE registered on THIS AMF instance — the dongle's view is
# not enough: after a core restart it keeps its old session address until it
# notices the network behind it changed.
dsk_amf_session_since() {
    sudo docker logs --since "$1" "$DSK_AMF_CONTAINER" 2>&1 | grep -qE "\[Added\] Number of AMF-Sessions is now [1-9]"
}

# Radio off and on (airplane mode) — makes the dongle register afresh without
# restarting it. at_cmd must always be given a command.
dsk_airplane_toggle() {
    dsk_dongle_exec at_cmd AT+CFUN=4 -t 5 >/dev/null 2>&1 || true
    sleep 4
    dsk_dongle_exec at_cmd AT+CFUN=1 -t 5 >/dev/null 2>&1 || true
}

dsk_amf_started_at() { sudo docker inspect -f '{{.State.StartedAt}}' "$DSK_AMF_CONTAINER" 2>/dev/null || true; }

dsk_dongle_status() { { dsk_script dongle_status.sh 2>/dev/null || true; } | grep '^RESULT_JSON ' | tail -1 | sed 's/^RESULT_JSON //'; }
dsk_dongle_attached() { [ "$(dsk_dongle_status | jq -r '.attached // false' 2>/dev/null || true)" = "true" ]; }

dsk_wait_dongle_attached() {   # dsk_wait_dongle_attached <timeout_s>
    local waited=0
    while [ "$waited" -lt "$1" ]; do
        check_cancel
        dsk_dongle_attached && return 0
        sleep 5; waited=$((waited + 5))
        [ $((waited % 30)) -eq 0 ] && log "   ⏳ Waiting for the dongle to attach (${waited}s / ${1}s)"
    done
    return 1
}

# Connecting to the AMF does not mean the gNB works: NG Setup happens before
# the fronthaul starts. On 2026-10-11 the RU came back from its reboot with
# its timing off (5% of U-plane packets on time instead of 99%); the gNB got
# malformed uplink (process_mbuf "res != symbol_total_bytes") and segfaulted
# 10-14 s after NG Setup — every time it was restarted, until the RU was
# rebooted again. The dongle then waited for a cell that was not there. So
# give the gNB DSK_GNB_STABLE_WAIT s, then require it still up and still
# associated with the AMF, and the RU to receive most U-plane packets on time.
# The RU publishes its pm-data counters only at the end of each measurement
# interval (~35-40 s), so two readings in the same interval are equal: keep
# reading until they move, up to DSK_RU_COUNTER_WAIT s (a fixed 30 s window
# saw "no packets" in all three recovery attempts on 2026-10-11 16:2x-16:45
# while the RAN was fine). Without the RU's CLI login only the gNB is checked.
dsk_gnb_stable() {   # dsk_gnb_stable <since: when the gNB was restarted>
    local snap now on0 e0 l0 on1 e1 l1 n pct code waited
    snap="$(dsk_ru_counters 2>/dev/null)" || snap=""
    cancellable_sleep "$DSK_GNB_STABLE_WAIT"
    waited=$DSK_GNB_STABLE_WAIT
    while :; do
        if ! dsk_gnb_running || ! dsk_amf_has_gnb "$1"; then
            code=$(dsk_gnb "docker inspect -f '{{.State.ExitCode}}' '$DSK_GNB_CONTAINER' 2>/dev/null" 2>/dev/null) || code="?"
            log "❌ The gNB went down within ${waited}s of connecting (exit code ${code:-?}; 139 = segfault, usually the RU's fronthaul timing)"
            return 1
        fi
        now="$(dsk_ru_counters 2>/dev/null)" || now=""
        if [ -z "$snap" ] || [ -z "$now" ]; then
            log "   ✅ gNB still up after ${waited}s (RU fronthaul counters not available)"
            return 0
        fi
        read -r on0 e0 l0 <<<"$snap"; read -r on1 e1 l1 <<<"$now"
        if [ "$on1" -lt "$on0" ] || [ "$e1" -lt "$e0" ] || [ "$l1" -lt "$l0" ]; then
            snap="$now"   # counters reset (RU rebooted meanwhile): measure from here
        else
            n=$(( (on1 - on0) + (e1 - e0) + (l1 - l0) ))
            [ "$n" -gt 0 ] && break
        fi
        if [ "$waited" -ge "$DSK_RU_COUNTER_WAIT" ]; then
            log "❌ The RU's U-plane counters did not move in ${waited}s with the gNB up"
            return 1
        fi
        cancellable_sleep 10; waited=$((waited + 10))
    done
    pct=$(( 100 * (on1 - on0) / n ))
    if [ "$pct" -lt "$DSK_RU_MIN_ON_TIME_PCT" ]; then
        log "❌ RU fronthaul timing off: only ${pct}% of U-plane packets on time (early $(( 100 * (e1 - e0) / n ))% · late $(( 100 * (l1 - l0) / n ))%, need ≥ ${DSK_RU_MIN_ON_TIME_PCT}%)"
        return 1
    fi
    log "   ✅ gNB still up after ${waited}s, RU fronthaul ${pct}% on time ($n U-plane packets)"
}

# Restart the gNB and wait until the radio side is usable again: gNB
# associated with the AMF, dongle attached with its PDU session. Needed after
# every core (re)start — the gNB does not reconnect to a restarted AMF by
# itself — and to recover a crashed gNB.
dsk_bring_up_ran() {
    log "📡 Restarting the gNB ($DSK_GNB_CONTAINER on $DSK_GNB_HOST) so it connects to the AMF..."
    local since; since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    dsk_gnb "docker compose -f '$DSK_GNB_COMPOSE_FILE' down >/dev/null 2>&1; docker compose -f '$DSK_GNB_COMPOSE_FILE' up -d >/dev/null 2>&1" \
        || { log "❌ Could not restart the gNB"; return 1; }
    DSK_AMF_STARTED_AT="$(dsk_amf_started_at)"

    local waited=0
    while ! dsk_amf_has_gnb "$since"; do
        check_cancel
        [ "$waited" -ge "$DSK_GNB_READY_TIMEOUT" ] && { log "❌ The gNB did not connect to the AMF within ${DSK_GNB_READY_TIMEOUT}s"; return 1; }
        sleep 3; waited=$((waited + 3))
        [ $((waited % 30)) -eq 0 ] && log "   ⏳ Waiting for the gNB to connect to the AMF (${waited}s / ${DSK_GNB_READY_TIMEOUT}s)"
    done
    log "   ✅ gNB connected to the AMF after ${waited}s"
    dsk_gnb_stable "$since" || return 1

    # The dongle still holds the session it had with the previous core and
    # only notices slowly. An airplane toggle makes it register right away;
    # then wait until the NEW AMF has a session for it. In a RAN recovery
    # (dsk_bring_up_ran reboot) the dongle is rebooted instead: after a run of
    # failed random accesses it stays stuck, and a toggle does not free it.
    local reg_since; reg_since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local first_toggle=45 timeout="$DSK_ATTACH_TIMEOUT"
    if [ "${1:-}" = "reboot" ]; then
        log "   🔁 Rebooting dongle $DSK_DONGLE (RAN recovery)..."
        dsk_dongle_exec reboot >/dev/null 2>&1 || true
        first_toggle=$DSK_DONGLE_BOOT_TIME; timeout=$((DSK_ATTACH_TIMEOUT + DSK_DONGLE_BOOT_TIME))
        sleep 20   # it must be down before "attached" can be trusted again
    else
        log "   ⏳ Re-registering dongle $DSK_DONGLE on the restarted core (airplane toggle)..."
        dsk_airplane_toggle
    fi
    waited=0
    until dsk_amf_session_since "$reg_since" && dsk_dongle_attached; do
        check_cancel
        if [ "$waited" -ge "$timeout" ]; then
            log "❌ Dongle $DSK_DONGLE did not attach within ${timeout}s"
            return 1
        fi
        sleep 3; waited=$((waited + 3))
        # Toggle again now and then: a toggle that landed before the cell was
        # back on air registers nothing.
        [ "$waited" -ge "$first_toggle" ] && [ $((waited % 45)) -eq 0 ] && { log "   ⏳ Still waiting for the dongle (${waited}s / ${timeout}s) — toggling airplane mode again"; dsk_airplane_toggle; }
    done
    log "   ✅ Dongle attached (UE IP $(dsk_dongle_status | jq -r '.ue_ip // "?"' 2>/dev/null || true))"
}

# Before an iteration: is the RAN still what we left? Recover if not.
#   - AMF restarted since the gNB last connected (core crash + restart)  -> restart the gNB
#   - gNB container down, or no gNB associated with the AMF (gNB crash)   -> restart the gNB
#   - dongle not attached                                                 -> wait for it
dsk_ensure_ran_ready() {
    local now; now="$(dsk_amf_started_at)"
    if [ -n "${DSK_AMF_STARTED_AT:-}" ] && [ "$now" != "$DSK_AMF_STARTED_AT" ]; then
        log "   ⚠️  The AMF was restarted since the gNB connected — the gNB has to be restarted too"
        dsk_bring_up_ran; return $?
    fi
    if ! dsk_gnb_running; then
        log "   ⚠️  The gNB container is not running (crashed?) — restarting it"
        dsk_bring_up_ran; return $?
    fi
    if ! dsk_amf_has_gnb; then
        log "   ⚠️  No gNB is connected to the AMF — restarting the gNB"
        dsk_bring_up_ran; return $?
    fi
    if ! dsk_dongle_attached; then
        log "   ⚠️  The dongle is not attached — waiting for it (it is never restarted from here)"
        dsk_wait_dongle_attached "$DSK_ATTACH_TIMEOUT" || { log "   ❌ Dongle still not attached"; return 1; }
    fi
    return 0
}

# ── After the run: a run in which any iteration failed is a failed run ───────
# The RAN can come up and the dongle can still drop out right after it (the
# 2026-10-08 night run: all 5 iterations "Dongle did not come back"), and run_batch
# exits 0 anyway. A partly failed run is no better: on 2026-10-09 the RU's
# timing drifted and runs with 1/5 or 3/5 iterations (the rest on a failing
# uplink) were marked done. Exit non-zero instead, so the batch runner does not
# mark the run done (--resume repeats it) and counts it towards its
# consecutive-failure stop. The result file is set aside, not left among the
# real results.
dsk_fail_if_incomplete() {
    local ok total
    ok=$(jq -r '.summary.successful_iterations // 0' "$BATCH_RESULTS_FILE" 2>/dev/null || echo 0)
    total=$(jq -r '.summary.total_iterations // 0' "$BATCH_RESULTS_FILE" 2>/dev/null || echo 0)
    [ "${DSK_RAN_DEGRADED:-0}" != 1 ] && [ "${total:-0}" -gt 0 ] && [ "${ok:-0}" -eq "$total" ] && return 0
    mv -f "$BATCH_RESULTS_FILE" "${BATCH_RESULTS_FILE}.failed" 2>/dev/null || true
    if [ "${DSK_RAN_DEGRADED:-0}" = 1 ]; then
        log "❌ ERROR: RAN degraded ($DSK_DEGRADED_REASON) — run stopped and counted as failed (results kept as $(basename "$BATCH_RESULTS_FILE").failed)"
        exit "$DSK_EXIT_RAN_DEGRADED"
    fi
    error_exit "Only ${ok:-0}/${total:-0} iterations succeeded with the dongle — run counted as failed (results kept as $(basename "$BATCH_RESULTS_FILE").failed)"
}

# ── RAN degradation: checked after every iteration ──────────────────────────
# Logs the iteration's key numbers and returns 0 (= degraded, stop the run)
# when the iteration failed, or when its setup time and its iperf loss are
# both above the limits: the uplink is failing (RU timing drift). Either alone
# also happens on a healthy RAN. Sets DSK_DEGRADED_REASON.
dsk_iteration_degraded() {   # dsk_iteration_degraded <iteration>
    local it status setup loss pmax web
    it=$(jq -c --argjson n "$1" '[.iterations[] | select(.iteration == $n)] | last' "$BATCH_RESULTS_FILE" 2>/dev/null) || it=""
    [ -n "$it" ] && [ "$it" != "null" ] || return 1
    status=$(jq -r '.status' <<<"$it")
    if [ "$status" != "success" ]; then
        DSK_DEGRADED_REASON="iteration $1 failed (${PR_ERROR:-?})"
        return 0
    fi
    setup=$(jq -r '.timing_ms.total // 0 | floor' <<<"$it")
    loss=$(jq -r '.iperf_results.lost_percent // 0 | floor' <<<"$it")
    pmax=$(jq -r '.ping_results.max_ms // "-"' <<<"$it")
    web=$(jq -r '[.webpage_results[]? | select(.success) | .page_load_ms] | sort | if length > 0 then .[length/2|floor] else "-" end' <<<"$it")
    log "   📈 Iteration $1: setup ${setup} ms · ping max ${pmax} ms · iperf loss ${loss}% · page load median ${web} ms"
    if [ "$setup" -gt "$DSK_DEGRADED_SETUP_MS" ] && [ "$loss" -gt "$DSK_DEGRADED_LOSS_PCT" ]; then
        DSK_DEGRADED_REASON="iteration $1: setup ${setup} ms > ${DSK_DEGRADED_SETUP_MS} ms and iperf loss ${loss}% > ${DSK_DEGRADED_LOSS_PCT}%"
        return 0
    fi
    return 1
}

# ── O-RU CLI (LITE-ON) ──────────────────────────────────────────────────────
# Reached over SSH from the gNB host, which has expect; the RU's CLI wants a
# password login plus an 'enable' password. The expect script goes over the
# SSH connection's stdin into a private temp file (mode 600) that is deleted
# right after the run, so the passwords never show in a command line. (expect
# cannot run a script read from stdin itself: it hangs after the login.)
# Prints the CLI's output for the given commands.
# 'reboot' drops the connection (any confirmation prompt is answered).
dsk_ru_cli() {   # dsk_ru_cli <command>...
    local pass enable cmds="" c out rc=0
    pass="$(_dsk_env RU_PASS)"; enable="$(_dsk_env RU_ENABLE_PASS)"
    [ -n "$DSK_RU_HOST" ] && [ -n "$DSK_RU_USER" ] && [ -n "$pass" ] && [ -n "$enable" ] \
        || { log "   ⚠️  The RU's CLI login (RU_HOST / RU_USER / RU_PASS / RU_ENABLE_PASS) is not set in webui/dongle.env"; return 1; }
    for c in "$@"; do cmds+="{$c} "; done
    out=$( { printf 'set target {%s@%s}\nset pw {%s}\nset en {%s}\nset cmds {%s}\n' \
                "$DSK_RU_USER" "$DSK_RU_HOST" "$pass" "$enable" "$cmds"
             cat <<'EXP'
set timeout 30
log_user 0
# Pattern lists must span several lines: on one line expect takes the whole
# {...} as a single pattern.
proc step {pattern answer code} {
    expect {
        -re $pattern { if {$answer ne ""} { send -- "$answer\r" } }
        timeout { exit $code }
        eof { exit $code }
    }
}
spawn ssh -o StrictHostKeyChecking=accept-new -o PubkeyAuthentication=no -o ConnectTimeout=8 $target
step {assword: ?$} $pw 2
step {> ?$} enable 3
step {assword: ?$} $en 3
step {# ?$} "" 4
foreach c $cmds {
    log_user 1
    send -- "$c\r"
    if {$c eq "reboot"} {
        expect {
            -re {y/n|Y/n|y/N|yes/no|[Cc]onfirm} { send "y\r"; exp_continue }
            timeout {}
            eof {}
        }
        exit 0
    }
    step {# ?$} "" 5
    log_user 0
}
# 'exit' only leaves enable mode; just hang up.
catch {close}
catch {wait}
EXP
           } | dsk_gnb 'umask 077; f=$(mktemp); cat > "$f"; expect "$f" </dev/null; rc=$?; rm -f "$f"; exit $rc' 2>&1) || rc=$?
    printf '%s\n' "$out" | tr -d '\r'
    return $rc
}

# U-plane packets the RU has received from the DU since its boot, by arrival
# time against its reception window: "<on time> <early> <late>".
dsk_ru_counters() {
    dsk_ru_cli "show pm-data" 2>/dev/null \
        | awk -F, '$2=="RX_ON_TIME"{on=$NF} $2=="RX_EARLY"{e=$NF} $2=="RX_LATE"{l=$NF} END{if(on!="") printf "%.0f %.0f %.0f\n", on, e, l}'
}

# Log the share of on-time / early / late packets since dsk_ru_snapshot. For
# information only: this counts the downlink, while the drift breaks the
# uplink, and how much "late" the RAN tolerates is not known. Logged so the
# next incident shows whether it would have warned in time.
dsk_ru_snapshot() { DSK_RU_SNAP="$(dsk_ru_counters)" || DSK_RU_SNAP=""; }
dsk_ru_report() {   # dsk_ru_report <since what>
    local now on0 e0 l0 on1 e1 l1; now="$(dsk_ru_counters)" || now=""
    if [ -z "$now" ] || [ -z "${DSK_RU_SNAP:-}" ]; then
        log "   📡 RU fronthaul counters not available"; DSK_RU_SNAP="$now"; return 0
    fi
    read -r on0 e0 l0 <<<"$DSK_RU_SNAP"; read -r on1 e1 l1 <<<"$now"
    if [ "$on1" -lt "$on0" ] || [ "$e1" -lt "$e0" ] || [ "$l1" -lt "$l0" ]; then
        log "   📡 RU fronthaul: counters went back (the RU rebooted since $1)"
    else
        local d_on=$((on1 - on0)) d_e=$((e1 - e0)) d_l=$((l1 - l0)) n
        n=$((d_on + d_e + d_l))
        if [ "$n" -eq 0 ]; then
            log "   📡 RU fronthaul since $1: no U-plane packets"
        else
            log "   📡 RU fronthaul since $1: on time $((100 * d_on / n))% · early $((100 * d_e / n))% · late $((100 * d_l / n))% ($n U-plane packets)"
        fi
    fi
    DSK_RU_SNAP="$now"
}

dsk_ru_ready() { dsk_ru_cli "show oru-status" 2>/dev/null | grep -qE "RF State *: *Ready"; }

# Has the RU booted within the last ~hour? 'show uptime' prints "up 0:12,"
# (h:mm), "up 12 min," or, later, "up 21:53," / "up 1 day, ...".
dsk_ru_rebooted_recently() {
    dsk_ru_cli "show uptime" 2>/dev/null | grep -qE "up +(0:[0-9]+|[0-9]+ min),"
}

# ── RAN recovery ────────────────────────────────────────────────────────────
# What brought the RAN back on 2026-10-10: reboot the RU (its timing is reset),
# leave it alone for a while, restart the gNB, reboot the dongle (it stays
# stuck otherwise). An RU reboot does not always fix its timing (2026-10-11:
# the first one left it at 5% on time, the next one fixed it), so a failed
# attempt starts over from the RU reboot, up to DSK_RECOVERY_ATTEMPTS times.
# Fails if the last attempt does, so the batch stops rather than measuring on
# a RAN that is still broken.
dsk_recover_ran() {
    local attempt rc
    for attempt in $(seq 1 "$DSK_RECOVERY_ATTEMPTS"); do
        [ "$attempt" -gt 1 ] && log "🔁 RAN recovery attempt $attempt/$DSK_RECOVERY_ATTEMPTS — starting over from the RU reboot"
        rc=0; _dsk_recover_ran_once || rc=$?
        [ "$rc" -eq 0 ] && return 0
        [ "$rc" -eq 2 ] && return 1   # cannot reach the RU at all: retrying will not help
    done
    log "❌ RAN still not working after $DSK_RECOVERY_ATTEMPTS recovery attempts"
    return 1
}

_dsk_recover_ran_once() {
    log "🔧 RAN recovery: RU reboot → ${DSK_RU_COOLDOWN}s wait → gNB restart → dongle reboot"
    dsk_ru_cli "show uptime" >/dev/null 2>&1 || { log "❌ Cannot log into the RU's CLI ($DSK_RU_USER@$DSK_RU_HOST via $DSK_GNB_HOST)"; return 2; }
    log "   🔁 Rebooting the RU ($DSK_RU_HOST)..."
    dsk_ru_cli reboot >/dev/null 2>&1 || true
    log "   ⏳ Leaving the RU alone for ${DSK_RU_COOLDOWN}s..."
    cancellable_sleep "$DSK_RU_COOLDOWN"
    local waited=0
    until dsk_ru_ready; do
        check_cancel
        [ "$waited" -ge "$DSK_RU_READY_TIMEOUT" ] && { log "❌ The RU did not report RF Ready within ${DSK_RU_READY_TIMEOUT}s after the wait"; return 1; }
        sleep 15; waited=$((waited + 15))
    done
    dsk_ru_rebooted_recently || { log "❌ The RU's uptime says it did not reboot"; return 1; }
    log "   ✅ RU back (RF Ready)"
    dsk_bring_up_ran reboot || return 1
    dsk_ru_snapshot; sleep 20; dsk_ru_report "the recovery"
    log "✅ RAN recovered"
}

# ── One iteration: cycle the UE and take the control-plane timings ──────────
# Sets the same variables start_packetrusher_with_timing sets, so the result
# JSON has one shape for both UE types.
#
# PacketRusher's "registration → PDU init" span is the registration procedure,
# and "PDU setup" the session setup — the dongle's registration_ms and
# pdu_setup_ms. There is no container, so "startup → registration" is 0, and
# the total is the two procedures' sum (the dongle's own wait between them is
# not network time; dongle_cp_setup.sh reports it separately).
dsk_start_ue_with_timing() {
    local iteration=$1
    log ""; log "---------------------------------------"
    log " Iteration $iteration: cycling dongle $DSK_DONGLE ($DSK_CYCLE)"
    log "---------------------------------------"
    PR_SUCCESS="" PR_ERROR="" PR_UE_IP="" PR_VRF="dongle-$DSK_DONGLE"
    PR_TOTAL_MS="" PR_STARTUP_TO_REG_MS="" PR_REG_TO_PDU_INIT_MS="" PR_PDU_SETUP_MS=""

    dsk_ensure_ran_ready || { PR_SUCCESS="false"; PR_ERROR="ran_not_ready"; return 1; }

    local out="$LOG_DIR/dsk_iter${iteration}_${TIMESTAMP}.log" res
    dsk_script dongle_cp_setup.sh "--mode $DSK_CYCLE" > "$out" 2>&1 || true
    { grep -vE '^RESULT_JSON ' "$out" || true; } | sed 's/^/      /' | tee -a "$LOG_DIR/batch_${TIMESTAMP}.log"
    res=$(grep '^RESULT_JSON ' "$out" | tail -1 | sed 's/^RESULT_JSON //') || true
    if [ -z "$res" ] || [ "$(echo "$res" | jq -r '.ok // false' 2>/dev/null || true)" != "true" ]; then
        PR_SUCCESS="false"
        PR_ERROR="$(echo "$res" | jq -r '.error // empty' 2>/dev/null || true)"; PR_ERROR="${PR_ERROR:-cp_measurement_failed}"
        PR_ERROR="${PR_ERROR//\"/\'}"
        return 1
    fi
    PR_UE_IP=$(echo "$res" | jq -r '.ue_ip // empty')
    PR_STARTUP_TO_REG_MS=0
    PR_REG_TO_PDU_INIT_MS=$(echo "$res" | jq -r '.timing.registration_ms // 0')
    PR_PDU_SETUP_MS=$(echo "$res" | jq -r '.timing.pdu_setup_ms // 0')
    PR_TOTAL_MS=$(echo "$res" | jq -r '.timing.total // 0')
    [ -n "$PR_UE_IP" ] || { PR_SUCCESS="false"; PR_ERROR="no_ue_ip"; return 1; }

    PR_SUCCESS="true"
    log "   ✅ Registration complete! UE IP: $PR_UE_IP (dongle $DSK_DONGLE)"
    log "   ⏱️  Timing: registration: ${PR_REG_TO_PDU_INIT_MS}ms, PDU setup: ${PR_PDU_SETUP_MS}ms, TOTAL: ${PR_TOTAL_MS}ms"
    return 0
}

# ── Webpage test ────────────────────────────────────────────────────────────
# The dongle cannot host a browser; dongle_webpage.sh runs Browsertime on the
# control host with its traffic pinned through the dongle. Fills the same
# result array test_single_webpage does.
dsk_test_single_webpage() {   # dsk_test_single_webpage <url> <site_name> <result array name>
    local url="$1" site_name="$2"
    local -n _wp_result=$3
    _wp_result[success]="false"
    _wp_result[ttfb_ms]=0; _wp_result[fcp_ms]=0; _wp_result[lcp_ms]=0
    _wp_result[dcl_ms]=0;  _wp_result[page_load_ms]=0; _wp_result[total_ms]=0

    local browser="$WEBPAGE_BROWSER"
    [ "$browser" = "edge" ] && browser="chrome"    # dongle_webpage.sh offers firefox and chrome
    local out j err
    out=$(dsk_script dongle_webpage.sh "-u '$url' -b $browser -m $((WEBPAGE_TIMEOUT + 60))" 2>&1) || true
    j=$(echo "$out" | grep '^WEBPAGE_JSON ' | tail -1 | sed 's/^WEBPAGE_JSON //') || true
    if [ -z "$j" ]; then
        err=$(echo "$out" | grep '^RESULT_JSON ' | tail -1 | sed 's/^RESULT_JSON //' | jq -r '.error // empty' 2>/dev/null) || true
        log "      ❌ $site_name: ${err:-page load failed}"
        return 1
    fi
    _wp_result[success]="true"
    _wp_result[ttfb_ms]=$(echo "$j" | jq -r '.ttfb_ms // 0')
    _wp_result[fcp_ms]=$(echo "$j" | jq -r '.fcp_ms // 0')
    _wp_result[lcp_ms]=$(echo "$j" | jq -r '.lcp_ms // 0')
    _wp_result[dcl_ms]=$(echo "$j" | jq -r '.dcl_ms // 0')
    _wp_result[page_load_ms]=$(echo "$j" | jq -r '.page_load_ms // 0')
    _wp_result[total_ms]=$(echo "$j" | jq -r '.total_time_ms // 0')
    log "      ✅ $site_name: TTFB=${_wp_result[ttfb_ms]}ms  FCP=${_wp_result[fcp_ms]}ms  LCP=${_wp_result[lcp_ms]}ms  DCL=${_wp_result[dcl_ms]}ms  Load=${_wp_result[page_load_ms]}ms  NetIdle=${_wp_result[total_ms]}ms"
    return 0
}
