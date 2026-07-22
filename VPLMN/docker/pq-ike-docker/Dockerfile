# syntax=docker/dockerfile:1
# ============================================================================
# strongSwan with post-quantum ML-KEM (FIPS 203) + ML-DSA (FIPS 204)
#
# Base image : Debian 13 "trixie"  -> ships OpenSSL 3.5.x, which provides
#              native ML-KEM and ML-DSA to strongSwan's `openssl` plugin.
# Source     : official strongSwan git, branch "ml-dsa" (default).
#
#   * ML-KEM key exchange is part of every 6.0.x release
#     (via OpenSSL 3.5+ since 6.0.2, plus the built-in `ml` plugin).
#   * ML-DSA certificates / IKEv2 authentication are NOT in any 6.0.x
#     release -- they live in the upstream "ml-dsa" branch (planned for
#     6.1.0). A build of that branch reports itself as 6.0.x, which is
#     why a "6.0.4 with ML-DSA" testbed is a branch build.
#
#   To build a plain release instead (scenarios 1+2 only, no ML-DSA):
#       SWAN_REF=6.0.4 docker compose build
# ============================================================================

# ---------------------------------------------------------------- build stage
FROM debian:trixie-slim AS build

ARG SWAN_REF=ml-dsa
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates build-essential \
        automake autoconf autopoint libtool pkg-config \
        gettext gperf flex bison \
        libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth 1 --branch "${SWAN_REF}" \
        https://github.com/strongswan/strongswan.git

WORKDIR /src/strongswan
RUN ./autogen.sh && \
    ./configure \
        --prefix=/usr \
        --sysconfdir=/etc \
        --enable-openssl \
        --enable-ml \
        --enable-vici \
        --enable-swanctl \
        --enable-pki \
        --enable-kernel-netlink \
        --enable-socket-default \
        --enable-pem --enable-pkcs1 --enable-pkcs8 \
        --enable-x509 --enable-pubkey \
        --enable-constraints --enable-revocation \
        --enable-nonce --enable-random --enable-drbg \
        --disable-systemd && \
    make -j"$(nproc)" && \
    make install DESTDIR=/out

# -------------------------------------------------------------- runtime stage
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# tshark: pre-answer the setuid debconf question (we run as root anyway)
RUN echo 'wireshark-common wireshark-common/install-setuid boolean false' \
        | debconf-set-selections && \
    apt-get update && apt-get install -y --no-install-recommends \
        openssl netbase \
        iproute2 iputils-ping procps \
        tcpdump tshark \
        bash \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/ /

COPY container/strongswan.conf      /etc/strongswan.conf
COPY container/entrypoint.sh        /entrypoint.sh
COPY container/swan-start           /usr/local/bin/swan-start
COPY container/swan-stop            /usr/local/bin/swan-stop
COPY container/swan-run-initiator   /usr/local/bin/swan-run-initiator
COPY container/gen-certs            /usr/local/bin/gen-certs

RUN chmod +x /entrypoint.sh /usr/local/bin/swan-* /usr/local/bin/gen-certs && \
    mkdir -p /etc/swanctl /var/log/strongswan && \
    echo "--- build smoke test ---" && \
    openssl version && \
    pki --help 2>&1 | head -1 && \
    if pki --gen --type mldsa65 > /dev/null 2>&1; then \
        echo "ML-DSA support : OK (PQ-auth scenarios 3+4 available)"; \
    else \
        echo "ML-DSA support : NOT available (scenarios 3+4 will be skipped)"; \
    fi

ENTRYPOINT ["/entrypoint.sh"]
CMD ["sleep", "infinity"]
