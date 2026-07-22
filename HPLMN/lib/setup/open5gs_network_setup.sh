#!/bin/bash

#==============================================================================
# Open5GS Network Setup Script
#==============================================================================
# Configures host networking required for Open5GS UPF in Docker host network
# mode. Auto-detects the main network interface and sets up IP forwarding,
# iptables NAT/FORWARD rules, ogstun interface configuration, and duplicate
# route cleanup. All settings are made persistent via a systemd service.
#
# Usage:
#   sudo ./open5gs_network_setup.sh
#
# What this script does:
#   1. Detects main network interface (default route)
#   2. Enables IPv4/IPv6 forwarding and sets loose RP filter
#   3. Configures iptables NAT (MASQUERADE) for ogstun subnet
#   4. Configures iptables FORWARD rules (ogstun <-> main interface)
#   5. Configures ogstun interface IPs and routes (if UPF has created it)
#   6. Cleans up duplicate Docker bridge routes
#   7. Creates a systemd service for persistence across reboots
#   8. Validates the configuration
#==============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Script version
SCRIPT_VERSION="3.1.0"

# Logging
LOG_DIR="${HOME}/open5gs_setup_logs"
LOG_FILE="${LOG_DIR}/setup_$(date +%Y%m%d_%H%M%S).log"

# Open5GS Standard Configuration
OGSTUN_IP="10.45.0.1"
OGSTUN_SUBNET="10.45.0.0/16"
OGSTUN_IPV6="2001:db8:cafe::1/48"
OGSTUN_IPV6_SUBNET="2001:db8:cafe::/48"

# Docker network subnets (detected automatically)
DOCKER_SUBNETS=()

# Variables to be set during execution
MAIN_IFACE=""
PRIMARY_IP=""

#==============================================================================
# Logging Functions
#==============================================================================
setup_logging() {
    mkdir -p "$LOG_DIR"
    exec 1> >(tee -a "$LOG_FILE")
    exec 2>&1
}

log() { echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }

header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

#==============================================================================
# Parse Command Line Arguments
#==============================================================================
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
}

show_help() {
    cat << EOF
Open5GS Network Setup Script v$SCRIPT_VERSION

Usage: sudo $0 [OPTIONS]

Options:
  --help, -h             Show this help message

Description:
  This script configures the host networking required for the Open5GS testbed.
  The UPF runs in Docker host network mode, so the host needs proper IP
  forwarding, NAT, and routing for UE traffic to reach the internet.

  The script will:
  1. Auto-detect the main network interface (default route)
  2. Enable IPv4/IPv6 forwarding and set loose reverse path filter
  3. Configure iptables NAT (MASQUERADE) for the ogstun subnet (10.45.0.0/16)
  4. Configure iptables FORWARD rules between ogstun and the main interface
  5. Configure the ogstun interface with IPs and routes (if created by UPF)
  6. Clean up duplicate Docker bridge routes
  7. Create a systemd service for persistence across reboots
  8. Validate the final configuration

  The ogstun TUN device is created automatically by the UPF container at
  startup. This script configures the host-side networking around it.

Network Requirements:
  - Docker and Docker Compose must be installed
  - Root/sudo access required

EOF
}

#==============================================================================
# Detect Main Network Interface
#==============================================================================
detect_main_interface() {
    header "Detecting Network Configuration"
    
    # Get main interface (the one with default route)
    MAIN_IFACE=$(ip route show default | awk '{print $5}' | head -1)
    
    if [ -z "$MAIN_IFACE" ]; then
        # No default route, try to find first UP interface (excluding lo)
        MAIN_IFACE=$(ip link show | grep "state UP" | grep -v "lo:" | head -1 | awk '{print $2}' | tr -d ':')
    fi
    
    if [ -z "$MAIN_IFACE" ]; then
        error "Could not determine main network interface"
        error "Please ensure network is configured"
        exit 1
    fi
    
    log "Main interface: $MAIN_IFACE"
    
    # Get primary IP (first non-loopback IP)
    PRIMARY_IP=$(ip addr show "$MAIN_IFACE" | grep "inet " | grep -v "127.0.0.1" | awk '{print $2}' | head -1)
    
    if [ -z "$PRIMARY_IP" ]; then
        warn "No IP address found on $MAIN_IFACE"
        warn "Interface may not be configured yet"
    else
        log "Primary IP: $PRIMARY_IP"
    fi
    
    echo ""
}

