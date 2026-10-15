#!/usr/bin/env bash
#
# Enable / disable commercial-RAN support: a real gNB (e.g. the DSK) with a
# USB-dongle UE, driven from the WebUI dashboard. OFF by default — a testbed
# that only uses PacketRusher never needs it.
#
# Usage:  set-dongle-mode.sh [on|off|status]
#   (no arg)  ask interactively
#   on        enable; prompts for the dongle control host and gNB host SSH
#             settings (current values as defaults; no prompts when stdin is
#             not a terminal)
#   off       disable (the SSH settings are kept for the next `on`)
#   status    print the current state
#
# What it switches:
#   * webui/dongle.env (gitignored) — DONGLE_ENABLED plus the DONGLE_* / GNB_*
#     SSH settings read by the WebUI backend. When disabled the backend serves
#     no dongle/gNB routes, never SSHes to those hosts, and the dashboard hides
#     every dongle/gNB panel. Kept out of VPLMN/.env on purpose: that file is
#     regenerated from scratch by the WebUI, set-open5gs-mode.sh and the
#     automation, which would drop these keys.
#   * The AMF NGAP + metrics bind (docker/amf-docker/amf{,_tls}.yaml, lines
#     tagged NGAP_BIND / METRICS_BIND): 0.0.0.0 when enabled, so an external
#     gNB reaching <VPLMN_IP>:38412 (published by docker-compose) lands on the
#     AMF; the AMF's own docker-network addresses when disabled.
#
# Applying it: if the AMF container is running on an older config than the
# one just written, it is recreated automatically (otherwise the new bind applies on the next
# `docker compose up`). If the WebUI is running you are asked whether to
# restart it, if not whether to start it (no questions when stdin is not a
# terminal — the commands are printed instead).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPLMN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DONGLE_ENV="$VPLMN_ROOT/webui/dongle.env"
AMF_YAMLS=("$VPLMN_ROOT/docker/amf-docker/amf.yaml" "$VPLMN_ROOT/docker/amf-docker/amf_tls.yaml")
# The AMF's addresses on the RAN (N2) and SBI docker networks (docker-compose.yml)
AMF_NGAP_IP="192.168.70.185"
AMF_METRICS_IP="192.168.50.185"

# Current value of KEY in dongle.env ("" if unset)
get_val() {
    [ -f "$DONGLE_ENV" ] || return 0
    grep -E "^$1=" "$DONGLE_ENV" | tail -1 | cut -d'=' -f2- | sed -e 's/^"//' -e 's/"$//'
}

is_enabled() {
    case "$(get_val DONGLE_ENABLED | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

# ask_secret VAR "Prompt" — like ask, but hidden; Enter keeps the current value
ask_secret() {
    local var="$1" prompt="$2" ans="" state="not set"
    [ -n "${!var}" ] && state="set, Enter keeps it"
    if [ -t 0 ]; then
        read -rsp "  $prompt [$state]: " ans; echo
    fi
    [ -n "$ans" ] && printf -v "$var" '%s' "$ans"
    return 0
}

# ask VAR "Prompt" DEFAULT — interactive only; otherwise keeps DEFAULT
ask() {
    local var="$1" prompt="$2" def="$3" ans=""
    if [ -t 0 ]; then
        read -rp "  $prompt [${def}]: " ans
    fi
    printf -v "$var" '%s' "${ans:-$def}"
}

# True if the running AMF was started before its config last changed — i.e.
# it is still on the old bind (also catches an earlier run that never applied).
amf_stale() {
    local started newest f m
    started=$(date -d "$(docker inspect -f '{{.State.StartedAt}}' open5gs-amf 2>/dev/null)" +%s 2>/dev/null) || return 1
    newest=0
    for f in "${AMF_YAMLS[@]}"; do
        m=$(stat -c %Y "$f" 2>/dev/null || echo 0)
        [ "$m" -gt "$newest" ] && newest=$m
    done
    [ "$newest" -gt "$started" ]
}

webui_running() {
    curl -s -m 3 -o /dev/null "http://localhost:9090/api/features"
}

apply_changes() {
    echo
    if [ -z "$(docker ps -q -f name='^open5gs-amf$' 2>/dev/null)" ]; then
        echo "AMF is not running — the NGAP bind applies on the next 'docker compose up'."
    elif amf_stale; then
        echo "Recreating the AMF so it picks up the new NGAP bind ..."
        (cd "$VPLMN_ROOT" && docker compose up -d --force-recreate open5gs-amf) \
            || echo "⚠️  AMF recreate failed — run: docker compose up -d --force-recreate open5gs-amf"
    else
        echo "AMF already runs with this NGAP bind."
    fi

    local webui="$VPLMN_ROOT/webui/start.sh" ans=""
    if webui_running; then
        if [ -t 0 ]; then read -rp "Restart the WebUI now to apply it? [Y/n]: " ans; else ans=n; fi
        case "$ans" in
            [nN]*) echo "Restart it later: $webui restart" ;;
            *)     "$webui" restart ;;
        esac
    else
        if [ -t 0 ]; then read -rp "The WebUI is not running. Start it now? [y/N]: " ans; fi
        case "$ans" in
            [yY]*) "$webui" start ;;
            *)     echo "It applies when you start it: $webui start" ;;
        esac
    fi
}

