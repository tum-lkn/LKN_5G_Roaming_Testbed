#!/bin/bash
# lib/automation/delays.sh
# Delay format validators, tc netem command builders, all tc delay injection
# (UPF gtpu/pfcp/n6/n3/ipsec, SEPP n32/eth0, SMF pfcp/eth0), N6 merged delay,
# removal, and reapply-after-restart.

# Defensive defaults: an unset constant would otherwise expand to an empty tc
# argument (e.g. "match ip dport  0xffff") and fail confusingly at runtime.
: "${GTPU_PORT:=2152}"
: "${ESP_PROTOCOL:=50}"
: "${IPSEC_NAT_T_PORT:=4500}"

validate_delay_format() {
    local delay=$1
    # Check for delay with optional jitter
    if [[ "$delay" =~ ^[0-9]+(\.[0-9]+)?(ms|s)(:[0-9]+(\.[0-9]+)?(ms|s))?$ ]]; then
        return 0
    fi
    return 1
}

# Parse delay value into delay and jitter components
parse_delay_value() {
    local value=$1
    local -n delay_ref=$2
    local -n jitter_ref=$3
    
    if [[ "$value" =~ ^([^:]+):(.+)$ ]]; then
        delay_ref="${BASH_REMATCH[1]}"
        jitter_ref="${BASH_REMATCH[2]}"
    else
        delay_ref="$value"
        jitter_ref=""
    fi
}

# Build tc netem delay command with optional jitter
build_netem_delay_cmd() {
    local delay=$1
    local jitter=$2
    
    if [ -n "$jitter" ]; then
        echo "netem delay $delay $jitter"
    else
        echo "netem delay $delay"
    fi
}

is_host_network_service() {
    local service=$1
    for s in "${HOST_NETWORK_SERVICES[@]}"; do
        [ "$s" = "$service" ] && return 0
    done
    return 1
}

is_port_delay_service() {
    local service=$1
    for s in "${PORT_DELAY_SERVICES[@]}"; do
        [ "$s" = "$service" ] && return 0
    done
    return 1
}

