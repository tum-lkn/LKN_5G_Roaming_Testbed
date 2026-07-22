# DN Latency Integration - Quick Reference Guide

## TL;DR

The testbed automation now supports **4 geographic server locations** (Frankfurt, Paris, Boston, Sydney) with **realistic data network (DN/N6) latencies** between them.

- **Generated configs**: 388 total (4 + 384)
- **Non-roaming**: 4 configs (1 per location)
- **Roaming modes**: 96 configs each (LBO, HR, HR-IPsec, HR-Remote-UPF)
- **Multiplier vs old**: +2.5× more roaming scenarios (from 96 to 384)

## What Changed

### 1. batch_runner.sh
- Added nested loops for DN location source and target
- For each roaming mode, iterate through: latencies → DN sources → DN targets → payloads
- Generated configs include bidirectional N6 delays (UPF + server)

### 2. Generated Configs
- New naming: `{mode}_lat{ixp}_jit{jitter}_dn_{source}_to_{target}_pld{payload}.conf`
- Each config includes **both**:
  - **IXP delays** (signaling/control plane): DELAY_RULE_1-4
  - **DN delays** (data plane): N6_DELAY_VALUE/JITTER + N6_SERVER_DELAY_VALUE/JITTER

### 3. testbed_automation.sh
- **No changes needed** ✓
- Already has full N6 delay parsing and application
- Roaming mode logic already implemented (applies delays to local/remote UPF as needed)

## Key Parameters

Every generated config includes these N6 settings:

```bash
N6_DELAY_ENABLED=true                    # Always enabled
N6_DELAY_VALUE=<latency>ms               # UPF ogstun delay
N6_DELAY_JITTER=<jitter>ms               # Optional jitter
N6_SERVER_DELAY_ENABLED=true             # Always bidirectional
N6_SERVER_DELAY_VALUE=<latency>ms        # Must equal N6_DELAY_VALUE
N6_SERVER_DELAY_JITTER=<jitter>ms        # Must equal N6_DELAY_JITTER
```

## DN Latency Matrix

Latencies (in milliseconds) between server locations:

|  From  → To | Frankfurt | Paris | Boston | Sydney |
|------------|-----------|-------|--------|--------|
| **Frankfurt** |     0     |  16   |   44   |  150   |
| **Paris**     |    16     |   0   |   40   |  139   |
| **Boston**    |    44     |  40   |    0   |  104   |
| **Sydney**    |   150     | 139   |  104   |    0   |

## Quick Commands

### Run All 388 Scenarios
```bash
cd VPLMN
./batch_runner.sh --all
```

### Run Specific Subset
```bash
# All LBO with 16ms IXP delay
./batch_runner.sh configs/generated/lbo_lat16_jit1_dn_*.conf

# HR to Sydney servers only
./batch_runner.sh configs/generated/hr_*_to_sydney_*.conf

# Non-roaming scenarios
./batch_runner.sh configs/generated/non_roaming*.conf
```

### Run With Multiple Iterations
```bash
# Run each of 388 configs twice
./batch_runner.sh --all -i 2

# With gtp5g reload every 5 runs
./batch_runner.sh --all -i 2 -r 5
```

## What Gets Tested

### Non-Roaming (4 scenarios)
- Frankfurt server (0ms DN latency)
- Paris server (0ms DN latency - tested from Frankfurt)
- Boston server (0ms DN latency - tested from Frankfurt)
- Sydney server (0ms DN latency - tested from Frankfurt)

### LBO / HR / HR-IPsec / HR-Remote-UPF (96 each)

For each of the 3 IXP latencies (16, 44, 150ms):
- 4 DN sources (Frankfurt, Paris, Boston, Sydney)
- 4 DN targets per source
- 2 payload sizes (56 bytes, 1400 bytes)
- = 3 × 4 × 4 × 2 = 96 per mode

### Combined IXP + DN Scenarios

