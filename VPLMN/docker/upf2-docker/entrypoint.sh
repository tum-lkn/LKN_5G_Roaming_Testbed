#!/bin/bash

# Source helper functions
source "/usr/local/bin/helper_functions.sh"

# Setup container interfaces based on config file provided in Docker CMD
setup_container_interfaces "${@}"

# Wait for eth0 to be ready
#while ! ip link show eth0 > /dev/null 2>&1; do
#    echo "Waiting for eth0 to be ready..."
#    sleep 1
#done

# Apply artificial network delay to eth0
#echo "Applying 100ms network delay with ±20ms jitter..."
#tc qdisc add dev eth0 root netem delay 100ms 20ms

# Start the UPF process
exec open5gs-upfd "${@}"
