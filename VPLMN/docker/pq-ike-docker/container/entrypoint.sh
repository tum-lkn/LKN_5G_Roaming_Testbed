#!/bin/bash
# ============================================================================
# Container entrypoint.
# The charon IKE daemon is intentionally NOT started here -- it is started
# and stopped once per test iteration by the host-side orchestrator
# (ike_eval_docker.sh) through `docker exec`, mirroring the original
# systemctl start/stop behaviour of the VM testbed.
# ============================================================================
set -e

# standard swanctl credential directories (silences --load-creds warnings)
mkdir -p /etc/swanctl/{x509,x509ca,x509aa,x509ac,x509crl,x509ocsp,pubkey,private,rsa,ecdsa,pkcs8,pkcs12} \
         /var/log/strongswan \
         /results/{pcaps,json,logs} 2>/dev/null || true

# an empty-but-valid config so `swanctl --load-all` works before the first
# scenario has been written by the orchestrator
if [ ! -f /etc/swanctl/swanctl.conf ]; then
    echo "# placeholder - overwritten per scenario by ike_eval_docker.sh" \
        > /etc/swanctl/swanctl.conf
fi

exec "$@"