show_delay_config_summary() {
    echo
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║          Delay Configuration Summary                          ║"
    echo "╠═══════════════════════════════════════════════════════════════╣"
    if [ "$DELAY_ENABLED" != "true" ]; then
        echo "║  Delays DISABLED (DELAY_ENABLED=false)                       ║"
    elif [ ${#DELAY_CONFIGS[@]} -eq 0 ]; then
        echo "║  No delay rules configured                                    ║"
    else
        for key in "${!DELAY_CONFIGS[@]}"; do
            IFS=':' read -r location service mode <<< "$key"
            local delay_value="${DELAY_CONFIGS[$key]}"
            local loc_display="LOCAL"
            [ "$location" = "remote" ] && loc_display="HPLMN"
            
            # Parse delay and jitter
            local delay_part jitter_part
            parse_delay_value "$delay_value" delay_part jitter_part
            
            if [ -n "$jitter_part" ]; then
                printf "║  %-7s %-15s %-8s = %-6s ±%-5s ║\n" "[$loc_display]" "$service" "($mode)" "$delay_part" "$jitter_part"
            else
                printf "║  %-7s %-15s %-8s = %-10s ║\n" "[$loc_display]" "$service" "($mode)" "$delay_part"
            fi
        done
    fi
    echo "╚═══════════════════════════════════════════════════════════════╝"
}

# Apply tc delay with jitter support on host interface
# PATCHED: explicit error reporting, NAT-T support, post-install verification
apply_tc_delay() {
    local interface=$1 delay_value=$2 location=$3 mode=$4

    # Parse delay and jitter
    local delay jitter
    parse_delay_value "$delay_value" delay jitter
    local netem_cmd
    netem_cmd=$(build_netem_delay_cmd "$delay" "$jitter")

    local jitter_info=""
    [ -n "$jitter" ] && jitter_info=" (jitter: $jitter)"

    # Build an array of tc commands per mode (instead of one big eval string).
    # Each element is a complete, runnable command.
    local -a tc_cmds=()

    # Always start by clearing any existing root qdisc (failure here is OK)
    tc_cmds+=("sudo tc qdisc del dev $interface root 2>/dev/null || true")

    case "$mode" in
        "gtpu")
            # Delay the N9 user plane, whether or not IPsec is up. With IPsec off,
            # GTP-U is on the wire as udp/2152. With IPsec on, it is encapsulated in
            # ESP and the port is no longer visible, so a udp/2152 filter silently
            # matches nothing. Both filter sets share the same netem band: they are
            # mutually exclusive (plaintext 2152 xor ESP), so a packet is classified
            # once and delayed once, measurement-identical in both modes. The N9 SA
            # is scoped to udp/2152, so ESP here carries GTP-U and nothing else. IKE
            # (udp/500) is deliberately not matched — it is tunnel management, not
            # user plane, and delaying it would skew rekeying.
            tc_cmds+=("sudo tc qdisc add dev $interface root handle 1: prio")
            tc_cmds+=("sudo tc qdisc add dev $interface parent 1:3 handle 30: $netem_cmd")
            tc_cmds+=("sudo tc filter add dev $interface protocol ip parent 1:0 prio 1 u32 match ip dport $GTPU_PORT 0xffff flowid 1:3")
            tc_cmds+=("sudo tc filter add dev $interface protocol ip parent 1:0 prio 1 u32 match ip sport $GTPU_PORT 0xffff flowid 1:3")
            tc_cmds+=("sudo tc filter add dev $interface protocol ip parent 1:0 prio 2 u32 match ip protocol $ESP_PROTOCOL 0xff flowid 1:3")
            tc_cmds+=("sudo tc filter add dev $interface protocol ip parent 1:0 prio 3 u32 match ip protocol 17 0xff match ip dport $IPSEC_NAT_T_PORT 0xffff flowid 1:3")
            tc_cmds+=("sudo tc filter add dev $interface protocol ip parent 1:0 prio 3 u32 match ip protocol 17 0xff match ip sport $IPSEC_NAT_T_PORT 0xffff flowid 1:3")
            ;;
        "ipsec")
            # Match ESP (proto 50) AND NAT-T (UDP/4500) — covers both encapsulation modes
            tc_cmds+=("sudo tc qdisc add dev $interface root handle 1: prio")
            tc_cmds+=("sudo tc qdisc add dev $interface parent 1:3 handle 30: $netem_cmd")
            tc_cmds+=("sudo tc filter add dev $interface protocol ip parent 1:0 prio 1 u32 match ip protocol $ESP_PROTOCOL 0xff flowid 1:3")
            tc_cmds+=("sudo tc filter add dev $interface protocol ip parent 1:0 prio 2 u32 match ip dport $IPSEC_NAT_T_PORT 0xffff flowid 1:3")
            tc_cmds+=("sudo tc filter add dev $interface protocol ip parent 1:0 prio 2 u32 match ip sport $IPSEC_NAT_T_PORT 0xffff flowid 1:3")
            ;;
        "pfcp")
            tc_cmds+=("sudo tc qdisc add dev $interface root handle 1: prio")
            tc_cmds+=("sudo tc qdisc add dev $interface parent 1:3 handle 30: $netem_cmd")
            tc_cmds+=("sudo tc filter add dev $interface protocol ip parent 1:0 prio 1 u32 match ip dport $PFCP_PORT 0xffff flowid 1:3")
            tc_cmds+=("sudo tc filter add dev $interface protocol ip parent 1:0 prio 1 u32 match ip sport $PFCP_PORT 0xffff flowid 1:3")
            ;;
        "full")
            tc_cmds+=("sudo tc qdisc add dev $interface root $netem_cmd")
            ;;
        *)
            log "   ❌ Unknown tc delay mode: $mode"
            return 1
            ;;
    esac

    # Helper that runs each command and reports failure with the exact command.
    # IMPORTANT: temporarily disable `set -e` so a single failure doesn't kill the script.
    local _run_one
    _run_one() {
        local target_loc=$1 cmd=$2
        local out rc
        if [ "$target_loc" = "local" ]; then
            set +e
            out=$(eval "$cmd" 2>&1)
            rc=$?
            set -e
        else
            set +e
            out=$(ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE \
                "$REMOTE_PC_USER@$HPLMN_IP" "$cmd" 2>&1)
            rc=$?
            set -e
        fi
        if [ $rc -ne 0 ]; then
            log "   ❌ tc command failed (rc=$rc): $cmd"
            [ -n "$out" ] && log "      → $out"
            return $rc
        fi
        return 0
    }

    # Run each command. Skip the optimistic "del" failure (handled by `|| true` inline).
    local failed_step=0
    local i=0
    for cmd in "${tc_cmds[@]}"; do
        i=$((i + 1))
        if ! _run_one "$location" "$cmd"; then
            failed_step=$i
            break
        fi
    done

    if [ $failed_step -ne 0 ]; then
        log "   ❌ Failed at step $failed_step of ${#tc_cmds[@]} on $location ($interface, mode=$mode)"
        return 1
    fi

    # Post-install verification: confirm the qdisc actually exists.
    local verify_cmd="sudo tc qdisc show dev $interface | grep -q 'qdisc netem'"
    if [ "$mode" = "full" ]; then
        verify_cmd="sudo tc qdisc show dev $interface | grep -q 'netem'"
    fi
    set +e
    if [ "$location" = "local" ]; then
        eval "$verify_cmd"
    else
        ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE \
            "$REMOTE_PC_USER@$HPLMN_IP" "$verify_cmd"
    fi
    local verify_rc=$?
    set -e

    if [ $verify_rc -ne 0 ]; then
        log "   ❌ Verification failed: netem qdisc not present on $interface ($location) after install"
        log "      → tc qdisc show output:"
        if [ "$location" = "local" ]; then
            sudo tc qdisc show dev "$interface" 2>&1 | while IFS= read -r line; do log "        $line"; done
        else
            ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE \
                "$REMOTE_PC_USER@$HPLMN_IP" "sudo tc qdisc show dev $interface" 2>&1 | \
                while IFS= read -r line; do log "        $line"; done
        fi
        return 1
    fi

    APPLIED_DELAYS+=("$location:host:$interface:$mode")
    local loc_label="$location"
    [ "$location" = "remote" ] && loc_label="remote (HPLMN)"
    log "   ✅ Applied $mode delay ($delay$jitter_info) to $interface on $loc_label [verified]"
    return 0
}

