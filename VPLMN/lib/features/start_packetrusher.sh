#!/usr/bin/env bash

set -e

CONFIG_DIR=~/LKN_5G_Roaming_Testbed/VPLMN/configs/Packetrusher_Configs

cleanup_gtp5g_state() {
    echo "Cleaning stale PacketRusher GTP state..."

    while IFS= read -r iface; do
        case "$iface" in
            val[0-9]*|vrf[0-9]*)
                sudo ip link delete "$iface" 2>/dev/null || true
                ;;
        esac
    done < <(ip -o link show | awk -F': ' '{print $2}' | cut -d'@' -f1)

    # Give Docker a moment to release the container network namespace, then
    # reload gtp5g to clear per-run TEID/FAR/PDR state held by the module.
    sleep 1
    sudo rmmod gtp5g 2>/dev/null || sudo rmmod -f gtp5g 2>/dev/null || true
    sudo modprobe gtp5g
}

echo "======================================="
echo " Select PacketRusher Roaming Mode"
echo "======================================="
echo "  1) Home Routed (HR)"
echo "  2) Local Breakout (LBO)"
echo "  3) Non-Roaming"
read -rp "Enter choice [1-3]: " CHOICE

case "$CHOICE" in
  1)
    CONFIG_FILE="config_hr_roaming.yml"
    IP_ADDR="192.168.70.190"
    ;;
  2)
    CONFIG_FILE="config_lbo_roaming.yml"
    IP_ADDR="192.168.70.190"
    ;;
  3)
    CONFIG_FILE="config_non_roaming.yml"
    IP_ADDR="192.168.70.190"
    ;;
  *)
    echo "❌ Invalid choice!"
    exit 1
    ;;
esac

echo
echo "Using config file: $CONFIG_FILE"
echo "Using container name: packetrusher"
echo "Using IP: $IP_ADDR"
echo

# Stop & remove old container if it exists
if sudo docker ps -a --format '{{.Names}}' | grep -q "^packetrusher$"; then
    echo "🛑 Removing existing packetrusher container..."
    sudo docker rm -f packetrusher
fi

cleanup_gtp5g_state

echo "🚀 Starting PacketRusher..."
sudo docker run --privileged --cap-add=ALL \
    --net my_second_network \
    --ip $IP_ADDR \
    --name packetrusher \
    -v $CONFIG_DIR/$CONFIG_FILE:/PacketRusher/config/config.yml \
    -it ghcr.io/borjis131/packetrusher:main \
    --config /PacketRusher/config/config.yml ue