#==============================================================================
# Detect Docker Networks
#==============================================================================
detect_docker_networks() {
    log "Detecting Docker networks..."
    
    # Get all Docker bridge networks and their subnets
    if command -v docker &> /dev/null; then
        for net_id in $(docker network ls --filter driver=bridge --format "{{.ID}}" 2>/dev/null); do
            subnet=$(docker network inspect "$net_id" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null)
            if [ -n "$subnet" ] && [ "$subnet" != "172.17.0.0/16" ]; then
                DOCKER_SUBNETS+=("$subnet")
            fi
        done
    fi
    
    if [ ${#DOCKER_SUBNETS[@]} -gt 0 ]; then
        log "Found Docker networks: ${DOCKER_SUBNETS[*]}"
    else
        info "No custom Docker networks found (will be created by docker compose)"
    fi
    
    echo ""
}

#==============================================================================
# System Check
#==============================================================================
check_prerequisites() {
    header "Checking Prerequisites"
    
    local ERRORS=0
    
    if [ "$EUID" -ne 0 ]; then
        error "This script must be run as root or with sudo"
        exit 1
    fi
    
    if command -v docker &> /dev/null; then
        log "✓ Docker installed: $(docker --version | cut -d' ' -f3 | tr -d ',')"
    else
        error "✗ Docker not installed"
        ((ERRORS++))
    fi
    
    if command -v docker compose version &> /dev/null; then
        log "✓ Docker Compose installed"
    else
        warn "⚠ Docker Compose not found (may need to use docker-compose)"
    fi
    
    if ip link show "$MAIN_IFACE" &> /dev/null; then
        log "✓ Main interface exists: $MAIN_IFACE"
    else
        error "✗ Main interface not found: $MAIN_IFACE"
        ((ERRORS++))
    fi
    
    if [ $ERRORS -gt 0 ]; then
        error "Prerequisites check failed with $ERRORS error(s)"
        exit 1
    fi
    
    log "✓ All prerequisites met"
    echo ""
}

#==============================================================================
# Clean Up Stale Configuration
#==============================================================================
cleanup_stale_config() {
    header "Cleaning Up Stale Network Configuration"
    
    log "Checking for duplicate routes..."
    
    # Check all Docker subnets plus ogstun
    local CHECK_SUBNETS=("${DOCKER_SUBNETS[@]}" "$OGSTUN_SUBNET")
    
    for subnet in "${CHECK_SUBNETS[@]}"; do
        ROUTE_COUNT=$(ip route show | grep -c "$subnet" 2>/dev/null || echo "0")
        
        if [ "$ROUTE_COUNT" -gt 1 ]; then
            warn "Found $ROUTE_COUNT routes for $subnet"
            
            ip route show | grep "$subnet" | while read -r route; do
                IFACE=$(echo "$route" | awk '{print $3}')
                STATE=$(ip link show "$IFACE" 2>/dev/null | grep -o "state [A-Z]*" | awk '{print $2}' || echo "UNKNOWN")
                
                if [ "$STATE" = "DOWN" ] || [ "$STATE" = "UNKNOWN" ]; then
                    warn "Removing stale route: $route (interface $IFACE is $STATE)"
                    ip route del "$subnet" dev "$IFACE" 2>/dev/null || true
                fi
            done
        fi
    done
    
    log "Flushing stale ARP entries..."
    ip neigh show | grep -E "FAILED|INCOMPLETE" | while read -r entry; do
        IP=$(echo "$entry" | awk '{print $1}')
        DEV=$(echo "$entry" | awk '{print $3}')
        ip neigh del "$IP" dev "$DEV" 2>/dev/null || true
    done
    
    for bridge in $(ip link show | grep -o "br-[a-z0-9]*" | sort -u); do
        ip neigh flush dev "$bridge" 2>/dev/null || true
    done
    
    log "✓ Cleanup complete"
    echo ""
}

#==============================================================================
# Configure IP Forwarding
#==============================================================================
configure_ip_forwarding() {
    header "Configuring IP Forwarding"
    
    log "Enabling IPv4 forwarding..."
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    
    log "Enabling IPv6 forwarding..."
    sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null
    
    log "Configuring RP filter (loose mode)..."
    sysctl -w net.ipv4.conf.all.rp_filter=2 > /dev/null
    sysctl -w net.ipv4.conf.default.rp_filter=2 > /dev/null
    
    log "Making changes persistent..."
    SYSCTL_CONF="/etc/sysctl.d/99-open5gs.conf"
    cat > "$SYSCTL_CONF" << EOF
# Open5GS Network Configuration
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
EOF
    
    log "✓ IP forwarding configured and persisted to $SYSCTL_CONF"
    echo ""
}

#==============================================================================
# Configure iptables Rules
#==============================================================================
configure_iptables() {
    header "Configuring iptables Rules"
    
    log "Setting FORWARD policy to ACCEPT..."
    iptables -P FORWARD ACCEPT
    ip6tables -P FORWARD ACCEPT
    
    if ip link show ogstun &>/dev/null; then
        log "Configuring FORWARD rules for ogstun..."
        
        if ! iptables -C FORWARD -i "$MAIN_IFACE" -o ogstun -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
            iptables -I FORWARD 1 -i "$MAIN_IFACE" -o ogstun -m state --state RELATED,ESTABLISHED -j ACCEPT
            log "✓ Added FORWARD rule: $MAIN_IFACE → ogstun (ESTABLISHED)"
        fi
        
        if ! iptables -C FORWARD -i ogstun -o "$MAIN_IFACE" -j ACCEPT 2>/dev/null; then
            iptables -I FORWARD 1 -i ogstun -o "$MAIN_IFACE" -j ACCEPT
            log "✓ Added FORWARD rule: ogstun → $MAIN_IFACE"
        fi
    else
        info "ogstun not created yet — FORWARD rules will be added by the persistent service after UPF starts"
    fi
    
    log "Configuring NAT rules for ogstun..."
    
    if ! iptables -t nat -C POSTROUTING -s "$OGSTUN_SUBNET" ! -o ogstun -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -s "$OGSTUN_SUBNET" ! -o ogstun -j MASQUERADE
        log "✓ Added IPv4 NAT rule: MASQUERADE $OGSTUN_SUBNET"
    else
        log "✓ IPv4 NAT rule already exists"
    fi
    
    if ! ip6tables -t nat -C POSTROUTING -s "$OGSTUN_IPV6_SUBNET" ! -o ogstun -j MASQUERADE 2>/dev/null; then
        ip6tables -t nat -A POSTROUTING -s "$OGSTUN_IPV6_SUBNET" ! -o ogstun -j MASQUERADE
        log "✓ Added IPv6 NAT rule: MASQUERADE $OGSTUN_IPV6_SUBNET"
    else
        log "✓ IPv6 NAT rule already exists"
    fi
    
    log "✓ iptables rules configured"
    echo ""
}

#==============================================================================
# Configure ogstun Interface
#==============================================================================
configure_ogstun() {
    header "Configuring ogstun Interface"
    
    if ! ip link show ogstun &>/dev/null; then
        info "ogstun interface not created yet"
        info "It will be created automatically by the UPF container on first start"
        info "The persistent systemd service will configure it when it appears"
        return
    fi
    
    log "ogstun interface exists — configuring..."
    
    ip link set ogstun up 2>/dev/null || true
    
    if ! ip addr show ogstun | grep -q "$OGSTUN_IP/16"; then
        log "Adding IPv4 address: $OGSTUN_IP/16"
        ip addr add "$OGSTUN_IP/16" dev ogstun 2>/dev/null || log "Address already exists"
    else
        log "✓ IPv4 address configured"
    fi
    
    if ! ip addr show ogstun | grep -q "$OGSTUN_IP/32"; then
        ip addr add "$OGSTUN_IP/32" dev ogstun 2>/dev/null || true
    fi
    
    if ! ip addr show ogstun | grep -q "$OGSTUN_IPV6"; then
        log "Adding IPv6 address: $OGSTUN_IPV6"
        ip addr add "$OGSTUN_IPV6" dev ogstun 2>/dev/null || log "Address already exists"
    else
        log "✓ IPv6 address configured"
    fi
    
    if ! ip route show | grep -q "$OGSTUN_SUBNET dev ogstun"; then
        log "Adding route: $OGSTUN_SUBNET dev ogstun"
        ip route add "$OGSTUN_SUBNET" dev ogstun 2>/dev/null || log "Route already exists"
    else
        log "✓ IPv4 route configured"
    fi
    
    if ! ip -6 route show | grep -q "$OGSTUN_IPV6_SUBNET dev ogstun"; then
        log "Adding IPv6 route: $OGSTUN_IPV6_SUBNET dev ogstun"
        ip -6 route add "$OGSTUN_IPV6_SUBNET" dev ogstun 2>/dev/null || log "Route already exists"
    else
        log "✓ IPv6 route configured"
    fi
    
    log "✓ ogstun interface configured"
    echo ""
}

#==============================================================================
# Make Configuration Persistent
#==============================================================================
make_persistent() {
    header "Making Network Configuration Persistent"
    
    SERVICE_FILE="/etc/systemd/system/open5gs-network-setup.service"
    CONFIG_SCRIPT="/usr/local/bin/configure-open5gs-network.sh"
    
    log "Creating systemd service: $SERVICE_FILE"
    
    cat > "$SERVICE_FILE" << 'EOF'
[Unit]
Description=Open5GS Network Configuration
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/configure-open5gs-network.sh

[Install]
WantedBy=multi-user.target
EOF
    
    log "Creating configuration script: $CONFIG_SCRIPT"
    
    cat > "$CONFIG_SCRIPT" << EOF
#!/bin/bash
# Auto-generated Open5GS network configuration script
# Generated on: $(date)

# Get main interface
MAIN_IFACE=\$(ip route show default | awk '{print \$5}' | head -1)
if [ -z "\$MAIN_IFACE" ]; then
    MAIN_IFACE=\$(ip link show | grep "state UP" | grep -v "lo:" | head -1 | awk '{print \$2}' | tr -d ':')
fi

# Configure sysctl
sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null 2>&1
sysctl -w net.ipv4.conf.all.rp_filter=2 > /dev/null 2>&1
sysctl -w net.ipv4.conf.default.rp_filter=2 > /dev/null 2>&1

# Set FORWARD policy
iptables -P FORWARD ACCEPT 2>/dev/null || true
ip6tables -P FORWARD ACCEPT 2>/dev/null || true

# Add NAT rules
iptables -t nat -A POSTROUTING -s $OGSTUN_SUBNET ! -o ogstun -j MASQUERADE 2>/dev/null || true
ip6tables -t nat -A POSTROUTING -s $OGSTUN_IPV6_SUBNET ! -o ogstun -j MASQUERADE 2>/dev/null || true

# Wait for ogstun to be created (max 30 seconds)
for i in {1..30}; do
    if ip link show ogstun &>/dev/null; then
        break
    fi
    sleep 1
done

# Configure ogstun if it exists
if ip link show ogstun &>/dev/null; then
    ip link set ogstun up
    ip addr add $OGSTUN_IP/16 dev ogstun 2>/dev/null || true
    ip addr add $OGSTUN_IP/32 dev ogstun 2>/dev/null || true
    ip addr add $OGSTUN_IPV6 dev ogstun 2>/dev/null || true
    ip route add $OGSTUN_SUBNET dev ogstun 2>/dev/null || true
    ip -6 route add $OGSTUN_IPV6_SUBNET dev ogstun 2>/dev/null || true
    
    # Add iptables rules
    iptables -t nat -A POSTROUTING -s $OGSTUN_SUBNET ! -o ogstun -j MASQUERADE 2>/dev/null || true
    ip6tables -t nat -A POSTROUTING -s $OGSTUN_IPV6_SUBNET ! -o ogstun -j MASQUERADE 2>/dev/null || true
    
    if [ -n "\$MAIN_IFACE" ]; then
        iptables -I FORWARD 1 -i ogstun -o "\$MAIN_IFACE" -j ACCEPT 2>/dev/null || true
        iptables -I FORWARD 1 -i "\$MAIN_IFACE" -o ogstun -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    fi
fi
EOF
    
    chmod +x "$CONFIG_SCRIPT"
    
    systemctl daemon-reload
    systemctl enable open5gs-network-setup.service
    
    log "✓ Persistent configuration created"
    info "Network configuration will be restored automatically on reboot"
    echo ""
}

#==============================================================================
# Post-Configuration Cleanup
#==============================================================================
post_config_cleanup() {
    header "Post-Configuration Cleanup"
    
    sleep 2
    
    log "Checking for duplicate routes..."
    
    # Re-detect Docker networks
    detect_docker_networks
    
    local CHECK_SUBNETS=("${DOCKER_SUBNETS[@]}")
    
    for subnet in "${CHECK_SUBNETS[@]}"; do
        ROUTE_COUNT=$(ip route show | grep -c "$subnet" 2>/dev/null || echo "0")
        
        if [ "$ROUTE_COUNT" -gt 1 ]; then
            warn "Found duplicate routes for $subnet"
            
            ip route show | grep "$subnet" | while read -r route; do
                IFACE=$(echo "$route" | awk '{print $3}')
                STATE=$(ip link show "$IFACE" 2>/dev/null | grep -o "state [A-Z]*" | awk '{print $2}' || echo "UNKNOWN")
                
                if [ "$STATE" = "DOWN" ]; then
                    warn "Removing duplicate route: $route"
                    ip route del "$subnet" dev "$IFACE" 2>/dev/null || true
                fi
            done
        fi
    done
    
    log "✓ Post-configuration cleanup complete"
    echo ""
}

#==============================================================================
# Validation
#==============================================================================
validate_configuration() {
    header "Validating Configuration"
    
    local ERRORS=0
    local WARNINGS=0
    
    # Check IP forwarding
    if [ "$(sysctl -n net.ipv4.ip_forward)" = "1" ]; then
        log "✓ IPv4 forwarding enabled"
    else
        error "✗ IPv4 forwarding disabled"
        ((ERRORS++))
    fi
    
    if [ "$(sysctl -n net.ipv6.conf.all.forwarding)" = "1" ]; then
        log "✓ IPv6 forwarding enabled"
    else
        warn "⚠ IPv6 forwarding disabled"
        ((WARNINGS++))
    fi
    
    # Check gateway reachability
    if [ -n "$PRIMARY_IP" ]; then
        GW=$(ip route show default | awk '{print $3}' | head -1)
        if [ -n "$GW" ] && ping -c 2 -W 2 "$GW" &>/dev/null; then
            log "✓ Can reach default gateway at $GW"
        else
            warn "⚠ Cannot reach default gateway"
            ((WARNINGS++))
        fi
    fi
    
    # Check NAT rule
    if iptables -t nat -L POSTROUTING -n | grep -q "$OGSTUN_SUBNET"; then
        log "✓ NAT rule for ogstun configured"
    else
        error "✗ NAT rule for ogstun missing"
        ((ERRORS++))
    fi
    
    # Check for duplicate routes
    local has_duplicates=0
    for subnet in "${DOCKER_SUBNETS[@]}"; do
        ROUTE_COUNT=$(ip route show | grep -c "$subnet" 2>/dev/null || echo "0")
        if [ "$ROUTE_COUNT" -gt 1 ]; then
            has_duplicates=1
            break
        fi
    done
    
    if [ $has_duplicates -eq 0 ]; then
        log "✓ No duplicate routes found"
    else
        warn "⚠ Duplicate routes still exist"
        ((WARNINGS++))
    fi
    
    # Check ogstun
    if ip link show ogstun &>/dev/null; then
        log "✓ ogstun interface exists"
        
        if ip addr show ogstun | grep -q "$OGSTUN_IP"; then
            log "✓ ogstun has correct IP address"
        else
            warn "⚠ ogstun IP address needs configuration"
            ((WARNINGS++))
        fi
    else
        info "ℹ ogstun not created yet (normal if UPF not running)"
    fi
    
    # Check persistent service
    if systemctl is-enabled open5gs-network-setup.service &>/dev/null; then
        log "✓ Persistent systemd service enabled"
    else
        warn "⚠ Persistent systemd service not enabled"
        ((WARNINGS++))
    fi
    
    echo ""
    
    if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
        log "${GREEN}✓✓✓ All validation checks passed! ✓✓✓${NC}"
    elif [ $ERRORS -eq 0 ]; then
        warn "⚠ Validation completed with $WARNINGS warning(s)"
    else
        error "✗ Validation failed with $ERRORS error(s) and $WARNINGS warning(s)"
    fi
    
    echo ""
}

#==============================================================================
# Display Summary
#==============================================================================
display_summary() {
    header "Configuration Summary"
    
    echo "Network Configuration:"
    echo "====================="
    echo "Main Interface:         $MAIN_IFACE"
    echo "Primary IP:             ${PRIMARY_IP:-Not configured}"
    echo ""
    
    echo "Open5GS ogstun Configuration:"
    echo "=============================="
    echo "ogstun IP:              $OGSTUN_IP/16"
    echo "ogstun Subnet:          $OGSTUN_SUBNET"
    echo "ogstun IPv6:            $OGSTUN_IPV6"
    echo ""
    
    if [ ${#DOCKER_SUBNETS[@]} -gt 0 ]; then
        echo "Docker Networks Detected:"
        echo "========================="
        for subnet in "${DOCKER_SUBNETS[@]}"; do
            echo "  - $subnet"
        done
        echo ""
    fi
    
    echo "Current Status:"
    echo "==============="
    echo ""
    echo "Interface $MAIN_IFACE:"
    ip addr show "$MAIN_IFACE" 2>/dev/null | grep -E "inet |state" || echo "  Not found"
    echo ""
    
    if ip link show ogstun &>/dev/null; then
        echo "ogstun Interface:"
        ip addr show ogstun | grep -E "inet |state"
        echo ""
    else
        echo "ogstun: Not created yet (will be created by UPF on startup)"
        echo ""
    fi
    
    echo "NAT Rules for ogstun:"
    iptables -t nat -L POSTROUTING -n -v 2>/dev/null | grep -E "Chain|$OGSTUN_IP" | head -5 || echo "  None configured"
    echo ""
    
    echo "Sysctl settings:"
    echo "  net.ipv4.ip_forward = $(sysctl -n net.ipv4.ip_forward)"
    echo "  net.ipv6.conf.all.forwarding = $(sysctl -n net.ipv6.conf.all.forwarding)"
    echo "  net.ipv4.conf.all.rp_filter = $(sysctl -n net.ipv4.conf.all.rp_filter)"
    echo ""
    
    echo "Log file: $LOG_FILE"
    echo ""
}

#==============================================================================
# Main Execution
#==============================================================================
main() {
    setup_logging
    
    header "Open5GS Network Setup v$SCRIPT_VERSION"
    log "Starting setup at $(date)"
    log "Hostname: $(hostname)"
    echo ""
    
    parse_arguments "$@"
    detect_main_interface
    detect_docker_networks
    check_prerequisites
    cleanup_stale_config
    configure_ip_forwarding
    configure_iptables
    configure_ogstun
    make_persistent
    post_config_cleanup
    validate_configuration
    display_summary
    
    header "Setup Complete!"
    log "${GREEN}Network configuration completed successfully!${NC}"
    echo ""
    echo "Next Steps:"
    echo "==========="
    echo "1. Start your testbed:"
    echo "   docker compose up"
    echo ""
    echo "2. Configuration will persist across reboots"
    echo ""
    echo "3. To reconfigure, run this script again"
    echo "   Use --help for usage information"
    echo ""
}

main "$@"