# Apply delay to container's eth0 interface with jitter support
apply_container_eth0_delay() {
    local container=$1 delay_value=$2 location=$3
    
    # Parse delay and jitter
    local delay jitter
    parse_delay_value "$delay_value" delay jitter
    local netem_cmd=$(build_netem_delay_cmd "$delay" "$jitter")
    
    local cmd="docker exec $container sh -c 'tc qdisc del dev eth0 root 2>/dev/null || true; tc qdisc add dev eth0 root $netem_cmd'"
    
    local jitter_info=""
    [ -n "$jitter" ] && jitter_info=" (jitter: $jitter)"
    
    if [ "$location" = "local" ]; then
        eval "sudo $cmd" 2>/dev/null && APPLIED_DELAYS+=("$location:container:$container:eth0") && log "   ✅ Applied delay ($delay$jitter_info) to $container eth0"
    else
        ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE \
            "$REMOTE_PC_USER@$HPLMN_IP" "sudo $cmd" 2>/dev/null && \
            APPLIED_DELAYS+=("$location:container:$container:eth0") && \
            log "   ✅ Applied delay ($delay$jitter_info) to $container eth0 (HPLMN)"
    fi
}

# Apply port-specific delay inside container (NEW in v3.0.0)
apply_container_port_delay() {
    local container=$1 delay_value=$2 location=$3 port1=$4 port2=$5 mode_name=$6
    
    # Parse delay and jitter
    local delay jitter
    parse_delay_value "$delay_value" delay jitter
    local netem_cmd=$(build_netem_delay_cmd "$delay" "$jitter")
    
    # Build tc commands to filter by ports
    local cmds="tc qdisc del dev eth0 root 2>/dev/null || true; "
    cmds+="tc qdisc add dev eth0 root handle 1: prio; "
    cmds+="tc qdisc add dev eth0 parent 1:3 handle 30: $netem_cmd; "
    cmds+="tc filter add dev eth0 protocol ip parent 1:0 prio 1 u32 match ip dport $port1 0xffff flowid 1:3; "
    cmds+="tc filter add dev eth0 protocol ip parent 1:0 prio 1 u32 match ip sport $port1 0xffff flowid 1:3"
    
    # Add second port if specified
    if [ -n "$port2" ]; then
        cmds+="; tc filter add dev eth0 protocol ip parent 1:0 prio 1 u32 match ip dport $port2 0xffff flowid 1:3"
        cmds+="; tc filter add dev eth0 protocol ip parent 1:0 prio 1 u32 match ip sport $port2 0xffff flowid 1:3"
    fi
    
    local cmd="docker exec $container sh -c '$cmds'"
    
    local jitter_info=""
    [ -n "$jitter" ] && jitter_info=" (jitter: $jitter)"
    
    local port_info="port $port1"
    [ -n "$port2" ] && port_info="ports $port1/$port2"
    
    if [ "$location" = "local" ]; then
        eval "sudo $cmd" 2>/dev/null && APPLIED_DELAYS+=("$location:container:$container:$mode_name") && \
            log "   ✅ Applied $mode_name delay ($delay$jitter_info) to $container ($port_info)"
    else
        ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE \
            "$REMOTE_PC_USER@$HPLMN_IP" "sudo $cmd" 2>/dev/null && \
            APPLIED_DELAYS+=("$location:container:$container:$mode_name") && \
            log "   ✅ Applied $mode_name delay ($delay$jitter_info) to $container ($port_info) (HPLMN)"
    fi
}

