#!/bin/bash
# ============================================================================
# dongle_usb.sh — keep every dongle's USB link at USB 2 (sourced, not run)
# ============================================================================
# At SuperSpeed (USB 3.x) the dongles' RNDIS/IPA data path does not survive
# traffic forwarded across the USB link (the page-load test): seconds in, the
# dongle stops answering on USB for good — no ARP, no frames — while the radio
# and PDU session stay up, so the core and gNB log nothing and only a replug
# brings it back. Measured on this bench with one dongle, one cable, one port:
# at 10 Gbps the link died on the first page load every time; at 480 Mbps it
# survived every run. A dongle that negotiates High-Speed by itself never
# showed the fault. 480 Mbps is far above what the radio carries here.
#
# The fix is per HOST PORT: switch off the SuperSpeed half of the port a
# dongle is plugged into, and the dongle re-attaches over the port's USB 2
# half within seconds. It survives replugging and rebooting the dongle; it
# resets only when this host reboots (or the dongle moves to another port),
# which is why it is re-checked on every status poll rather than done once.
#
# Every RNDIS device on this host is treated as a dongle, so all of them are
# covered — the selected one and any other plugged in at the same time — with
# nothing hardcoded. Ports are found from sysfs at runtime.
#
# Writing a port's 'disable' file needs root; Docker (already required by the
# page-load test, and root-equivalent) does it from a one-off privileged
# container, so this host needs no sudo.
#
# Set DONGLE_ALLOW_SUPERSPEED=1 to leave links alone (e.g. to reproduce).
# ============================================================================

DONGLE_USB_IMAGE="${DONGLE_USB_IMAGE:-sitespeedio/browsertime}"

# sysfs dir of the USB device behind a network interface
usb_dev_of() {
    local d
    d=$(readlink -f "/sys/class/net/$1/device" 2>/dev/null) || return 1
    d=$(dirname "$d")                     # .../X-Y:1.0 -> .../X-Y
    [[ -r "$d/speed" ]] && printf '%s\n' "$d"
}

# USB speed (Mbps) of the device behind a network interface, or empty
usb_speed_of() {
    local d; d=$(usb_dev_of "$1") || return 1
    cat "$d/speed" 2>/dev/null
}

# Port paths of every RNDIS dongle currently on a SuperSpeed link. Pure sysfs
# reads, so it is cheap enough to run on every status poll.
dongle_superspeed_ports() {
    local n drv d speed
    for n in /sys/class/net/*; do
        drv=$(readlink -f "$n/device/driver" 2>/dev/null) || continue
        [[ "$(basename "$drv")" == rndis_host ]] || continue
        d=$(usb_dev_of "$(basename "$n")") || continue
        speed=$(cat "$d/speed" 2>/dev/null)
        [[ "$speed" =~ ^[0-9]+$ ]] && (( speed >= 5000 )) || continue
        readlink -f "$d/port" 2>/dev/null
    done | sort -u
}

# Switch every SuperSpeed dongle to USB 2. Prints one line per port switched.
# Returns 0 if at least one port was switched, 1 if none needed it,
# 2 if a switch was needed but failed (no image / no privileged docker).
dongle_force_usb2() {
    [[ "${DONGLE_ALLOW_SUPERSPEED:-0}" == 1 ]] && return 1
    local ports p cmd=""
    ports=$(dongle_superspeed_ports)
    [[ -n "$ports" ]] || return 1
    for p in $ports; do
        [[ -e "$p/disable" ]] || return 2
        cmd+="echo 1 > '$p/disable'; "
    done
    command -v docker >/dev/null 2>&1 || return 2
    docker image inspect "$DONGLE_USB_IMAGE" >/dev/null 2>&1 || return 2
    docker run --rm --privileged -v /sys:/sys --entrypoint sh "$DONGLE_USB_IMAGE" \
        -c "$cmd" >/dev/null 2>&1 || return 2
    for p in $ports; do printf '%s\n' "$(basename "$p")"; done
    return 0
}
