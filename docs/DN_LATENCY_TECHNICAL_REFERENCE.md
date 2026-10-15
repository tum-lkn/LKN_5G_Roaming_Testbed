# DN Latency Configuration Technical Reference

> **Parameter names changed (automation v3.2.3 and later).** `N6_SERVER_DELAY_ENABLED` and `N6_SERVER_DELAY_VALUE` are retired: the DN server's half of the delay is applied automatically whenever `N6_DELAY_ENABLED=true`, using `N6_DELAY_VALUE`. `N6_SERVER_INTERFACE` is now `SERVER_INTERFACE` (the old name is still accepted). Where this document shows the old names, read them that way. Traffic to destinations other than the performance server gets its second half at the UPF — see [AUTOMATION.md](AUTOMATION.md#n6-delay-data-network-latency).

## Parameter Definitions

### N6 Delay Parameters

| Parameter | Purpose | Example | Notes |
|-----------|---------|---------|-------|
| `N6_DELAY_ENABLED` | Enable/disable DN data plane delays | `true` | Set to `true` in all generated configs |
| `N6_DELAY_VALUE` | Latency on UPF ogstun interface | `50ms` | Applied to local UPF (LBO/non-roaming) or remote UPF (HR) |
| `N6_DELAY_JITTER` | Jitter for DN delay | `10ms` | Standard deviation of delay variation |
| `N6_SERVER_DELAY_ENABLED` | Enable server-side delay | `true` | Always `true` for bidirectional symmetry |
| `N6_SERVER_DELAY_VALUE` | Server-side delay | `50ms` | **Must match** `N6_DELAY_VALUE` for symmetrical testing |
| `N6_SERVER_DELAY_JITTER` | Server-side jitter | `10ms` | **Must match** `N6_DELAY_JITTER` for symmetrical testing |
| `N6_SERVER_INTERFACE` | Host interface for server delay | `eth0` | Typically the host network interface |

### IXP Signaling Delays

These control plane delays simulate inter-network delays:

```bash
DELAY_RULE_1=local:open5gs-upf:gtpu=<latency>ms:<jitter>ms
DELAY_RULE_2=remote:open5gs-upf:gtpu=<latency>ms:<jitter>ms
DELAY_RULE_3=local:open5gs-sepp:n32=<latency>ms:<jitter>ms
DELAY_RULE_4=remote:open5gs-sepp:n32=<latency>ms:<jitter>ms
```

- **DELAY_RULE_1/2**: GTP-U delays (user plane tunneling protocol)
- **DELAY_RULE_3/4**: N32 SEPP delays (inter-PLMN signaling interface)

## DN Latency Matrix Explained

### Structure: 4×4 Geographic Matrix

Each location has a row in the matrix representing latencies TO all other locations:

```
                Frankfurt    Paris    Boston    Sydney
From Frankfurt:    0ms       16ms      44ms     150ms
From Paris:       16ms        0ms      40ms     139ms
From Boston:      44ms       40ms       0ms     104ms
From Sydney:      150ms      139ms     104ms      0ms
```

### Reading the Matrix

Example: "Paris to Boston"
- Location index: Paris = 1 (DN_LATENCIES_1)
- Target index: Boston = 2
- Latency: DN_LATENCIES_1[2] = 40ms
- Jitter: DN_JITTERS_1[2] = 1ms

Generated config name: `..._dn_paris_to_boston_...40ms jitter 1ms`

### Matrix Values Source