# Apply UPF-specific delays
apply_upf_delay() {
    local location=$1 mode=$2 delay_value=$3
    local interface
    case "$mode" in
        "gtpu"|"ipsec"|"full")
            interface=$(get_host_default_interface "$location")
            [ -z "$interface" ] && { log "   ❌ Could not detect default interface"; return 1; }
            apply_tc_delay "$interface" "$delay_value" "$location" "$mode"
            ;;
        "pfcp")
            interface=$(get_control_plane_bridge_interface "$location")
            [ -z "$interface" ] && { log "   ❌ Could not detect control plane bridge"; return 1; }
            apply_tc_delay "$interface" "$delay_value" "$location" "pfcp"
            ;;
        "n3")
            [ "$location" = "remote" ] && { log "   ❌ N3 not available on HPLMN"; return 1; }
            interface=$(get_n3_bridge_interface "$location")
            [ -z "$interface" ] && { log "   ⚠️  N3 bridge not found"; return 1; }
            apply_tc_delay "$interface" "$delay_value" "$location" "gtpu"
            ;;
        "n6"|"ogstun")
            # N6 delay - apply to ogstun inside UPF container
            local delay jitter
            parse_delay_value "$delay_value" delay jitter
            local netem_cmd=$(build_netem_delay_cmd "$delay" "$jitter")
            
            local cmds="tc qdisc del dev ogstun root 2>/dev/null || true; tc qdisc add dev ogstun root $netem_cmd"
            
            local jitter_info=""
            [ -n "$jitter" ] && jitter_info=" (jitter: $jitter)"
            
            if [ "$location" = "local" ]; then
                sudo docker exec open5gs-upf sh -c "$cmds" 2>/dev/null && {
                    APPLIED_DELAYS+=("$location:container:open5gs-upf:n6")
                    log "   ✅ Applied N6 delay ($delay$jitter_info) to local UPF ogstun"
                    return 0
                }
            else
                ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE \
                    "$REMOTE_PC_USER@$HPLMN_IP" \
                    "sudo docker exec open5gs-upf sh -c '$cmds'" 2>/dev/null && {
                    APPLIED_DELAYS+=("$location:container:open5gs-upf:n6")
                    log "   ✅ Applied N6 delay ($delay$jitter_info) to remote UPF ogstun (HPLMN)"
                    return 0
                }
            fi
            log "   ❌ Failed to apply N6 delay"
            return 1
            ;;
    esac
}

