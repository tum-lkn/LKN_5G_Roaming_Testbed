# ============================================================================
# dongle_env.sh — shared settings and helpers for the dongle scripts (sourced)
# ============================================================================
# The dongle scripts live here, in the repository, and run on the VPLMN. They
# used to live on the dongle bench's control host (~/data_roaming) together
# with a dongle_env.sh that held the dongle's root password and the VPLMN's
# login. Nothing is stored on the control host any more; it is still needed
# for three things that are physically tied to it:
#
#   1. The way in: the dongles are USB devices on the control host and only
#      reachable on its USB networks (192.168.43.x / 192.168.44.x). Every SSH
#      to a dongle jumps through it (DONGLE_JUMP_OPTS), over one multiplexed
#      connection.
#   2. The USB 2 fix and the ICMP gate: both act on the control host's own
#      USB port / link (ctrl_force_usb2, dongle_icmp).
#   3. The page-load test: the browser has to run where the dongle is plugged
#      in. dongle_webpage.sh ships itself there for each run (ctrl_run_bundle)
#      and removes itself afterwards.
#
# Settings come from webui/dongle.env (gitignored), the file the WebUI and
# lib/features/set-dongle-mode.sh use:
#   DONGLE_HOST / DONGLE_USER / DONGLE_PORT / DONGLE_KEY_PATH   control host
#   DONGLE_SSH_PASS                                             dongles' root password
# Every value below stays env-overridable, as before, so a caller can point a
# script at another dongle (SSH_HOST / SSH_PORT) without editing anything.
# ============================================================================

DSK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# webui/dongle.env holds KEY=VALUE lines; read them without sourcing, so a
# password with shell characters in it stays a literal string.
DONGLE_ENV_SETTINGS="${DONGLE_ENV_SETTINGS:-$DSK_LIB_DIR/../../webui/dongle.env}"
_dongle_setting() {
    [[ -r "$DONGLE_ENV_SETTINGS" ]] || return 0
    sed -n "s/^$1=//p" "$DONGLE_ENV_SETTINGS" | tail -1
}

# ── Control host (the jump host and the home of the USB ports) ──────────────
CTRL_HOST="${CTRL_HOST:-$(_dongle_setting DONGLE_HOST)}"
CTRL_USER="${CTRL_USER:-$(_dongle_setting DONGLE_USER)}"
CTRL_PORT="${CTRL_PORT:-$(_dongle_setting DONGLE_PORT)}"; CTRL_PORT="${CTRL_PORT:-22}"
CTRL_KEY="${CTRL_KEY:-$(_dongle_setting DONGLE_KEY_PATH)}"; CTRL_KEY="${CTRL_KEY/#\~/$HOME}"

# ── Dongle (default A; the WebUI and dsk.sh export SSH_HOST/SSH_PORT) ───────
SSH_HOST="${SSH_HOST:-192.168.44.1}"
SSH_PORT="${SSH_PORT:-8822}"
SSH_PASS="${SSH_PASS:-$(_dongle_setting DONGLE_SSH_PASS)}"
# sshpass -e reads the password from SSHPASS, so it never appears in a
# process list (sshpass -p would put it on the command line).
export SSHPASS="$SSH_PASS"

# ── The VPLMN, where the NGAP capture is taken — this host ──────────────────
VPLMN_HOST="${VPLMN_HOST:-10.0.0.10}"
AMF_CONTAINER="${AMF_CONTAINER:-open5gs-amf}"

# ── Measurement defaults (every one can be overridden by an env var) ────────
REMOTE_TARGET="${REMOTE_TARGET:-10.0.0.30}"   # ping destination behind the core
PING_FALLBACK="${PING_FALLBACK:-8.8.8.8}"     # ping target when REMOTE_TARGET is down
CAPTURE_IFACE="${CAPTURE_IFACE:-any}"         # iface on the VPLMN carrying NGAP
GNB_IP="${GNB_IP:-10.0.0.2}"                  # the gNB the dongle attaches to
AMF_IP="${AMF_IP:-10.0.0.10}"                 # AMF (VPLMN core)

# Ping target with a fallback: REMOTE_TARGET when this host can reach it,
# PING_FALLBACK otherwise, so the reachability checks do not fail just because
# the server behind the core is down. For PINGING only — REMOTE_TARGET is also
# the iperf and download server, which a public host cannot stand in for.
# Set PING_TARGET to skip the check. The answer is cached for 60s so back-to-
# back runs do not each wait on an unreachable host.
resolve_ping_target() {
    if [[ -n "${PING_TARGET:-}" ]]; then printf '%s\n' "$PING_TARGET"; return; fi
    local cache="${TMPDIR:-/tmp}/dongle_ping_target.$(id -u)" now ts primary target
    now=$(date +%s)
    if read -r ts primary target 2>/dev/null < "$cache" \
       && [[ "$primary" == "$REMOTE_TARGET" && $(( now - ts )) -lt 60 ]]; then
        printf '%s\n' "$target"; return
    fi
    if ping -c 1 -W 1 "$REMOTE_TARGET" >/dev/null 2>&1; then
        target="$REMOTE_TARGET"
    else
        target="$PING_FALLBACK"
    fi
    printf '%s %s %s\n' "$now" "$REMOTE_TARGET" "$target" > "$cache" 2>/dev/null || true
    printf '%s\n' "$target"
}

