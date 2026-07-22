#!/bin/bash

# --- Function to Start MongoDB Service ---
start_mongodb() {
    echo "Starting MongoDB service..."
    /usr/bin/mongod --dbpath /data/db --logpath /var/log/mongodb/mongod.log --port 27017 --fork --bind_ip 0.0.0.0
    echo "MongoDB service started."
}

# --- Function to Add Open5GS Subscribers --- ( IMSI's are used according to open5gs roaming tutorial)
add_open5gs_subscribers() {
    echo "Adding Open5GS subscribers..."
    local key="8BAF473F2F8FD09487CCCBD7097C6862"
    local opc="8E27B6AF0E692E750F32667A3B14605D"

    # ===============================
    # BULK INSERT ALL SUBSCRIBERS
    # ===============================
    echo "Bulk inserting all subscribers..."
    
    mongosh mongodb://localhost/open5gs --eval '
    const key = "'"$key"'";
    const opc = "'"$opc"'";
    const subscribers = [];
    
    // NON-ROAMING (101 UE): 999700000000001 - 999700000000101
    for (let i = 1; i <= 101; i++) {
        const imsi = "999700" + String(i).padStart(9, "0");
        subscribers.push({
            schema_version: NumberInt(1),
            imsi: imsi,
            msisdn: [],
            imeisv: [],
            mme_host: [],
            mm_realm: [],
            purge_flag: [],
            slice: [{
                sst: NumberInt(1),
                default_indicator: true,
                session: [{
                    name: "internet",
                    type: NumberInt(3),
                    qos: {
                        index: NumberInt(9),
                        arp: {
                            priority_level: NumberInt(8),
                            pre_emption_capability: NumberInt(1),
                            pre_emption_vulnerability: NumberInt(2)
                        }
                    },
                    ambr: {
                        downlink: { value: NumberInt(1000000000), unit: NumberInt(0) },
                        uplink: { value: NumberInt(1000000000), unit: NumberInt(0) }
                    },
                    pcc_rule: []
                }]
            }],
            security: { k: key, op: null, opc: opc, amf: "8000" },
            ambr: {
                downlink: { value: NumberInt(1000000000), unit: NumberInt(0) },
                uplink: { value: NumberInt(1000000000), unit: NumberInt(0) }
            },
            access_restriction_data: 32,
            network_access_mode: 0,
            subscriber_status: 0,
            operator_determined_barring: 0,
            subscribed_rau_tau_timer: 12,
            __v: 0
        });
    }
    
    // LBO ROAMING (101 UE): 001010000000001 - 001010000000101
    for (let i = 1; i <= 101; i++) {
        const imsi = "00101" + String(i).padStart(10, "0");
        subscribers.push({
            schema_version: NumberInt(1),
            imsi: imsi,
            msisdn: [],
            imeisv: [],
            mme_host: [],
            mm_realm: [],
            purge_flag: [],
            slice: [{
                sst: NumberInt(1),
                default_indicator: true,
                session: [{
                    name: "internet",
                    type: NumberInt(3),
                    qos: {
                        index: NumberInt(9),
                        arp: {
                            priority_level: NumberInt(8),
                            pre_emption_capability: NumberInt(1),
                            pre_emption_vulnerability: NumberInt(2)
                        }
                    },
                    ambr: {
                        downlink: { value: NumberInt(1000000000), unit: NumberInt(0) },
                        uplink: { value: NumberInt(1000000000), unit: NumberInt(0) }
                    },
                    pcc_rule: [],
                    lbo_roaming_allowed: true
                }]
            }],
            security: { k: key, op: null, opc: opc, amf: "8000" },
            ambr: {
                downlink: { value: NumberInt(1000000000), unit: NumberInt(0) },
                uplink: { value: NumberInt(1000000000), unit: NumberInt(0) }
            },
            access_restriction_data: 32,
            network_access_mode: 0,
            subscriber_status: 0,
            operator_determined_barring: 0,
            subscribed_rau_tau_timer: 12,
            __v: 0
        });
    }
    
    // HR ROAMING (101 UE): 001010000001001 - 001010000001101
    for (let i = 1; i <= 101; i++) {
        const num = 1000 + i;
        const imsi = "00101000000" + String(num);
        subscribers.push({
            schema_version: NumberInt(1),
            imsi: imsi,
            msisdn: [],
            imeisv: [],
            mme_host: [],
            mm_realm: [],
            purge_flag: [],
            slice: [{
                sst: NumberInt(1),
                default_indicator: true,
                session: [{
                    name: "internet",
                    type: NumberInt(3),
                    qos: {
                        index: NumberInt(9),
                        arp: {
                            priority_level: NumberInt(8),
                            pre_emption_capability: NumberInt(1),
                            pre_emption_vulnerability: NumberInt(2)
                        }
                    },
                    ambr: {
                        downlink: { value: NumberInt(1000000000), unit: NumberInt(0) },
                        uplink: { value: NumberInt(1000000000), unit: NumberInt(0) }
                    },
                    pcc_rule: [],
                    lbo_roaming_allowed: false
                }]
            }],
            security: { k: key, op: null, opc: opc, amf: "8000" },
            ambr: {
                downlink: { value: NumberInt(1000000000), unit: NumberInt(0) },
                uplink: { value: NumberInt(1000000000), unit: NumberInt(0) }
            },
            access_restriction_data: 32,
            network_access_mode: 0,
            subscriber_status: 0,
            operator_determined_barring: 0,
            subscribed_rau_tau_timer: 12,
            __v: 0
        });
    }
    
    // Bulk insert all subscribers
    const result = db.subscribers.insertMany(subscribers, { ordered: false });
    print("Inserted " + result.insertedCount + " subscribers");
    '

    echo "Open5GS subscribers added."
}

# --- Main Execution ---

# Start MongoDB service
start_mongodb

# Add Open5GS Subscribers
add_open5gs_subscribers

# Keep the shell running for interaction (optional)
tail -f /dev/null