# Apply SEPP-specific delays (NEW in v3.0.0)
apply_sepp_delay() {
    local location=$1 mode=$2 delay_value=$3
    local container_name=$(get_container_name_for_service "open5gs-sepp" "$location")
    
    [ -z "$container_name" ] && { log "   ⚠️  SEPP container not found"; return 1; }
    
    case "$mode" in
        "n32")
            # Apply delay only to N32 interface ports (8080 and 8081)
            apply_container_port_delay "$container_name" "$delay_value" "$location" "$SEPP_N32_PORT_1" "$SEPP_N32_PORT_2" "n32"
            ;;
        "eth0"|"full")
            # Apply delay to all traffic on eth0
            apply_container_eth0_delay "$container_name" "$delay_value" "$location"
            ;;
        *)
            log "   ⚠️  Unknown SEPP delay mode: $mode"
            return 1
            ;;
    esac
}

# Apply SMF-specific delays (NEW in v3.0.0)
apply_smf_delay() {
    local location=$1 mode=$2 delay_value=$3
    local container_name=$(get_container_name_for_service "open5gs-smf" "$location")
    
    [ -z "$container_name" ] && { log "   ⚠️  SMF container not found"; return 1; }
    
    case "$mode" in
        "pfcp")
            # Apply delay only to PFCP port (8805) - SMF-UPF communication
            apply_container_port_delay "$container_name" "$delay_value" "$location" "$PFCP_PORT" "" "pfcp"
            ;;
        "eth0"|"full")
            # Apply delay to all traffic on eth0
            apply_container_eth0_delay "$container_name" "$delay_value" "$location"
            ;;
        *)
            log "   ⚠️  Unknown SMF delay mode: $mode"
            return 1
            ;;
    esac
}

apply_preconfigured_delays() {
    # Check if delays are enabled FIRST
    if [ "$DELAY_ENABLED" != "true" ]; then
        log "ℹ️  Network delays disabled (DELAY_ENABLED=false)"
        return 0
    fi
    
    if [ ${#DELAY_CONFIGS[@]} -eq 0 ]; then
        log "ℹ️  No delay rules configured"
        return 0
    fi
    
    record_timing delays_start
    log ""; log "======================================="
    log " Applying Pre-configured Network Delays"
    log "======================================="
    
    for key in "${!DELAY_CONFIGS[@]}"; do
        IFS=':' read -r location service mode <<< "$key"
        local delay_value="${DELAY_CONFIGS[$key]}"
        log "   Applying: $service ($mode) = $delay_value on $location"
        
        case "$service" in
            "open5gs-upf")
                apply_upf_delay "$location" "$mode" "$delay_value"
                ;;
            "open5gs-sepp")
                apply_sepp_delay "$location" "$mode" "$delay_value"
                ;;
            "open5gs-smf")
                apply_smf_delay "$location" "$mode" "$delay_value"
                ;;
            *)
                # Generic container eth0 delay for other services
                local container_name=$(get_container_name_for_service "$service" "$location")
                [ -z "$container_name" ] && { log "   ⚠️  Container for $service not found"; continue; }
                apply_container_eth0_delay "$container_name" "$delay_value" "$location"
                ;;
        esac
    done
    
    record_timing delays_end
    log ""; log "✅ All pre-configured delays applied ($(get_elapsed_ms delays_start delays_end)ms)"
}

