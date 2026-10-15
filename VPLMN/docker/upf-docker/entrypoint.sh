#!/bin/bash

# UPF entrypoint

# source helper functions
source "helper_functions.sh"

# "${@}" contains the CMD provided by Docker

# setup container interfaces based on config file provided in Docker CMD
setup_container_interfaces "${@}"

# Fix: Remove duplicate route that causes ARP failure to PacketRusher
# This prevents Layer 2 reachability issues in HR Roaming scenarios
echo "Checking for duplicate route on corenet interface..."
if ip route show | grep -q "192.168.70.0/24 dev corenet"; then
    echo "Removing duplicate route: 192.168.70.0/24 dev corenet"
    ip route del 192.168.70.0/24 dev corenet 2>/dev/null || true
    echo "Route removed successfully"
else
    echo "No duplicate route found, skipping"
fi

# Verify remaining routes
echo "Current routes for 192.168.70.0/24:"
ip route show | grep "192.168.70.0/24" || echo "No routes found"

# container entrypoint receiving arguments from Docker CMD
open5gs-upfd "${@}"