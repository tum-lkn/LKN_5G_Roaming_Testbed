#!/bin/bash

# AMF entrypoint

# Update /etc/hosts with necessary mappings
echo '192.168.50.189 nrf.5gc.mnc071.mcc999.3gppnetwork.org' >> /etc/hosts
echo '192.168.50.191 ausf.5gc.mnc071.mcc999.3gppnetwork.org' >> /etc/hosts
echo '192.168.50.192 udm.5gc.mnc071.mcc999.3gppnetwork.org' >> /etc/hosts

# Disable checksum offloading if specified
if [[ "${DISABLE_CHECKSUM_OFFLOADING}" == "TRUE" ]]; then
    ethtool -K eth0 rx off tx off
fi

# Check if the first argument is "debug"
if [ "$1" == "debug" ]; then
    # Run the AMF binary in gdb for debugging
    gdb /usr/local/bin/open5gs-amfd \
        -ex "set substitute-path ../src /usr/local/src" \
        -ex "break main" \
        -ex "run -c /etc/open5gs/default/amf.yaml"
else
    # Container entrypoint receiving arguments from Docker CMD
    exec /usr/local/bin/open5gs-amfd "${@}"
fi

# Keep the container running
exec /bin/bash