remove_all_delays() {
    log ""; log "======================================="
    log " Removing All Network Delays"
    log "======================================="
    
    # Remove N6 delays first
    remove_n6_delays
    
    for entry in "${APPLIED_DELAYS[@]}"; do
        IFS=':' read -r location type target mode <<< "$entry"
        if [ "$type" = "container" ]; then
            if [[ "$mode" == "n6"* ]]; then
                # N6 delays handled by remove_n6_delays
                continue
            fi
            local cmd="docker exec $target sh -c 'tc qdisc del dev eth0 root 2>/dev/null || true'"
            [ "$location" = "local" ] && eval "sudo $cmd" 2>/dev/null || \
                ssh -o ConnectTimeout=5 -o BatchMode=$SSH_BATCH_MODE "$REMOTE_PC_USER@$HPLMN_IP" "sudo $cmd" 2>/dev/null
        else
            local cmd="sudo tc qdisc del dev $target root 2>/dev/null || true"
            [ "$location" = "local" ] && eval "$cmd" || \
                ssh -o ConnectTimeout=5 -o BatchMode=$SSH_BATCH_MODE "$REMOTE_PC_USER@$HPLMN_IP" "$cmd" 2>/dev/null
        fi
        log "   Removed delay from $target ($location) [$mode]"
    done
    APPLIED_DELAYS=()
    log "✅ All delays removed"
}

# ============================================================================
# N6 Delay Functions (MERGED in v3.2.3)
# ============================================================================
# When N6_DELAY_ENABLED=true, the same delay is applied to BOTH:
#   1) UPF ogstun (tun device) - based on roaming mode
#   2) Server main interface ($SERVER_INTERFACE) - all traffic
# This creates a symmetric bidirectional delay.

# Remove N6 delays from both UPFs and server
remove_n6_delays() {
    log "   🧹 Removing N6 delays..."
    
    # Remove ogstun delay from local UPF
    sudo docker exec open5gs-upf sh -c 'tc qdisc del dev ogstun root 2>/dev/null || true' 2>/dev/null || true
    
    # Remove ogstun delay from remote UPF
    ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE \
        "$REMOTE_PC_USER@$HPLMN_IP" \
        "sudo docker exec open5gs-upf sh -c 'tc qdisc del dev ogstun root 2>/dev/null || true'" 2>/dev/null || true
    
    # Remove server-side delay on performance server
    if [ -n "$SERVER_INTERFACE" ]; then
        ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE \
            "$SERVER_USER@$SERVER_IP" \
            "sudo tc qdisc del dev $SERVER_INTERFACE root 2>/dev/null || true" 2>/dev/null || true
    fi
    
    log "   ✅ N6 delays removed"
}

# Apply delay to UPF's ogstun interface
apply_n6_ogstun_delay() {
    local delay_value=$1
    local jitter_value=$2
    local location=$3
    
    local netem_cmd=$(build_netem_delay_cmd "$delay_value" "$jitter_value")
    local jitter_info=""
    [ -n "$jitter_value" ] && jitter_info=" (jitter: $jitter_value)"
    
    log "   🌐 Applying N6 delay to ogstun ($location)..."
    log "   📋 Delay: $delay_value$jitter_info"
    
    local cmds="tc qdisc del dev ogstun root 2>/dev/null || true; tc qdisc add dev ogstun root $netem_cmd"
    
    if [ "$location" = "local" ]; then
        sudo docker exec open5gs-upf sh -c "$cmds" 2>/dev/null && {
            APPLIED_DELAYS+=("local:container:open5gs-upf:n6-ogstun")
            log "   ✅ N6 delay applied to local UPF ogstun ($delay_value$jitter_info)"
            return 0
        }
    else
        ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE \
            "$REMOTE_PC_USER@$HPLMN_IP" \
            "sudo docker exec open5gs-upf sh -c '$cmds'" 2>/dev/null && {
            APPLIED_DELAYS+=("remote:container:open5gs-upf:n6-ogstun")
            log "   ✅ N6 delay applied to remote UPF ogstun ($delay_value$jitter_info)"
            return 0
        }
    fi
    
    log "   ❌ Failed to apply N6 delay on $location UPF"
    return 1
}