# ensure_ssh_key LABEL USER HOST PORT KEY — make sure KEY logs in to USER@HOST
# without a password (the batch and the WebUI use BatchMode SSH). Creates the
# key if missing and installs it with ssh-copy-id (asks for that host's
# password once). Without a terminal it only prints the command to run.
ensure_ssh_key() {
    local label="$1" user="$2" host="$3" port="$4" key="${5/#\~/$HOME}"
    [ -n "$user" ] && [ -n "$host" ] || return 0
    local opts=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -i "$key" -p "$port")
    if [ -f "$key" ] && ssh "${opts[@]}" "$user@$host" true 2>/dev/null; then
        echo "  ✓ SSH key login to the $label ($user@$host) works"
        return 0
    fi
    if [ ! -t 0 ]; then
        echo "⚠️  No key login to the $label yet — run: ssh-copy-id -i $key.pub -p $port $user@$host"
        return 0
    fi
    if [ ! -f "$key" ]; then
        echo "  Generating SSH key $key ..."
        ssh-keygen -t ed25519 -N "" -f "$key" >/dev/null || { echo "⚠️  ssh-keygen failed"; return 0; }
    fi
    echo "  Installing $key.pub on the $label ($user@$host) — enter its password:"
    ssh-copy-id -o StrictHostKeyChecking=accept-new -i "$key.pub" -p "$port" "$user@$host" >/dev/null || true
    if ssh "${opts[@]}" "$user@$host" true 2>/dev/null; then
        echo "  ✓ SSH key login to the $label works"
    else
        echo "⚠️  Key login to the $label still fails — run: ssh-copy-id -i $key.pub -p $port $user@$host"
    fi
}

set_amf_bind() {
    local ngap="$1" metrics="$2" f
    for f in "${AMF_YAMLS[@]}"; do
        [ -f "$f" ] || { echo "  SKIP (not found): $f"; continue; }
        # Rewrite only when different: the file's mtime tells apply_changes
        # whether the running AMF is stale, so a no-op run must not touch it.
        grep -q "address: $ngap .*# NGAP_BIND" "$f" \
            || sed -i -E "s/(- address: )[0-9.]+(.*# NGAP_BIND)/\1$ngap\2/" "$f"
        grep -q "address: $metrics .*# METRICS_BIND" "$f" \
            || sed -i -E "s/(- address: )[0-9.]+(.*# METRICS_BIND)/\1$metrics\2/" "$f"
        grep -q "address: $ngap .*# NGAP_BIND" "$f" || { echo "❌ NGAP_BIND line not found in $f"; exit 1; }
        echo "  ✓ $(basename "$f"): NGAP $ngap, metrics $metrics"
    done
}

write_env() {
    local enabled="$1"
    # Holds the dongles' root password: readable by this user only.
    ( umask 077; : > "$DONGLE_ENV" ); chmod 600 "$DONGLE_ENV"
    cat > "$DONGLE_ENV" <<EOF
# Commercial RAN (gNB + USB dongle UE) — written by lib/features/set-dongle-mode.sh
# Machine-local (gitignored). Restart the WebUI after editing.
DONGLE_ENABLED=$enabled

# Control host of the dongle bench: the dongles are plugged in there. The
# dongle scripts (lib/dsk) run on this host and jump through it with this key.
DONGLE_HOST=$DONGLE_HOST
DONGLE_USER=$DONGLE_USER
DONGLE_PORT=$DONGLE_PORT
DONGLE_KEY_PATH=$DONGLE_KEY_PATH

# gNB host (the radio the dongle attaches to; controlled via docker compose)
GNB_HOST=$GNB_HOST
GNB_USER=$GNB_USER
GNB_PORT=$GNB_PORT
GNB_KEY_PATH=$GNB_KEY_PATH
GNB_CONTAINER=$GNB_CONTAINER
GNB_COMPOSE_FILE=$GNB_COMPOSE_FILE

# Root password of the dongles (lib/dsk/*.sh log in with sshpass via the control host)
DONGLE_SSH_PASS=$DONGLE_SSH_PASS

# O-RU CLI (LITE-ON), reached from the gNB host — the batch reboots it when its
# timing drifts (lib/automation/dsk.sh, dsk_recover_ran). Empty = no recovery.
RU_HOST=$RU_HOST
RU_USER=$RU_USER
RU_PASS=$RU_PASS
RU_ENABLE_PASS=$RU_ENABLE_PASS
EOF
}

