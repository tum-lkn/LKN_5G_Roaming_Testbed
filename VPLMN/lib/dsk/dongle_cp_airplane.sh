#!/bin/bash
# ============================================================================
# dongle_cp_airplane.sh — control-plane measurement WITHOUT rebooting the dongle
# ============================================================================
# Same measurement as dongle_cp_setup.sh — NGAP capture on the VPLMN, the same
# parsing, the same RESULT_JSON — but the UE is cycled by switching the
# modem's radio off and on (airplane mode, AT+CFUN=4 / AT+CFUN=1) instead of
# rebooting the whole dongle. That takes a few seconds instead of ~2 minutes
# and produces ONE registration instead of the two a reboot causes.
#
# This is dongle_cp_setup.sh in --mode airplane; all the logic lives there, so
# the two cannot drift apart. Arguments are passed through (e.g. --parse-only).
#
# Usage:
#   dongle_cp_airplane.sh
# ============================================================================
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dongle_cp_setup.sh" --mode airplane "$@"