# Apply server-side delay on performance server interface (all traffic)
apply_n6_server_delay() {
    local delay_value=$1
    local jitter_value=$2
    local interface=$3
    
    local netem_cmd=$(build_netem_delay_cmd "$delay_value" "$jitter_value")
    local jitter_info=""
    [ -n "$jitter_value" ] && jitter_info=" (jitter: $jitter_value)"
    
    log "   🖥️  Applying server-side N6 delay on $interface..."
    log "   📋 Interface: $interface, Delay: $delay_value$jitter_info"
    log "   📍 Server: $SERVER_USER@$SERVER_IP"
    
    # Build SSH command to run tc on performance server
    local ssh_cmd="ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE $SERVER_USER@$SERVER_IP"
    
    # Clear existing rules then apply simple netem delay to all traffic
    local tc_script="sudo tc qdisc del dev $interface root 2>/dev/null || true; sudo tc qdisc add dev $interface root $netem_cmd"
    
    if ! $ssh_cmd "$tc_script" 2>&1; then
        log "   ❌ Failed to apply server-side N6 delay on $interface"
        log "   ℹ️  Attempting diagnostic..."
        $ssh_cmd "ip link show $interface 2>&1 | head -2; sudo tc qdisc show dev $interface 2>&1" 2>/dev/null || true
        log "   ℹ️  Try manually: ssh $SERVER_USER@$SERVER_IP 'sudo tc qdisc show dev $interface'"
        return 1
    fi
    
    APPLIED_DELAYS+=("server:host:$interface:n6-server")
    log "   ✅ Server-side N6 delay applied on $interface ($delay_value$jitter_info)"
    
    return 0
}

# Apply N6 delays based on roaming mode (MERGED in v3.2.3)
# Single config applies to BOTH ogstun and server interface
apply_n6_delays() {
    if [ "$N6_DELAY_ENABLED" != "true" ]; then
        return 0
    fi
    
    if [ -z "$N6_DELAY_VALUE" ]; then
        log "   ⚠️  N6 delay enabled but N6_DELAY_VALUE not set, skipping"
        return 0
    fi
    
    record_timing n6_delay_start
    log ""
    log "======================================="
    log " Applying N6 Interface Delays (Merged)"
    log "======================================="
    log "   Roaming Mode: $ROAMING_MODE"
    log "   Delay: $N6_DELAY_VALUE ${N6_DELAY_JITTER:+(jitter: $N6_DELAY_JITTER)}"
    
    # Determine which UPF to apply ogstun delay
    local ogstun_location=""
    case "$ROAMING_MODE" in
        "lbo")
            ogstun_location="local"
            log "   📌 LBO mode: ogstun delay → LOCAL UPF (VPLMN handles DN)"
            ;;
        "hr")
            ogstun_location="remote"
            log "   📌 HR mode: ogstun delay → REMOTE UPF (HPLMN handles DN)"
            ;;
        "non-roaming")
            ogstun_location="local"
            log "   📌 Non-roaming mode: ogstun delay → LOCAL UPF"
            ;;
    esac
    
    # Step 1: Apply ogstun delay on appropriate UPF
    log ""
    log "   --- Step 1/2: UPF ogstun delay ---"
    apply_n6_ogstun_delay "$N6_DELAY_VALUE" "$N6_DELAY_JITTER" "$ogstun_location"
    
    # Step 2: Apply same delay on server interface
    log ""
    log "   --- Step 2/2: Server interface delay ---"
    apply_n6_server_delay "$N6_DELAY_VALUE" "$N6_DELAY_JITTER" "$SERVER_INTERFACE"
    
    record_timing n6_delay_end
    log ""
    log "✅ N6 delays applied to both ogstun and server ($(get_elapsed_ms n6_delay_start n6_delay_end)ms)"
}

reapply_preconfigured_delays() {
    if [ "$DELAY_ENABLED" != "true" ] && [ "$N6_DELAY_ENABLED" != "true" ]; then
        return 0
    fi
    if [ ${#DELAY_CONFIGS[@]} -eq 0 ] && [ "$N6_DELAY_ENABLED" != "true" ]; then
        return 0
    fi
    log "🔄 Reapplying pre-configured delays..."
    APPLIED_DELAYS=()
    apply_preconfigured_delays
    apply_n6_delays
}
