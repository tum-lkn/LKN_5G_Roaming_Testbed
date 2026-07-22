#!/bin/bash

# AMF entrypoint

# Update /etc/hosts with necessary mappings
echo '192.168.60.189 nrf.5gc.mnc001.mcc001.3gppnetwork.org' >> /etc/hosts
echo '192.168.60.191 ausf.5gc.mnc001.mcc001.3gppnetwork.org' >> /etc/hosts
echo '192.168.60.192 udm.5gc.mnc001.mcc001.3gppnetwork.org' >> /etc/hosts

# Disable checksum offloading if specified
if [[ "${DISABLE_CHECKSUM_OFFLOADING}" == "TRUE" ]]; then
    ethtool -K eth0 rx off tx off
fi

# Container entrypoint receiving arguments from Docker CMD
exec open5gs-amfd "${@}"
