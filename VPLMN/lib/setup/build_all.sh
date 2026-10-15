#!/bin/bash

# Builds the VPLMN Open5GS images.
#
# By default an image that already exists is left alone ([SKIP]). If any are
# already built, an interactive run asks whether to rebuild them from scratch;
# rebuilding stops the stack, removes those images, and builds them again.
#
# Usage: build_all.sh [--rebuild | --keep]
#   --rebuild  remove existing Open5GS images and rebuild, without asking
#   --keep     keep existing images and build only what is missing (no prompt)
# With neither flag, an interactive terminal is prompted and a non-interactive
# run (CI, cron, piped stdin) defaults to --keep so it can never block.

# Navigate to the testbed root (two levels up from lib/setup/), because the
# docker build paths below are relative to it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.." || exit

# Force BuildKit: the unified UPF (Dockerfile.upf) still declares a
# `FROM base-open5gs … AS builder` stage but no longer COPYs from it, so
# BuildKit skips that stage and base-open5gs is not needed.
export DOCKER_BUILDKIT=1

REBUILD_MODE="ask"
for arg in "$@"; do
    case "$arg" in
        --rebuild) REBUILD_MODE="rebuild" ;;
        --keep)    REBUILD_MODE="keep" ;;
        -h|--help) sed -n '3,13p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg (try --help)"; exit 1 ;;
    esac
done

FAILED=0

image_exists() {
    docker image inspect "$1" &>/dev/null
}

# ── The images this script builds ────────────────────────────────────────────
# Single source of truth: drives both the rebuild prompt below and the builds
# at the bottom, so the two can never disagree about which images are ours.
# Format: "<tag>|<docker build arguments>"
# Image tag for the Open5GS NF images. v2.8.0 unifies HR / LBO / Non-Roaming
# into ONE image set — the UPF is a single unified image (built from files/,
# so no base-open5gs / separate LBO UPF any more). MongoDB shares the same tag
# for label consistency (its image content is not open5gs-derived). Override to build another tag,
# e.g.  OPEN5GS_TAG=v2.7.6-hr ./build_all.sh
TAG="${OPEN5GS_TAG:-v2.8.0}"

IMAGES=(
    "open5gs-amf:${TAG}|-f docker/amf-docker/Dockerfile.amf     docker/amf-docker"
    "open5gs-ausf:${TAG}|-f docker/ausf-docker/Dockerfile.ausf   docker/ausf-docker"
    "open5gs-bsf:${TAG}|-f docker/bsf-docker/Dockerfile.bsf     docker/bsf-docker"
    "open5gs-mongodb:${TAG}|-f docker/mongodb-docker/Dockerfile     docker/mongodb-docker"
    "open5gs-nrf:${TAG}|-f docker/nrf-docker/Dockerfile.nrf     docker/nrf-docker"
    "open5gs-nssf:${TAG}|-f docker/nssf-docker/Dockerfile.nssf   docker/nssf-docker"
    "open5gs-pcf:${TAG}|-f docker/pcf-docker/Dockerfile.pcf     docker/pcf-docker"
    "open5gs-scp:${TAG}|-f docker/scp-docker/Dockerfile.scp     docker/scp-docker"
    "open5gs-sepp:${TAG}|-f docker/sepp-docker/Dockerfile.sepp   docker/sepp-docker"
    "open5gs-smf:${TAG}|-f docker/smf-docker/Dockerfile.smf     docker/smf-docker"
    "open5gs-udm:${TAG}|-f docker/udm-docker/Dockerfile.udm     docker/udm-docker"
    "open5gs-udr:${TAG}|-f docker/udr-docker/Dockerfile.udr     docker/udr-docker"
    "open5gs-upf:${TAG}|-f docker/upf-docker/Dockerfile.upf     docker/upf-docker"
)

# Echoes the tags from IMAGES (plus the two conditional ones) that exist now.
existing_images() {
    local entry tag
    for entry in "${IMAGES[@]}"; do
        tag="${entry%%|*}"
        image_exists "$tag" && echo "$tag"
    done
}

# Removes every existing image in our list, stopping the stack first: docker
# rmi refuses while a container still references the image, and a running
# stack would otherwise be left pointing at images that no longer exist.
remove_existing_images() {
    local -a present
    mapfile -t present < <(existing_images)

    if [ -n "$(docker compose ps -aq 2>/dev/null)" ]; then
        echo "[DOWN] containers are using these images — stopping the stack"
        docker compose down || echo "[WARN] docker compose down reported an error"
    fi

    local tag rmi_failed=0
    for tag in "${present[@]}"; do
        if docker rmi -f "$tag" >/dev/null 2>&1; then
            echo "[RMI] removed $tag"
        else
            echo "[FAILED] could not remove $tag (still in use?)"
            rmi_failed=$((rmi_failed + 1))
        fi
    done
    return "$rmi_failed"
}

# ── Decide what to do with images that are already built ─────────────────────
mapfile -t PRESENT < <(existing_images)

if [ ${#PRESENT[@]} -eq 0 ]; then
    [ "$REBUILD_MODE" = "rebuild" ] && echo "Nothing to rebuild — no Open5GS images exist yet."
elif [ "$REBUILD_MODE" = "ask" ]; then
    echo ""
    echo "Found ${#PRESENT[@]} existing Open5GS image(s):"
    printf '    %s\n' "${PRESENT[@]}"
    echo ""
    echo "Rebuilding removes them and builds again from the current Dockerfiles"
    echo "and binaries (10-15 min). Answer N to keep them and build only the"
    echo "images that are missing."
    echo ""
    if [ -t 0 ]; then
        read -p "Rebuild existing Open5GS images? (y/N) " -r reply
        echo
        [[ $reply =~ ^[Yy]$ ]] && REBUILD_MODE="rebuild" || REBUILD_MODE="keep"
    else
        echo "Non-interactive run — keeping existing images (use --rebuild to force)."
        REBUILD_MODE="keep"
    fi
fi

if [ "$REBUILD_MODE" = "rebuild" ] && [ ${#PRESENT[@]} -gt 0 ]; then
    if ! remove_existing_images; then
        echo ""
        echo "Some images could not be removed. Stop whatever is using them"
        echo "(docker ps -a), then re-run this script."
        exit 1
    fi
    echo "[OK] existing images removed — all images will be rebuilt"
fi

echo "Clearing any leftover build cache before starting..."
docker builder prune -af && echo "[CACHE] cleared"

echo "Pulling fresh ubuntu:jammy base image (ensures up-to-date apt keyring)..."
docker pull ubuntu:jammy

echo "Starting builds..."

build_image() {
    local tag="$1"
    shift
    if image_exists "$tag"; then
        echo "[SKIP] $tag (already exists)"
        return
    fi
    echo "[BUILD] $tag"
    if ! docker build --no-cache -t "$tag" "$@"; then
        echo "[FAILED] $tag"
        FAILED=$((FAILED + 1))
    else
        echo "[OK] $tag"
    fi
    # Prune build cache immediately after each image to prevent disk exhaustion
    docker builder prune -af && echo "[CACHE] pruned after $tag"
}

for entry in "${IMAGES[@]}"; do
    build_image "${entry%%|*}" ${entry#*|}
done

if [ "$FAILED" -eq 0 ]; then
    echo "All builds completed successfully!"
    exit 0
else
    echo "$FAILED build(s) failed."
    exit 1
fi
