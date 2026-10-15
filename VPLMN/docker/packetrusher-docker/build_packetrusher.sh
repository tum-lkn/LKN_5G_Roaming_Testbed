#!/usr/bin/env bash
#
# Build the testbed's PacketRusher image (packetrusher:20250225) from upstream
# HewlettPackard/PacketRusher source. This is the drop-in replacement for the
# old ghcr.io/borjis131/packetrusher:main fork image, which predated PR #135
# and sent QFI-less uplink G-PDUs -> the stock Open5GS v2.8.0 UPF dropped all
# uplink (strict QFI PDR match). The pinned ref below already contains PR #135.
#
# The source lives at VPLMN/PacketRusher (gitignored). If it is not present
# (fresh checkout), it is cloned at the pinned ref. gtp5g is a HOST kernel
# module and is NOT built here.
#
# Usage:  ./build_packetrusher.sh [--rebuild]
#   (no arg)   build only if the image is missing
#   --rebuild  remove and rebuild even if it already exists
# Env:
#   DOCKER_CMD   docker invocation to use (default "docker"; pass e.g.
#                "sudo docker" or "sudo -n docker" on hosts that need it)
set -euo pipefail

IMAGE="packetrusher:20250225"
PR_REPO="https://github.com/HewlettPackard/PacketRusher.git"
# 20250225-25-g5bf8b4e — the 20250225 snapshot (has PR #135) + later fixes;
# this is exactly the build verified for HR/LBO/non-roaming on Open5GS v2.8.0.
PR_REF="5bf8b4e"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPLMN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DIR="$VPLMN_ROOT/PacketRusher"
DOCKERFILE="$SCRIPT_DIR/Dockerfile"
DOCKER_CMD="${DOCKER_CMD:-docker}"

REBUILD=0
[ "${1:-}" = "--rebuild" ] && REBUILD=1

if [ "$REBUILD" -eq 0 ] && $DOCKER_CMD image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "[SKIP] $IMAGE already present (use --rebuild to force)"
    exit 0
fi

# Ensure the upstream source is present (fresh operators won't have the
# gitignored checkout). Clone at the pinned ref for reproducibility.
if [ ! -d "$SRC_DIR/.git" ]; then
    echo "[CLONE] $PR_REPO -> $SRC_DIR"
    git clone "$PR_REPO" "$SRC_DIR"
    git -C "$SRC_DIR" checkout "$PR_REF"
else
    echo "[SRC]   using existing checkout at $SRC_DIR ($(git -C "$SRC_DIR" describe --tags --always 2>/dev/null || echo unknown))"
fi

[ "$REBUILD" -eq 1 ] && $DOCKER_CMD image rm -f "$IMAGE" >/dev/null 2>&1 || true

echo "[BUILD] $IMAGE  (Dockerfile: $DOCKERFILE, context: $SRC_DIR)"
DOCKER_BUILDKIT=1 $DOCKER_CMD build -f "$DOCKERFILE" -t "$IMAGE" "$SRC_DIR"
echo "[OK]    $IMAGE built"
