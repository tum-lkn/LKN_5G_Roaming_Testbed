#!/usr/bin/env bash
# ============================================================================
# Grant the testbed user passwordless sudo for the commands the automation and
# batch scripts run non-interactively.
#
# Why this is needed:
#   The WebUI backend runs as your normal user (never root — see webui/start.sh).
#   The automation/batch scripts apply network delays with `sudo tc` (host
#   traffic control) and `sudo docker` (delay inside the UPF container). A batch
#   run has no terminal, so if sudo asks for a password the command just fails
#   with e.g. "Failed to apply N6 delay on local UPF". This installs a scoped
#   /etc/sudoers.d drop-in so those commands run without a password prompt.
#
# Usage:
#   ./setup_sudoers.sh            # grant to the current user
#   ./setup_sudoers.sh <user>     # grant to a specific user
#
# Safe to re-run; validates with `visudo -c` before installing.
# ============================================================================
set -euo pipefail

USER_TO_GRANT="${1:-$(whoami)}"
if ! id "$USER_TO_GRANT" &>/dev/null; then
    echo "ERROR: user '$USER_TO_GRANT' does not exist" >&2
    exit 1
fi

# Make sure strongSwan is installed so `ipsec` resolves below and is included in
# the grant. Paths are resolved at runtime, so if this script runs before
# strongSwan is installed, ipsec would be silently omitted and `sudo ipsec` (the
# N9 HR tunnel used by the automation/WebUI) would still prompt for a password.
# Best-effort install; a failure here just falls back to omitting ipsec rather
# than aborting the whole setup.
if ! type -P ipsec >/dev/null 2>&1; then
    echo "strongSwan ('ipsec') not found — installing so it can be granted..."
    if   command -v apt-get >/dev/null; then sudo apt-get install -y strongswan strongswan-pki strongswan-starter || true
    elif command -v dnf     >/dev/null; then sudo dnf install -y strongswan || true
    elif command -v yum     >/dev/null; then sudo yum install -y strongswan || true
    elif command -v pacman  >/dev/null; then sudo pacman -S --noconfirm strongswan || true
    else echo "WARNING: no supported package manager found; install strongSwan manually." >&2
    fi
    type -P ipsec >/dev/null 2>&1 || echo "WARNING: strongSwan still unavailable; 'ipsec' will be omitted from the grant." >&2
fi

# Resolve the real paths of the privileged commands the testbed uses. Paths are
# resolved on THIS machine so it works regardless of distro layout (e.g. snap
# docker). bash/pkill/true are required by the WebUI's Post-Quantum tab (the PQ
# backend runs `sudo -n bash ike_eval_docker.sh`, probes with `sudo -n true`,
# and cleans up with `sudo -n pkill`). NOTE: NOPASSWD for bash makes this grant
# effectively equivalent to full root for this user.
CMDS=(tc docker fuser ss netstat ip nsenter ipsec modprobe rmmod bash pkill true)
paths=()
for c in "${CMDS[@]}"; do
    # type -P: always resolve to the on-disk binary (command -v would return
    # bare builtin names like "true", which are invalid in sudoers).
    p=$(type -P "$c" 2>/dev/null || true)
    [ -n "$p" ] && paths+=("$p")
done
if [ ${#paths[@]} -eq 0 ]; then
    echo "ERROR: none of the expected commands (${CMDS[*]}) were found in PATH" >&2
    exit 1
fi
joined=$(IFS=,; echo "${paths[*]}")

SUDOERS_FILE="/etc/sudoers.d/roamingtb-${USER_TO_GRANT}"
TMP=$(mktemp)
printf '# Passwordless sudo for the Open5GS roaming testbed (installed by setup_sudoers.sh)\n%s ALL=(ALL) NOPASSWD: %s\n' \
    "$USER_TO_GRANT" "$joined" > "$TMP"

echo "Will install $SUDOERS_FILE with:"
sed 's/^/    /' "$TMP"
echo

# Validate syntax against the whole sudoers ruleset before installing.
if sudo visudo -cf "$TMP" >/dev/null; then
    sudo install -m 0440 -o root -g root "$TMP" "$SUDOERS_FILE"
    rm -f "$TMP"
    echo "✓ Installed. '$USER_TO_GRANT' now has passwordless sudo for: ${paths[*]}"
    echo "  Verify:  sudo -n tc qdisc show >/dev/null && echo OK"
else
    rm -f "$TMP"
    echo "✗ sudoers syntax check failed — nothing was installed." >&2
    exit 1
fi