load_current() {
    DONGLE_HOST="$(get_val DONGLE_HOST)"
    DONGLE_USER="$(get_val DONGLE_USER)"
    DONGLE_PORT="$(get_val DONGLE_PORT)";         DONGLE_PORT="${DONGLE_PORT:-22}"
    DONGLE_KEY_PATH="$(get_val DONGLE_KEY_PATH)"; DONGLE_KEY_PATH="${DONGLE_KEY_PATH:-~/.ssh/id_ed25519}"
    GNB_HOST="$(get_val GNB_HOST)"
    GNB_USER="$(get_val GNB_USER)"
    GNB_PORT="$(get_val GNB_PORT)";               GNB_PORT="${GNB_PORT:-22}"
    GNB_KEY_PATH="$(get_val GNB_KEY_PATH)";       GNB_KEY_PATH="${GNB_KEY_PATH:-~/.ssh/id_ed25519}"
    GNB_CONTAINER="$(get_val GNB_CONTAINER)"
    GNB_COMPOSE_FILE="$(get_val GNB_COMPOSE_FILE)"
    DONGLE_SSH_PASS="$(get_val DONGLE_SSH_PASS)"
    RU_HOST="$(get_val RU_HOST)";                 RU_HOST="${RU_HOST:-192.168.1.100}"
    RU_USER="$(get_val RU_USER)";                 RU_USER="${RU_USER:-user}"
    RU_PASS="$(get_val RU_PASS)"
    RU_ENABLE_PASS="$(get_val RU_ENABLE_PASS)"
}

print_status() {
    if is_enabled; then
        echo "Commercial RAN (dongle) support: ENABLED"
        echo "  dongle control host: $(get_val DONGLE_USER)@$(get_val DONGLE_HOST)"
        echo "  gNB host:            $(get_val GNB_USER)@$(get_val GNB_HOST)"
    else
        echo "Commercial RAN (dongle) support: disabled"
    fi
}

enable() {
    load_current
    echo "Commercial RAN SSH settings (Enter keeps the value in brackets):"
    echo " Dongle control host:"
    ask DONGLE_HOST     "Host / IP"        "$DONGLE_HOST"
    ask DONGLE_USER     "SSH user"         "$DONGLE_USER"
    ask DONGLE_PORT     "SSH port"         "$DONGLE_PORT"
    ask DONGLE_KEY_PATH "SSH key"          "$DONGLE_KEY_PATH"
    ask_secret DONGLE_SSH_PASS "Dongles' root password"
    echo " gNB host:"
    ask GNB_HOST         "Host / IP"             "$GNB_HOST"
    ask GNB_USER         "SSH user"              "$GNB_USER"
    ask GNB_PORT         "SSH port"              "$GNB_PORT"
    ask GNB_KEY_PATH     "SSH key"               "$GNB_KEY_PATH"
    ask GNB_CONTAINER    "gNB container name"    "$GNB_CONTAINER"
    ask GNB_COMPOSE_FILE "gNB compose file path" "$GNB_COMPOSE_FILE"
    echo " O-RU CLI (seen from the gNB host; for the batch's RAN recovery):"
    ask RU_HOST          "Host / IP"             "$RU_HOST"
    ask RU_USER          "CLI user"              "$RU_USER"
    ask_secret RU_PASS        "CLI password"
    ask_secret RU_ENABLE_PASS "CLI 'enable' password"
    write_env true
    set_amf_bind 0.0.0.0 0.0.0.0
    local missing=()
    for v in DONGLE_HOST DONGLE_USER DONGLE_SSH_PASS GNB_HOST GNB_USER GNB_CONTAINER GNB_COMPOSE_FILE; do
        [ -n "${!v}" ] || missing+=("$v")
    done
    [ ${#missing[@]} -eq 0 ] || echo "⚠️  Still empty: ${missing[*]} — fill them in $DONGLE_ENV"
    ensure_ssh_key "dongle control host" "$DONGLE_USER" "$DONGLE_HOST" "$DONGLE_PORT" "$DONGLE_KEY_PATH"
    ensure_ssh_key "gNB host"            "$GNB_USER"    "$GNB_HOST"    "$GNB_PORT"    "$GNB_KEY_PATH"
    local tool
    for tool in sshpass tshark; do
        command -v "$tool" >/dev/null 2>&1 || echo "⚠️  $tool is not installed — the dongle scripts need it: sudo apt-get install $tool"
    done
    echo "✅ Commercial RAN support enabled"
}

disable() {
    load_current
    write_env false
    set_amf_bind "$AMF_NGAP_IP" "$AMF_METRICS_IP"
    echo "✅ Commercial RAN support disabled"
}

ACTION="${1:-}"
if [ -z "$ACTION" ]; then
    print_status
    read -rp "Do you have a commercial RAN (gNB + dongle UE) to test with? [y/N]: " ans
    case "$ans" in [yY]*) ACTION=on ;; *) ACTION=off ;; esac
fi

case "$ACTION" in
    on)     enable ;;
    off)    disable ;;
    status) print_status; exit 0 ;;
    *)      echo "Usage: $0 [on|off|status]"; exit 1 ;;
esac

apply_changes
