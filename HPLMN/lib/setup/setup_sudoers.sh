#!/usr/bin/env bash
# ============================================================================
# Grant the HPLMN (PC2) user passwordless sudo for the commands the VPLMN WebUI
# runs on this machine over SSH.
#
# Why this is needed:
#   HPLMN has no WebUI of its own — the VPLMN (PC1) WebUI controls it remotely
#   with `ssh <user>@HPLMN "... sudo docker compose up -d"` (and `down`/`ps`),
#   `sudo docker exec ...` (to apply N6 delays inside the UPF container),
#   `sudo tc ...` (delay rules on this host), in Home-Routed mode `sudo ipsec ...`
#   (bring the N9 tunnel up/down/restart) and `sudo sed -i ... /etc/ipsec.conf`
#   (N9 cipher change, esp_config.sh), and `sudo -n bash n4_ipsec.sh ...`
#   (N4 IPsec on this host, from the WebUI and the automation).
#   Those SSH commands run NON-interactively (BatchMode, no terminal), so if
#   sudo asks for a password the command just fails with
#   "sudo: a terminal is required to read the password" — and the WebUI shows
#   "Failed" when you try to start HPLMN. This installs a scoped
#   /etc/sudoers.d drop-in so those specific commands run without a prompt.
#
# Scope: `docker`, `ipsec`, `tc`, `sed` and `bash` — what HPLMN needs as a
#   remote-controlled node (VPLMN also grants nsenter/modprobe/etc. for its
#   local automation and Post-Quantum tab). NOTE: NOPASSWD for bash (needed for
#   n4_ipsec.sh) and sed (writes /etc/ipsec.conf) makes this grant effectively
#   equivalent to full root for this user, the same as on VPLMN.
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
# N9 HR tunnel, driven by the VPLMN WebUI over SSH) would still prompt for a
# password. Best-effort install; a failure here just falls back to a docker-only
# grant rather than aborting the whole setup.
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

# Resolve the real paths of the privileged commands on THIS machine, so it works
# regardless of distro layout (e.g. snap docker).
CMDS=(docker ipsec tc sed bash)
paths=()
for c in "${CMDS[@]}"; do
    # type -P: always resolve to the on-disk binary (command -v could return a
    # bare builtin name, which is invalid in sudoers).
    p=$(type -P "$c" 2>/dev/null || true)
    [ -n "$p" ] && paths+=("$p")
done
if [ ${#paths[@]} -eq 0 ]; then
    echo "ERROR: none of the expected commands (${CMDS[*]}) were found in PATH" >&2
    echo "Install Docker (and strongSwan for IPsec) first, then re-run." >&2
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
    echo "  Verify:  sudo -n docker ps >/dev/null && echo OK"
else
    rm -f "$TMP"
    echo "✗ sudoers syntax check failed — nothing was installed." >&2
    exit 1
fi
