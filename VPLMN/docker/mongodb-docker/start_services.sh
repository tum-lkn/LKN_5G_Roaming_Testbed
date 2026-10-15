#!/bin/bash

# --- Function to Start MongoDB Service ---
start_mongodb() {
    echo "Starting MongoDB service..."
    /usr/bin/mongod --dbpath /data/db --logpath /var/log/mongodb/mongod.log --port 27017 --fork --bind_ip 0.0.0.0
    echo "MongoDB service started."
}

# --- Add Open5GS Subscribers --- VPLMN provisions its own non-roaming
# 999710... subscribers (PLMN 999/71) WITH credentials, PLUS policy-only stubs
# for the inbound LBO roamers (001/01) so the VISITED PCF can serve them. The
# roamers are home to the HPLMN and authenticate there (different key/OPc), so
# VPLMN stores NO security for them - only the session/policy data the v-PCF
# needs. See the roamer loop below for the full rationale.
add_open5gs_subscribers() {
    echo "Adding Open5GS subscribers..."
    local key="465B5CE8B199B49FAA5F0A2EE238A6BC"
    local opc="E8ED289DEBA952E4283B54E88E6183CA"

    # ===============================
    # BULK INSERT ALL SUBSCRIBERS
    # ===============================
    echo "Bulk inserting all subscribers..."
    
    mongosh mongodb://localhost/open5gs --eval '
    const key = "'"$key"'";
    const opc = "'"$opc"'";
    const subscribers = [];
    
    // NON-ROAMING (101 UE): 999710000000001 - 999710000000101
    for (let i = 1; i <= 101; i++) {
        const imsi = "999710" + String(i).padStart(9, "0");
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

    // INBOUND LBO ROAMERS (101 UE): 001010000000001 - 001010000000101.
    // HPLMN home subscribers (PLMN 001/01) visiting under Local Breakout. In LBO
    // the VISITED SMF asks the VISITED (this) PCF for policy, and Open5GS PCF
    // does a local Mongo lookup by SUPI (ogs_dbi_session_data); with no matching
    // doc it returns 404 -> PDU session rejected (5GSM cause #34). So we seed
    // exactly the session/policy data the v-PCF needs and NOTHING ELSE - in
    // particular NO "security" block: these UEs authenticate against the HOME
    // (HPLMN) key/OPc over N32, never VPLMN(s), so VPLMN must not carry their
    // credentials. HR roamers (001010000001001+) are home-routed and use the
    // HOME PCF, so they are intentionally NOT seeded here.
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
        db.subscribers.deleteMany({});
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