Based on real-world ping statistics from [WonderNetwork](https://wondernetwork.com/pings/Frankfurt):
- **Frankfurt (EU Central)** → Paris (EU West): 16ms
- **Frankfurt** → Boston (US East): 44ms  
- **Frankfurt** → Sydney (Australia): 150ms
- **Paris** → Boston: 40ms
- **Paris** → Sydney: 139ms
- **Boston** → Sydney: 104ms

## Configuration Generation Algorithm

### Input Parameters

```bash
MODE_NAMES=(non-roaming lbo hr hr-ipsec hr-remote-upf hr-remote-upf-ipsec)
LATENCIES=(16 44 150)                    # IXP latencies in ms
JITTERS=(1 1 2)                          # Corresponding jitter values
PING_PAYLOADS=(56 1400)                  # Payload sizes in bytes
DN_LOCATIONS=("Frankfurt" "Paris" "Boston" "Sydney")
DN_LATENCIES_0=(0 16 44 150)             # From Frankfurt to [FR, PA, BO, SY]
DN_LATENCIES_1=(16 0 40 139)             # From Paris to [FR, PA, BO, SY]
DN_LATENCIES_2=(44 40 0 104)             # From Boston to [FR, PA, BO, SY]
DN_LATENCIES_3=(150 139 104 0)           # From Sydney to [FR, PA, BO, SY]
```

### Generation Loops

```python
# Pseudo-code for config generation

for mode in MODE_NAMES:
    if mode == "non-roaming":
        # Non-roaming: test each DN location once
        for dn_location in DN_LOCATIONS:
            payload = PING_PAYLOADS[0]  # Use first payload only
            config = generate_config(
                mode="non-roaming",
                dn_delay=DN_LATENCIES_<index>[<index>],  # e.g., Paris→Paris = 0ms
                dn_jitter=DN_JITTERS_<index>[<index>]
            )
            # 4 configs total
    else:
        # Roaming modes: full matrix
        for latency_idx in LATENCIES:
            for dn_source_idx in DN_LOCATIONS:
                for dn_target_idx in DN_LOCATIONS:  # All 4 targets per source
                    for payload in PING_PAYLOADS:
                        config = generate_config(
                            mode=mode,
                            ixp_latency=LATENCIES[latency_idx],
                            ixp_jitter=JITTERS[latency_idx],
                            dn_delay=DN_LATENCIES_<source_idx>[<target_idx>],
                            dn_jitter=DN_JITTERS_<source_idx>[<target_idx>]
                        )
        # Per mode: 3 * 4 * 4 * 2 = 96 configs
        # 4 modes * 96 = 384 roaming configs
```

## Delay Application Flow

### Sequence of Operations in testbed_automation.sh

```mermaid
1. Parse config file
   ↓
2. Check N6_DELAY_ENABLED
   ├─ false → skip N6 setup
   └─ true ↓
3. Determine UPF location based on ROAMING_MODE
   ├─ LBO/non-roaming → apply to LOCAL UPF
   └─ HR/HR-IPsec → apply to REMOTE UPF
   ↓
4. Apply ogstun delay
   └─ tc qdisc add dev ogstun root netem delay <N6_DELAY_VALUE> jitter <N6_DELAY_JITTER>
   ↓
5. If N6_SERVER_DELAY_ENABLED
   └─ Apply server-side delay on host interface
      tc qdisc add dev <interface> ... netem delay <N6_SERVER_DELAY_VALUE> jitter <N6_SERVER_DELAY_JITTER>
```

## Real-World Scenarios

### Scenario 1: LBO with Local Server (Frankfurt VPLMN, Frankfurt DN)

```
Generated Config: lbo_lat16_jit1_dn_frankfurt_to_frankfurt_pld56.conf

ROAMING_MODE=lbo
DELAY_RULE_1=local:open5gs-upf:gtpu=16ms:1ms  ← IXP delay (signaling path)
DELAY_RULE_2=remote:open5gs-upf:gtpu=16ms:1ms ← IXP delay (HPLMN side)
N6_DELAY_VALUE=0ms                            ← No DN latency (same location)
N6_DELAY_JITTER=0ms

What this simulates:
- Control plane: 16ms IXP delay between VPLMN and HPLMN
- Data plane: No delay (UE data stays local in VPLMN)
- Result: Optimal performance, but still with IXP signaling delays
```

### Scenario 2: LBO with Remote Server (Frankfurt VPLMN, Sydney DN)

```
Generated Config: lbo_lat150_jit2_dn_frankfurt_to_sydney_pld1400.conf

ROAMING_MODE=lbo
DELAY_RULE_1=local:open5gs-upf:gtpu=150ms:2ms  ← IXP delay
DELAY_RULE_2=remote:open5gs-upf:gtpu=150ms:2ms ← IXP delay
N6_DELAY_VALUE=150ms                            ← DN latency to Sydney
N6_DELAY_JITTER=2ms
N6_SERVER_DELAY_ENABLED=true
N6_SERVER_DELAY_VALUE=150ms                     ← Server-side bidirectional delay

What this simulates:
- Control plane: 150ms IXP delay + jitter
- Data plane: 150ms delay to Sydney server (+ 150ms return)
- Application: Downloading 10MB file from Sydney server over LBO
- Result: Significant latency but with local breakout (no HPLMN data routing)
```

### Scenario 3: HR with Remote Server (Frankfurt VPLMN, Boston DN via HPLMN)

```
Generated Config: hr_lat44_jit1_dn_paris_to_boston_pld56.conf

ROAMING_MODE=hr
DELAY_RULE_1=local:open5gs-upf:gtpu=44ms:1ms   ← IXP delay (Frankfurt-Paris)
DELAY_RULE_2=remote:open5gs-upf:gtpu=44ms:1ms  ← IXP delay (Paris-Frankfurt)
N6_DELAY_VALUE=40ms                             ← DN latency (Paris-Boston)
N6_DELAY_JITTER=1ms

What this simulates:
- UE is in Frankfurt (VPLMN)
- Home network PDN gateway is in Paris (HPLMN with Boston server connection)
- Control plane: 44ms IXP delay between Frankfurt and Paris
- Data plane: 40ms to Boston (routed through Paris HPLMN)
- Result: Home routing with remote DN access
```

### Scenario 4: HR-IPsec Intercontinental (Sydney VPLMN, Frankfurt DN)

```
Generated Config: hr-ipsec_lat150_jit2_dn_sydney_to_frankfurt_pld1400.conf

ROAMING_MODE=hr
IPSEC_ENABLED=true
DELAY_RULE_1=local:open5gs-upf:ipsec=150ms:2ms  ← IPsec tunnel delay
DELAY_RULE_2=remote:open5gs-upf:ipsec=150ms:2ms ← IPsec tunnel delay
N6_DELAY_VALUE=150ms                             ← DN latency (Sydney-Frankfurt)
N6_DELAY_JITTER=2ms

What this simulates:
- UE is in Sydney (VPLMN) with IPsec tunnel to Frankfurt (HPLMN)
- Maximum intercontinental delay scenario
- Control plane: 150ms through IPsec tunnel + 2ms jitter
- Data plane: 150ms to Frankfurt server + 2ms jitter
- Result: Highly realistic scenario for international roaming with encryption
```

## Parameter Combinations Generated

### For Single Payload Size (56 bytes):

```
Non-roaming:
  Non-roaming → Frankfurt (0ms)
  Non-roaming → Paris (0ms)
  Non-roaming → Boston (0ms)
  Non-roaming → Sydney (0ms)
  = 4 configs

LBO (per latency, e.g., 16ms):
  Frankfurt → Frankfurt (0ms)
  Frankfurt → Paris (16ms)
  Frankfurt → Boston (44ms)
  Frankfurt → Sydney (150ms)
  Paris → Frankfurt (16ms)
  ... [all 4×4 = 16 combinations per mode]
  = 16 configs per latency

Per Roaming Mode:
  3 latencies × 16 combinations = 48 configs per payload size
  2 payload sizes × 48 = 96 configs per mode
  4 modes × 96 = 384 roaming configs

Total: 4 + 384 = 388 configs
```

## Filtering Generated Configs

### By Roaming Mode
```bash
ls configs/generated/hr_lat*.conf      # All HR configs
ls configs/generated/lbo_*.conf        # All LBO configs
ls configs/generated/non_roaming*.conf # Non-roaming only
```

### By IXP Latency
```bash
ls configs/generated/*_lat16_*         # All 16ms IXP delay
ls configs/generated/*_lat44_*         # All 44ms IXP delay
ls configs/generated/*_lat150_*        # All 150ms IXP delay
```

### By DN Path
```bash
ls configs/generated/*_dn_frankfurt_* # All FROM Frankfurt
ls configs/generated/*_to_sydney_*     # All TO Sydney
ls configs/generated/*_frankfurt_to_paris_* # Frankfurt→Paris specifically
```

### By Payload Size
```bash
ls configs/generated/*_pld56.conf      # All with 56-byte payloads
ls configs/generated/*_pld1400.conf    # All with 1400-byte payloads
```

## Batch Execution Examples

### Test All Non-Roaming Scenarios
```bash
./batch_runner.sh configs/generated/non_roaming*.conf
```

### Test LBO with 16ms IXP Delay Only
```bash
./batch_runner.sh configs/generated/lbo_lat16_jit1_dn_*.conf
```

### Test All HR Scenarios with Sydney Server
```bash
./batch_runner.sh configs/generated/hr_*_to_sydney_*.conf
```

### Test HR-IPsec with Large Payload (1400 bytes)
```bash
./batch_runner.sh configs/generated/hr-ipsec_*_pld1400.conf
```

### Full Test Suite with 2 Iterations
```bash
./batch_runner.sh --all -i 2
```

## Results Analysis

### Output Fields Include N6 Delays

Each test result in `batch_results_*.json` includes:

```json
{
  "iteration": 1,
  "status": "success",
  "timing_ms": {
    "total": 5234,
    "startup_to_registration": 2100,
    "registration_to_pdu_init": 1500,
    "pdu_setup": 1634
  },
  "ping_results": {
    "success": 10,
    "fail": 0,
    "avg_ms": 125,
    "min_ms": 50,
    "max_ms": 201
  },
  "download_results": {
    "success": true,
    "size_bytes": 10485760,
    "speed_bytes_per_sec": 84210,
    "time_total_sec": 124.5
  }
}
```

### Correlation Analysis

The config filename encodes all delay parameters:
```
hr_lat44_jit1_dn_paris_to_boston_pld56.conf

├─ hr:              Roaming mode
├─ lat44:           IXP signaling delay 44ms
├─ jit1:            IXP jitter 1ms
├─ paris_to_boston: DN path (40ms latency, 1ms jitter)
└─ pld56:           Payload size 56 bytes
```

Can correlate performance metrics against each parameter independently.