Example: **HR mode, 44ms IXP, Paris→Boston DN**
```
Config: hr_lat44_jit1_dn_paris_to_boston_pld56.conf

Simulates:
- UE roaming from Frankfurt (VPLMN) to Paris IXP (44ms signaling latency)
- Home gateway in HPLMN
- Data traffic routes through Boston datacenter (40ms DN latency)
- Full realistic roaming + geographic distribution
```

## Files Generated

All in: `/VPLMN/configs/generated/`

- `non_roaming_dn_*.conf` (4 files)
- `lbo_lat*_dn_*.conf` (96 files)
- `hr_lat*_dn_*.conf` (96 files)
- `hr-ipsec_lat*_dn_*.conf` (96 files)
- `hr-remote-upf_lat*_dn_*.conf` (96 files)

**Total: 388 configuration files**

## Implementation Details

### How Delays Are Applied

1. **IXP Signaling Delays** (control plane)
   - Applied via `DELAY_RULE_*` to GTP-U and SEPP N32 interfaces
   - Affects PDU session establishment, SMS, etc.

2. **DN Data Delays** (data plane)
   - Applied to UPF's ogstun interface via `tc qdisc`
   - Location: Local UPF (LBO/non-roaming) or Remote UPF (HR modes)
   - Applied symmetrically on server side for bidirectional testing

3. **Mode-Specific Application**
   ```
   Non-roaming:  DN delay → local UPF (VPLMN handles everything)
   LBO:          DN delay → local UPF (local breakout)
   HR:           DN delay → remote UPF (home routing)
   HR-IPsec:     DN delay → remote UPF (with encryption)
   ```

## Results Integration

Each test run records:
- Config filename (encodes all parameters)
- Ping results (affected by both IXP + DN delays)
- Download/video results (affected by DN latency)
- iperf3 results (throughput with DN delay)
- Timing metrics

Can correlate performance against specific IXP latency, DN location pair, and payload size.

## Example: Analysis Workflow

```bash
# 1. Run all HR tests to Paris datacenter
./batch_runner.sh configs/generated/hr_*_to_paris_*.conf

# 2. Results saved to: results/batch_results_TIMESTAMP.json

# 3. Compare performance metrics:
#    - hr_lat16_jit1_dn_frankfurt_to_paris_pld56 (close, small payload)
#    - hr_lat150_jit2_dn_sydney_to_paris_pld1400 (far, large payload)
#    - Understand impact of latency on download speed, iperf throughput, etc.

# 4. Generate plots with plotting scripts
python3 results/plotting/plotting_performance_metrics.py
```

## Validation Checklist

- [x] 388 total configs generated
- [x] N6 delay parameters in all configs
- [x] Bidirectional delays (UPF + server)
- [x] Realistic latency values from real-world ping data
- [x] Proper roaming mode logic (local vs remote UPF)
- [x] Config naming convention consistent
- [x] testbed_automation.sh reads all parameters
- [x] All modes supported (non-roaming, LBO, HR, HR-IPsec, HR-Remote-UPF)

## Next Steps

1. **Run test batch**: `./batch_runner.sh --all`
2. **Monitor results**: Check `results/batch_results_*.json`
3. **Analyze performance**: Correlate ping/download/iperf results with latencies
4. **Adjust parameters**: Modify `main.conf` if needed
5. **Generate reports**: Use plotting scripts for visualization

## Documentation

- **Technical reference**: [DN_LATENCY_TECHNICAL_REFERENCE.md](DN_LATENCY_TECHNICAL_REFERENCE.md)
- **This file**: Quick Reference Guide

## Support

If you need to:
- **Add more locations**: Edit `DN_LOCATIONS` and add corresponding `DN_LATENCIES_*` arrays in `main.conf`
- **Change latency values**: Update the latency matrices in `main.conf`
- **Modify payload sizes**: Edit `PING_PAYLOADS` array
- **Adjust jitter**: Modify `JITTERS` array

All changes will be reflected automatically in the next `batch_runner.sh --all` run.