# Everything below is for the VPLMN side only. A script shipped to the
# control host by ctrl_run_bundle gets a minimal settings file instead, with
# DONGLE_ON_CTRL=1, and must not try to jump to itself.
[[ "${DONGLE_ON_CTRL:-0}" == 1 ]] && return 0

# ── SSH to the control host, one multiplexed connection ─────────────────────
# A test issues many short commands (every ping of a ping test, every status
# poll), and a fresh handshake for each would cost more than the command.
CTRL_SSH_OPTS=(
    -o BatchMode=yes
    -o ConnectTimeout=8
    -o StrictHostKeyChecking=accept-new
    -o LogLevel=ERROR
    -o ControlMaster=auto
    -o ControlPersist=300
    -o "ControlPath=/tmp/dsk-ctrl-%r@%h-%p"
    -o ServerAliveInterval=15
    -p "$CTRL_PORT"
)
[[ -n "$CTRL_KEY" && -r "$CTRL_KEY" ]] && CTRL_SSH_OPTS+=(-i "$CTRL_KEY")
ctrl_ssh() { ssh "${CTRL_SSH_OPTS[@]}" "$CTRL_USER@$CTRL_HOST" "$@"; }

# Added to every SSH to a dongle: reach it through the control host's
# multiplexed connection (-W forwards stdin/stdout to the dongle's sshd).
_jump="ssh"
for _o in "${CTRL_SSH_OPTS[@]}"; do _jump+=" $(printf '%q' "$_o")"; done
_jump+=" -W %h:%p $(printf '%q' "$CTRL_USER@$CTRL_HOST")"
DONGLE_JUMP_OPTS=(-o "ProxyCommand=$_jump")
unset _jump _o

# ICMP probe of the dongle, sent from the control host (the dongle's link is
# there). Cheap for the modem; used to decide whether an SSH is worth trying.
dongle_icmp() {   # dongle_icmp [timeout_s]
    ctrl_ssh "ping -c 1 -W ${1:-2} $(printf '%q' "$SSH_HOST")" >/dev/null 2>&1
}

# Run dongle_usb.sh's dongle_force_usb2 on the control host (it writes the
# USB port's sysfs there). Same output and exit codes as calling it locally.
ctrl_force_usb2() {
    { cat "$DSK_LIB_DIR/dongle_usb.sh"; printf '\ndongle_force_usb2\n'; } \
        | ctrl_ssh "DONGLE_ALLOW_SUPERSPEED=$(printf '%q' "${DONGLE_ALLOW_SUPERSPEED:-0}") bash -s"
}

# Run one of these scripts ON the control host, without leaving it there:
# copy it, dongle_usb.sh and a minimal settings file (no passwords) into a
# fresh temp dir, run it with a pty (-tt: line-by-line output, and a local
# cancel hangs the remote script up too), remove the dir afterwards.
ctrl_run_bundle() {   # ctrl_run_bundle <script> [args...]
    local script="$1"; shift
    local stage remote args="" a
    stage=$(mktemp -d) || return 1
    cp "$DSK_LIB_DIR/$script" "$DSK_LIB_DIR/dongle_usb.sh" "$stage/"
    {
        echo "DONGLE_ON_CTRL=1"
        printf 'SSH_HOST=%q\nSSH_PORT=%q\nREMOTE_TARGET=%q\nPING_FALLBACK=%q\n' \
            "$SSH_HOST" "$SSH_PORT" "$REMOTE_TARGET" "$PING_FALLBACK"
    } > "$stage/dongle_env.sh"
    remote=$(ctrl_ssh 'mktemp -d /tmp/dsk-bundle.XXXXXX') || { rm -rf "${stage:?}"; return 1; }
    tar -C "$stage" -cf - . | ctrl_ssh "tar -C $(printf '%q' "$remote") -xf -" \
        || { rm -rf "${stage:?}"; return 1; }
    rm -rf "${stage:?}"
    for a in "$@"; do args+=" $(printf '%q' "$a")"; done
    # The pty turns every newline into \r\n; strip the \r so callers parse the
    # same lines as before. The exit status is the remote script's.
    ssh -tt "${CTRL_SSH_OPTS[@]}" "$CTRL_USER@$CTRL_HOST" \
        "d=$(printf '%q' "$remote"); trap 'rm -rf \"\$d\"' EXIT HUP INT TERM; DONGLE_ON_CTRL=1 bash \"\$d/$script\"$args" \
        | tr -d '\r'
    return "${PIPESTATUS[0]}"
}
