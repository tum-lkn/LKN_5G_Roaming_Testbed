#!/bin/bash

# NRF entrypoint

# Update /etc/hosts with necessary mappings
echo '192.168.60.189 nrf.5gc.mnc001.mcc001.3gppnetwork.org' >> /etc/hosts
echo '192.168.60.191 ausf.5gc.mnc001.mcc001.3gppnetwork.org' >> /etc/hosts
echo '192.168.60.192 udm.5gc.mnc001.mcc001.3gppnetwork.org' >> /etc/hosts


# Container entrypoint receiving arguments from Docker CMD
exec open5gs-ausfd "${@}"
