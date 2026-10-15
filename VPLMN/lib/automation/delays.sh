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

# netem holds every delayed packet in its queue for the whole delay, and drops
# arrivals once the queue is full. The default (1000 packets) is smaller than
# what a 100 Mbps iperf test keeps in flight at 150 ms (~1300 packets, ~2600
# IP fragments with N9 IPsec), so the emulator itself dropped 25-70% — loss a
# real long-distance link would not add. 10000 covers ~750 Mbps at 150 ms.
: "${NETEM_LIMIT:=10000}"

# Build tc netem delay command with optional jitter
build_netem_delay_cmd() {
    local delay=$1
    local jitter=$2
    
    if [ -n "$jitter" ]; then
        echo "netem limit $NETEM_LIMIT delay $delay $jitter"
    else
        echo "netem limit $NETEM_LIMIT delay $delay"
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
    # scope (gtpu only): "n9" = only traffic to the other PLMN's host. Set for the
    # host interface, where a real gNB's N3 rides alongside N9. "n3" = the N3
    # docker bridge, where nothing goes to the other PLMN but every UDP packet
    # is GTP-U, so all UDP is delayed there (see the fragment note below).
    local interface=$1 delay_value=$2 location=$3 mode=$4 scope=${5:-}

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
            local n9_peer
            if [ "$location" = "remote" ]; then
                n9_peer=$(ip route get "$HPLMN_IP" 2>/dev/null | grep -oP 'src \K[0-9.]+')
            else
                n9_peer=$HPLMN_IP
            fi
            # On the host interface, match only packets to the N9 peer. N3 (gNB <->
            # vUPF) is udp/2152 too, and with a real gNB (UE_TYPE=dsk) it leaves
            # through this interface: a port-only filter delayed the N3 downlink as
            # well (+44ms RTT in LBO, where there is no N9 at all; three delays per
            # round trip instead of two in HR). PacketRusher's N3 runs over a docker
            # bridge, so for it this matches exactly what the port-only filter did.
            # Same fix as the WebUI's apply_n9_delay (webui/backend/app.py).
            local dst=""
            if [ "$scope" = "n9" ]; then
                if [ -n "$n9_peer" ]; then
                    dst="match ip dst $n9_peer/32 "
                else
                    log "   ⚠️  N9 peer address unknown on $location — GTP-U delay not limited to N9 (would also hit a real gNB's N3)"
                fi
            fi
            tc_cmds+=("sudo tc qdisc add dev $interface root handle 1: prio")
            tc_cmds+=("sudo tc qdisc add dev $interface parent 1:3 handle 30: $netem_cmd")
            tc_cmds+=("sudo tc filter add dev $interface protocol ip parent 1:0 prio 1 u32 ${dst}match ip dport $GTPU_PORT 0xffff flowid 1:3")
            tc_cmds+=("sudo tc filter add dev $interface protocol ip parent 1:0 prio 1 u32 ${dst}match ip sport $GTPU_PORT 0xffff flowid 1:3")
            tc_cmds+=("sudo tc filter add dev $interface protocol ip parent 1:0 prio 2 u32 ${dst}match ip protocol $ESP_PROTOCOL 0xff flowid 1:3")
            tc_cmds+=("sudo tc filter add dev $interface protocol ip parent 1:0 prio 3 u32 ${dst}match ip protocol 17 0xff match ip dport $IPSEC_NAT_T_PORT 0xffff flowid 1:3")
            tc_cmds+=("sudo tc filter add dev $interface protocol ip parent 1:0 prio 3 u32 ${dst}match ip protocol 17 0xff match ip sport $IPSEC_NAT_T_PORT 0xffff flowid 1:3")
            # A full-size GTP-U packet does not fit the 1500-byte link and is
            # IP-fragmented. Only the first fragment carries the UDP header, so the
            # port filters above delay it while the rest bypassed netem — unlike
            # ESP, where every fragment is proto 50. Also match UDP to the other
            # PLMN's host (every fragment carries the IP header), so all fragments
            # take the same delay and queue in both modes. IKE (udp/500) stays out.
            if [ -n "$n9_peer" ]; then
                tc_cmds+=("sudo tc filter add dev $interface protocol ip parent 1:0 prio 4 u32 match ip protocol 17 0xff match ip dport $IPSEC_IKE_PORT 0xffff flowid 1:2")
                tc_cmds+=("sudo tc filter add dev $interface protocol ip parent 1:0 prio 4 u32 match ip protocol 17 0xff match ip sport $IPSEC_IKE_PORT 0xffff flowid 1:2")
                tc_cmds+=("sudo tc filter add dev $interface protocol ip parent 1:0 prio 5 u32 match ip protocol 17 0xff match ip dst $n9_peer/32 flowid 1:3")
            fi
            # The same fragment problem on the N3 bridge: TCP over PacketRusher
            # fragments on nearly every segment there (MSS 1460 + GTP-U > 1500),
            # and with only the first fragment delayed TCP fell to 3-4 Mb/s
            # (measured 2026-10-08). The bridge carries no UDP but GTP-U (PFCP is
            # on the control-plane network), so matching all UDP is exact.
            if [ "$scope" = "n3" ]; then
                tc_cmds+=("sudo tc filter add dev $interface protocol ip parent 1:0 prio 6 u32 match ip protocol 17 0xff flowid 1:3")
            fi
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
            # Delay N4 (PFCP), whether or not N4 IPsec is up — same reasoning as
            # "gtpu" above. In the clear PFCP is udp/8805; under N4 IPsec it is
            # inside ESP and a port filter silently matches nothing. This is the
            # control-plane bridge, where the only ESP is the N4 tunnel (N9's ESP
            # is on the host's default interface), so matching ESP here delays
            # PFCP and nothing else. IKE (udp/500) is not matched.
            tc_cmds+=("sudo tc qdisc add dev $interface root handle 1: prio")
            tc_cmds+=("sudo tc qdisc add dev $interface parent 1:3 handle 30: $netem_cmd")
            tc_cmds+=("sudo tc filter add dev $interface protocol ip parent 1:0 prio 1 u32 match ip dport $PFCP_PORT 0xffff flowid 1:3")
            tc_cmds+=("sudo tc filter add dev $interface protocol ip parent 1:0 prio 1 u32 match ip sport $PFCP_PORT 0xffff flowid 1:3")
            tc_cmds+=("sudo tc filter add dev $interface protocol ip parent 1:0 prio 2 u32 match ip protocol $ESP_PROTOCOL 0xff flowid 1:3")
            tc_cmds+=("sudo tc filter add dev $interface protocol ip parent 1:0 prio 3 u32 match ip protocol 17 0xff match ip dport $IPSEC_NAT_T_PORT 0xffff flowid 1:3")
            tc_cmds+=("sudo tc filter add dev $interface protocol ip parent 1:0 prio 3 u32 match ip protocol 17 0xff match ip sport $IPSEC_NAT_T_PORT 0xffff flowid 1:3")
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

    # PFCP under N4 IPsec leaves the SMF as ESP (the tunnel terminates inside
    # this container), where the port filter above matches nothing. Match ESP
    # and NAT-T as well: the N4 tunnel is the only IPsec in the SMF container.
    if [ "$mode_name" = "pfcp" ]; then
        cmds+="; tc filter add dev eth0 protocol ip parent 1:0 prio 2 u32 match ip protocol $ESP_PROTOCOL 0xff flowid 1:3"
        cmds+="; tc filter add dev eth0 protocol ip parent 1:0 prio 3 u32 match ip protocol 17 0xff match ip dport $IPSEC_NAT_T_PORT 0xffff flowid 1:3"
        cmds+="; tc filter add dev eth0 protocol ip parent 1:0 prio 3 u32 match ip protocol 17 0xff match ip sport $IPSEC_NAT_T_PORT 0xffff flowid 1:3"
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
            apply_tc_delay "$interface" "$delay_value" "$location" "$mode" n9
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
            apply_tc_delay "$interface" "$delay_value" "$location" "gtpu" n3
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
        # N6 delays (UPF ogstun/IFB and the performance server's interface) were
        # removed by remove_n6_delays above. The server entry in particular must
        # not fall through: its location is "server", which the remote branch
        # below would send to the HPLMN.
        [[ "$mode" == "n6"* ]] && continue
        local cmd
        if [ "$type" = "container" ]; then
            cmd="sudo docker exec $target sh -c 'tc qdisc del dev eth0 root 2>/dev/null || true'"
        else
            cmd="sudo tc qdisc del dev $target root 2>/dev/null || true"
        fi
        # Never fatal: this runs from the EXIT trap under set -e, and an
        # unreachable HPLMN (e.g. unplugged for a non-roaming run) used to end
        # the cleanup there with ssh's 255 as the run's exit status.
        if [ "$location" = "local" ]; then
            eval "$cmd" 2>/dev/null || true
        elif ! ssh -o ConnectTimeout=5 -o BatchMode=$SSH_BATCH_MODE "$REMOTE_PC_USER@$HPLMN_IP" "$cmd" 2>/dev/null; then
            log "   ⚠️  Could not remove delay from $target on the HPLMN (unreachable?)"
            continue
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
    
    # ogstun root = the downlink half; ogstun ingress + the IFB device = the
    # uplink half for destinations other than the performance server.
    local n6_clear="tc qdisc del dev ogstun root 2>/dev/null || true; tc qdisc del dev ogstun ingress 2>/dev/null || true; ip link del $N6_IFB_DEV 2>/dev/null || true"

    # Remove ogstun delay from local UPF
    sudo docker exec open5gs-upf sh -c "$n6_clear" 2>/dev/null || true
    
    # Remove ogstun delay from remote UPF
    ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE \
        "$REMOTE_PC_USER@$HPLMN_IP" \
        "sudo docker exec open5gs-upf sh -c '$n6_clear'" 2>/dev/null || true
    
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

# Uplink half of the N6 delay for every destination EXCEPT the performance server.
#
# The N6 delay has two halves. The downlink half is netem on the UPF's ogstun
# (apply_n6_ogstun_delay); the other half is netem on the performance server's
# interface (apply_n6_server_delay). Traffic to the performance server passes
# both — ping, download and iperf see the full delay. Traffic to any OTHER
# destination (the web pages of the Browsertime test) never reaches that
# server, so it would get only the ogstun half, i.e. half the intended RTT.
#
# This adds the missing half where such traffic does pass: at the UPF, in the
# uplink direction. netem shapes egress only and the uplink ARRIVES on ogstun
# (from the GTP side), so it is redirected into an IFB device and delayed
# there — before the UPF's MASQUERADE rewrites the source. Packets to the
# performance server are passed untouched, so that path keeps exactly the
# delay it always had.
N6_IFB_DEV="ifb-n6"
apply_n6_uplink_delay() {
    local delay_value=$1
    local jitter_value=$2
    local location=$3
    local exclude_ip=$4

    local netem_cmd=$(build_netem_delay_cmd "$delay_value" "$jitter_value")
    local jitter_info=""
    [ -n "$jitter_value" ] && jitter_info=" (jitter: $jitter_value)"

    log "   🌐 Applying N6 uplink delay at the $location UPF for destinations other than ${exclude_ip:-<none excluded>}..."

    local cmds="ip link show $N6_IFB_DEV >/dev/null 2>&1 || ip link add $N6_IFB_DEV type ifb; ip link set $N6_IFB_DEV up; "
    cmds+="tc qdisc del dev ogstun ingress 2>/dev/null || true; tc qdisc add dev ogstun handle ffff: ingress; "
    [ -n "$exclude_ip" ] && cmds+="tc filter add dev ogstun parent ffff: protocol ip prio 1 u32 match ip dst $exclude_ip/32 action pass; "
    cmds+="tc filter add dev ogstun parent ffff: protocol ip prio 2 u32 match u32 0 0 action mirred egress redirect dev $N6_IFB_DEV; "
    cmds+="tc qdisc replace dev $N6_IFB_DEV root $netem_cmd"

    # The container cannot load kernel modules; the host has to provide ifb.
    if [ "$location" = "local" ]; then
        sudo modprobe ifb 2>/dev/null || true
        sudo docker exec open5gs-upf sh -c "$cmds" 2>/dev/null && {
            APPLIED_DELAYS+=("local:container:open5gs-upf:n6-uplink")
            log "   ✅ N6 uplink delay applied at local UPF ($delay_value$jitter_info)"
            return 0
        }
    else
        ssh -o ConnectTimeout=$SSH_CONNECT_TIMEOUT -o BatchMode=$SSH_BATCH_MODE \
            "$REMOTE_PC_USER@$HPLMN_IP" \
            "sudo modprobe ifb 2>/dev/null; sudo docker exec open5gs-upf sh -c '$cmds'" 2>/dev/null && {
            APPLIED_DELAYS+=("remote:container:open5gs-upf:n6-uplink")
            log "   ✅ N6 uplink delay applied at remote UPF ($delay_value$jitter_info)"
            return 0
        }
    fi

    log "   ❌ Failed to apply N6 uplink delay on $location UPF"
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
    log "   --- Step 1/3: UPF ogstun delay (downlink, all destinations) ---"
    apply_n6_ogstun_delay "$N6_DELAY_VALUE" "$N6_DELAY_JITTER" "$ogstun_location"
    
    # Step 2: Apply same delay on server interface
    log ""
    log "   --- Step 2/3: Server interface delay (performance server) ---"
    apply_n6_server_delay "$N6_DELAY_VALUE" "$N6_DELAY_JITTER" "$SERVER_INTERFACE"

    # Step 3: the same delay for traffic that never reaches that server
    # (web pages), so every destination sees the full N6 delay. Not fatal: the
    # performance-server tests do not depend on it.
    log ""
    log "   --- Step 3/3: UPF uplink delay (all other destinations) ---"
    apply_n6_uplink_delay "$N6_DELAY_VALUE" "$N6_DELAY_JITTER" "$ogstun_location" "$SERVER_IP" \
        || log "   ⚠️  Web-page traffic will see only half the N6 delay in this run"
    
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
