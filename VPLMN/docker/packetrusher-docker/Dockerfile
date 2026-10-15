# Builds the testbed's PacketRusher image from upstream HewlettPackard/PacketRusher
# source (>= 20250225 snapshot, which includes PR #135 — uplink GTP-U QFI /
# PDU Session Container). This REPLACES the old ghcr.io/borjis131/packetrusher:main
# fork image, which predated PR #135 and sent QFI-less uplink G-PDUs that the
# stock Open5GS v2.8.0 UPF rejects (strict QFI PDR match -> Error Indication ->
# 100% uplink loss). See build_packetrusher.sh and the migration HANDOFF.
#
# Interface is kept byte-compatible with the old fork image so existing
# `docker run … --config /PacketRusher/config/config.yml ue` invocations are
# unchanged:  ENTRYPOINT /PacketRusher/packetrusher · WORKDIR /PacketRusher ·
# config at /PacketRusher/config/config.yml.
#
# gtp5g is a HOST kernel module (0.9.3, which already supports the QFI QER) —
# it is NOT built here. Build context = the PacketRusher source tree.

#---------------------------------------------------------------------
# BUILDER  (Go 1.24.1 — go.mod on this source requires go >= 1.23.0, so the
#           stock upstream docker/Dockerfile's Go 1.21.3 will NOT compile it)
#---------------------------------------------------------------------
ARG BASE_IMAGE=ubuntu:jammy
FROM $BASE_IMAGE AS builder

ARG GO_VERSION=1.24.1
RUN apt-get update && apt-get install -y --no-install-recommends wget ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN wget -q https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz \
    && tar -C /usr/local -xzf go${GO_VERSION}.linux-amd64.tar.gz \
    && rm go${GO_VERSION}.linux-amd64.tar.gz
ENV GOROOT=/usr/local/go
ENV GOPATH=/goproject
ENV PATH=$GOPATH/bin:$GOROOT/bin:$PATH

COPY . /packetrusher
RUN cd /packetrusher \
    && go mod download \
    && cd cmd && go build -o app

#---------------------------------------------------------------------
# RUNTIME  (no Go toolchain — the entrypoint only runs the compiled binary)
#---------------------------------------------------------------------
ARG BASE_IMAGE=ubuntu:jammy
FROM $BASE_IMAGE AS packetrusher

# iproute2 (ip/vrf), iputils-ping, iperf3, and curl/wget for the UE data-plane
# tests. curl in particular is required by the testbed's download test (WebUI
# and automation run `curl` inside the UE's VRF); the old fork image shipped it.
RUN apt-get update && apt-get install -y --no-install-recommends \
        iproute2 iputils-ping iperf3 curl wget ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /PacketRusher
COPY --from=builder /packetrusher/cmd/app            /PacketRusher/packetrusher
COPY --from=builder /packetrusher/config/config.yml  /PacketRusher/config/config.yml

ENTRYPOINT ["/PacketRusher/packetrusher"]
CMD ["--config", "/PacketRusher/config/config.yml", "ue"]
