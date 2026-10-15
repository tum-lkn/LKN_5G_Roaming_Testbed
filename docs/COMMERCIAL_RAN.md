# Commercial RAN: gNB + Dongle UE

This document describes how the testbed drives a **real RAN** — a commercial gNB (e.g. the DSK) with USB-dongle UEs attached to it — as an alternative to PacketRusher, and how the measurements taken through it work and should be read.

The feature is **optional and off by default**. Enabling and disabling it is covered in [VPLMN/README.md → Commercial RAN](../VPLMN/README.md#commercial-ran-gnb--dongle-ue); this document covers everything after that.

---

## Table of Contents

- [Overview](#overview)
- [The Dongle Scripts](#the-dongle-scripts)
- [Selecting a Dongle](#selecting-a-dongle)
- [Where Each Test Runs](#where-each-test-runs)
- [Control-Plane Timings (Registration / PDU Setup)](#control-plane-timings-registration--pdu-setup)
- [Running the Automation and the Batch Runner with the Dongle](#running-the-automation-and-the-batch-runner-with-the-dongle)
  - [RAN Recovery in the Batch](#ran-recovery-in-the-batch)
- [The "ims" Requests](#the-ims-requests)
- [AT Commands on the Dongle](#at-commands-on-the-dongle)
- [USB Link Speed: Dongles Are Kept on USB 2](#usb-link-speed-dongles-are-kept-on-usb-2)
- [Ping Target and Its Fallback](#ping-target-and-its-fallback)
- [Troubleshooting](#troubleshooting)

---

## Overview

Four machines are involved. The VPLMN PC runs the core and the WebUI; everything RAN-side is reached from it over SSH.

```
   VPLMN PC (core + WebUI)                     gNB host
   ──────────────────────                      ────────
   AMF :38412  ◄──────── NGAP ────────────────  gNB (docker compose)
   UPF (N3)    ◄──────── GTP-U ───────────────       ▲  radio
   WebUI, batch                                      │
   lib/dsk/dongle_*.sh ──SSH (jump)──┐          Dongle A / Dongle B
                                     ▼           (USB modems, UE)
   Dongle control host ───── USB (RNDIS) ─────────────┘
```

| Machine | Role | Configured in |
|---|---|---|
| VPLMN PC | 5G core, WebUI, the dongle scripts (`VPLMN/lib/dsk`), NGAP capture (tshark) | — |
| gNB host | The commercial gNB, run with `docker compose` | `GNB_*` in `VPLMN/webui/dongle.env` |
| Dongle control host | The dongles are plugged in here by USB. The scripts jump through it to reach a dongle; it also runs the page-load browser. Nothing is stored there. | `DONGLE_*` in `VPLMN/webui/dongle.env` |
| Dongles | The UEs. Each is a small Linux modem reachable over its USB link (`192.168.44.1`, `192.168.43.1`, SSH port 8822) | `dongles` list in `VPLMN/webui/backend/app.py` |

The WebUI and the batch automation run the dongle scripts on the VPLMN PC. A script reaches its dongle over SSH with the control host as jump host (one multiplexed connection), and prints machine-readable lines (`RESULT_JSON …`, `PING_JSON …`, …) that the WebUI parses. The results use the same keys as the PacketRusher path, so the dashboard renders both the same way.

---

## The Dongle Scripts

The dongle scripts live in this repository under `VPLMN/lib/dsk/` and run on the VPLMN PC. (Up to 2026-10, they lived on the control host under `~/data_roaming/`.) The control host is still needed for three things that are physically tied to it, and receives them per call without storing anything:

1. **The way in:** the dongles are only reachable on the control host's USB networks, so every SSH to a dongle jumps through it.
2. **The USB 2 fix and the ICMP gate:** both act on the control host's own USB ports and links.
3. **The page-load test:** the browser has to run where the dongle is plugged in. `dongle_webpage.sh` copies itself there for each run and removes itself afterwards.

| Script | What it does |
|---|---|
| `dongle_env.sh` | Shared settings and helpers, sourced by all the others: the control host and the dongles' root password (both read from `webui/dongle.env`, no secrets in the file itself), the jump-host SSH options, `REMOTE_TARGET`, the ping fallback. Every value is `${VAR:-default}`, so callers can override it. |
| `dongle_usb.sh` | Shared helper (sourced, not run): keeps every dongle's USB link at USB 2. See [USB Link Speed](#usb-link-speed-dongles-are-kept-on-usb-2). |
| `dongle_status.sh` | Cheap liveness probe the WebUI polls every few seconds: is the dongle attached, and what is its UE IP. Also moves any dongle that shows up on USB 3 to USB 2. |
| `dongle_cp_setup.sh` | Control-plane measurement: starts tshark locally (`sudo`), cycles the dongle so it re-registers, and parses registration / PDU session timing from the NGAP capture. `--mode reboot` (default) reboots the dongle; `--mode airplane` switches its radio off and on instead. `--parse-only <pcap>` re-parses an existing capture without touching the dongle. |
| `dongle_cp_airplane.sh` | The same measurement in airplane mode, under its own name — a thin wrapper around `dongle_cp_setup.sh --mode airplane`. |
| `dongle_exec.sh` | Runs one command on the selected dongle and passes its output back. The automation uses it to run its ping / curl / iperf3 tests on the dongle. |
| `dongle_ping.sh` | Pings from the dongle through the 5G bearer. |
| `dongle_iperf.sh` | iperf3 from the dongle against a server behind the core. |
| `dongle_download.sh` | HTTP(S) download on the dongle (curl), with the connection timing breakdown. |
| `dongle_webpage.sh` | Browsertime page-load test. The browser runs on the control host (the script ships itself there per run), with its traffic pinned through the dongle — see below. |

Requirements on the VPLMN PC: `sshpass`, `tshark`, `bc`, `jq`, `script` (util-linux), passwordless `sudo bash` (for tshark), and key-based SSH to the control host and the gNB host. `setup.sh` installs the packages and the sudo rule; `lib/features/set-dongle-mode.sh on` installs the SSH key on both hosts (`ssh-copy-id`, asks each host's password once) and asks for the dongles' root password, stored as `DONGLE_SSH_PASS` in `VPLMN/webui/dongle.env` (mode `600`). On the control host: `docker` (the user must be in the `docker` group) and `python3`.

---

## Selecting a Dongle

Two dongles can be attached at the same time; they share the same gNB. The WebUI's UE panel has a selector, and **only the selected dongle is probed, restarted and measured** — the other is not touched. The selection is explicit on purpose: a testbed that silently picked one would produce measurements nobody can attribute afterwards.

The WebUI passes the selection to the scripts as `SSH_HOST` / `SSH_PORT` in front of the command, which overrides the defaults in `lib/dsk/dongle_env.sh`. Every result is stamped with the dongle it came from.

---

## Where Each Test Runs

| Test | Runs on | Traffic crosses the USB link? |
|---|---|---|
| Ping, iPerf, Download | **The dongle itself** (it has real `ping`, `iperf3`, `curl`) | No |
| Webpage load | **The control host** — a browser cannot run on the modem (227 MB RAM, read-only rootfs) | **Yes** |

For the webpage test, `dongle_webpage.sh` runs Browsertime in Docker on the control host, attached to a macvlan network whose only gateway is the dongle. The container has no route that does not cross the radio, so it cannot silently measure the lab LAN instead. The extra USB hop costs well under a millisecond against the same target.

Only **Load** (the browser's `loadEventEnd`) is the page-load time. **Net idle** is when the network went fully quiet and includes background traffic after the page had loaded (analytics, lazy loads, polling). A run whose page never fired its load event is reported as a failed load, not with a substituted number.

---

## Control-Plane Timings (Registration / PDU Setup)

PacketRusher reports its timings from the UE's own log. The dongle has no such log we can read, so `dongle_cp_setup.sh` measures them **from the core side**: it captures NGAP on the VPLMN while the dongle is made to re-register, and reads the timestamps from that capture. Captures are kept on the VPLMN under `/tmp/dongle_cp_*.pcap`.

### Two ways to make the dongle re-register

| | Reboot (`dongle_cp_setup.sh`, WebUI **Restart Dongle**) | Airplane toggle (`dongle_cp_airplane.sh`, WebUI **Airplane Toggle**) |
|---|---|---|
| How | Reboots the whole dongle | Switches the modem's radio off and on (`AT+CFUN=4`, then `AT+CFUN=1`); the dongle's Linux side keeps running |
| Whole run | ~2 minutes | ~20 seconds |
| Registrations the core sees | 2 (see below) | 1 |
| Registration / PDU setup, no delay | 87 / 70 ms | 80 / 80 ms |
| Same, 50 ms SEPP ⇄ SEPP delay per direction | 596 / 279 ms | 585 / 255 ms |

Both use the same capture, the same parsing and the same result format (the result's `method` field says which was used), and both start with a deregistration, so the registration goes to the home network. The numbers agree within normal run-to-run variation. **Use the airplane toggle for measurements**; the reboot is the one to use when the dongle itself needs restarting.

Neither guarantees authentication. The modem keeps its security context across an airplane toggle (registration with its 5G-GUTI, no authentication), and usually — not always — across a reboot.

### What the dongle does after a reboot

Every reboot follows the same pattern (times after boot, from a boot traced on the dongle and the core at once):

| Time | Event |
|---|---|
| ~16 s | The modem registers on its own (**registration #1**). Nothing requests the internet PDU session yet. |
| 24 s | The vendor connection manager, `xap_core`, starts. |
| 32–48 s | The modem goes **off the air** without deregistering. |
| ~75 s | The gNB notices and releases it (`radio-connection-with-ue-lost`). |
| ~105–110 s | The modem comes back and registers again (**registration #2**). |
| < 1 s later | `xap_core` requests the **internet** PDU session; it is up 0.1 s after that. |

So the ~1.5 minutes are not a slow start: the modem is registered at 16 s, is then taken offline for about a minute, and the PDU session follows the second registration immediately. The kernel log shows no modem crash in that window and `xap_core` contains routines for switching the modem to low-power mode and back, so this is most likely its start-up sequence; which step takes the minute is not visible (its debug log is off and its configuration is encrypted). The gap is the same with the modem's "ims" profile removed.

The two registrations are not alike. The first goes to the home network (in roaming: several UDM round trips over N32) and is the one measured. The second varies: it is often answered by the AMF from the context the first left behind (no N32, ~50 ms whatever the delay), and sometimes — when the modem comes back without its security context — runs a full authentication.

Probing a dongle with AT commands while it boots slows this down further (registration at ~215 s instead of ~110 s in one traced boot), so leave it alone until it is up.

### Definitions

| Field | Measured as |
|---|---|
| **Registration** | The **first** registration that completed after the dongle was cycled (the only one in airplane mode): Registration Request (`InitialUEMessage`) → `InitialContextSetupResponse`. |
| **PDU Setup** | The dongle's PDU Session Establishment Request → `PDUSessionResourceSetupResponse`. It starts at the NAS request, not at `PDUSessionResourceSetupRequest`: everything the core does (SMF, N4, and in roaming the lookups in the home network over N32 — the home UDM, plus the home SMF in HR) happens between the two. NAS is ciphered, so the request is identified by behaviour: the last uplink NAS message before the N2 setup that the AMF did not answer on its own (the rejected "ims" requests are answered immediately). |
| **Total** | Registration + PDU Setup: the time the network spent on the dongle's requests. |
| Wall clock / dongle-side gap | Logged separately: the time the dongle spends between the two — about 1.5 minutes after a reboot (see above), about half a second after an airplane toggle — is **not** network time and is excluded from Total. |

As a reference, on this bench with a 50 ms SEPP ⇄ SEPP delay (per direction): registration 81 → 596 ms (+5 N32 round trips), PDU setup 84 → 279 ms (+2 round trips). That run used an LBO subscriber, so the PDU setup's N32 round trips were home-UDM lookups; an HR subscriber adds the vSMF ⇄ hSMF exchange on top.

### Comparing with PacketRusher

The numbers are comparable in scale but not identical in definition:

- PacketRusher always registers from scratch **with authentication**; the dongle's measured registration normally has none, so it is shorter for the same delay.
- PacketRusher's times come from the UE's log, the dongle's from the core's capture — the dongle's therefore exclude the radio time before the first NGAP message.

The dashboard shows these definitions as tooltips on both UE result boxes.

---

## Running the Automation and the Batch Runner with the Dongle

`testbed_automation.sh` and `batch_runner.sh` were written around PacketRusher. With `UE_TYPE=dsk` in the config they run the same process against a dongle (`lib/automation/dsk.sh`):

```
UE_TYPE=dsk          # packetrusher (default) | dsk
DSK_DONGLE=b         # a | b
DSK_CYCLE=airplane   # airplane (default) | reboot
```

| Step | PacketRusher | Dongle (`UE_TYPE=dsk`) |
|---|---|---|
| Bring the UE up, take registration / PDU timings | Start a fresh container; timings from its log | `dongle_cp_setup.sh --mode <DSK_CYCLE>`; timings from the NGAP capture |
| Ping, download, iperf3 | `ping` / `curl` / `iperf3` inside its VRF | The same commands, run on the dongle (`dongle_exec.sh`) |
| Webpage test | Browsertime in its network namespace | `dongle_webpage.sh` on the control host |
| Video test | yes | not available — skipped |
| End of iteration | Remove the container | Nothing; the next iteration cycles the dongle again |

`UE_TYPE=dsk` needs commercial RAN support enabled (`DONGLE_ENABLED=true` in `webui/dongle.env`). Otherwise `testbed_automation.sh` stops before touching the gNB, and `batch_runner.sh` refuses any batch containing such a config.

**What happens per config**

1. Preflight: the control host, the dongle scripts and the gNB host must be reachable, and **the SIM in the dongle must fit the roaming mode** — read with `AT+CIMI` and checked against the ranges the cores seed (HR `001010000001001–…1101`, LBO `001010000000001–…0101`, non-roaming `999710000000001–…0101`). A wrong SIM ends the run with exit status 42 before anything is restarted.
2. Both cores are restarted, as for PacketRusher.
3. **The gNB is restarted** — it does not reconnect to a restarted AMF by itself — and waited for until the AMF reports it connected.
4. The dongle is re-registered with an airplane toggle and waited for until the **new AMF** has a PDU session for it. (The dongle's own view is not enough: after a core restart it keeps its old session address for a while.)
5. The iterations run.

**Before every iteration** the RAN is checked and repaired: if the AMF was restarted since the gNB connected (a core crash), if the gNB container is down, or if no gNB is connected to the AMF, the gNB is restarted and the dongle re-registered as above. If only the dongle is not attached, it is waited for. **The dongle is never restarted to recover.**

**Results** go to `results_dsk/` (PacketRusher's stay in `results/`). The WebUI Results and Plots tabs switch between the two (**PacketRusher / Dongle**); dongle plots are stored separately. The files have the same structure, plus `ue_type`, `dsk_dongle`, `dsk_cycle` and `ue_registration_has_authentication: false` in `test_info`. In the timings, `registration_to_pdu_init` is the registration, `pdu_setup` the session setup, `startup_to_registration` is 0 (there is no container), and `total` is the sum of the two procedures.

**Differences to keep in mind when comparing with PacketRusher**

- PacketRusher registers a new subscriber with authentication every iteration; the dongle re-registers the same subscriber without authentication.
- One SIM, so one roaming mode at a time. In a batch, configs needing another SIM are set aside and picked up with `--resume` after the swap — see [BATCH_RUNNER.md](BATCH_RUNNER.md#stop-and-resume).
- Delay rules on the N3 Docker network do not apply: the real gNB reaches the core over the physical network.

From the WebUI: the Automation tab's config form has a **UE** selector (shown when the commercial RAN is enabled), and the Batch Runner tab a **Resume interrupted batch** option and a **Resume last batch** button.

### RAN Recovery in the Batch

The O-RU's timing drifts after some hours of operation: first the uplink degrades, then the dongle cannot attach. The batch detects this and recovers the RAN.

- **Detection:** after each iteration, a failed iteration, or setup > `DSK_DEGRADED_SETUP_MS` (300 ms) together with iperf loss > `DSK_DEGRADED_LOSS_PCT` (50 %), stops the run with exit status 43. So does a RAN that does not come up at the start of a run.
- **Rollback:** the batch moves that run's result and those of up to `DSK_ROLLBACK_RUNS` (3) DSK runs before it into `results_dsk/discarded_<date>/` (nothing is deleted), then measures them again.
- **Recovery** (`testbed_automation.sh --recover-ran <config>`): RU reboot over its CLI → wait `DSK_RU_COOLDOWN` (600 s) → RU reports RF Ready → gNB restart → dongle reboot → attach. Up to `DSK_RECOVERY_ATTEMPTS` (3) attempts.
- **gNB check after every gNB restart:** the gNB must stay up and connected to the AMF for `DSK_GNB_STABLE_WAIT` (30 s), and the RU must deliver ≥ `DSK_RU_MIN_ON_TIME_PCT` (90 %) of U-plane packets on time. The RU updates these counters only every ~35–40 s; the check waits up to `DSK_RU_COUNTER_WAIT` (120 s) for them to move.
- **Scheduled:** the same recovery runs before the first DSK run of a batch and after every `DSK_RU_REBOOT_EVERY` (10) DSK runs.
- **Stops the batch:** a failed recovery, a degraded first run after a recovery, or a degradation after `DSK_MAX_RECOVERIES` (5) recoveries.

The RU login is in `webui/dongle.env` (`RU_HOST`, `RU_USER`, `RU_PASS`, `RU_ENABLE_PASS`; asked by `set-dongle-mode.sh on`). The CLI is reached from the gNB host. Without it, no recovery and no RU check. The dongle is rebooted only during a recovery, never for a measurement.

Where the settings live: `DSK_ROLLBACK_RUNS`, `DSK_MAX_RECOVERIES`, `DSK_RU_REBOOT_EVERY` and `DSK_MAX_CONSECUTIVE_FAILURES` at the top of `batch_runner.sh`; `DSK_DEGRADED_SETUP_MS`, `DSK_DEGRADED_LOSS_PCT` and `DSK_RU_COOLDOWN` in the config; the rest as environment variables (defaults in `lib/automation/dsk.sh`).

---

## The "ims" Requests

A dongle in its factory state asks for a PDU session named **"ims"** right after every registration. The core does not offer that DNN for the dongle's subscriber, so the AMF rejects it and logs `Ue requested DNN "ims" Not Supported OR Not Subscribed in the Slice`, in bursts of five, 16 s apart.

- **Where it comes from:** the modem itself. It has its own PDP profiles underneath the web UI's APN setting (`AT+CGDCONT?`): profile 1 is the internet session, **profile 2 is `ims`**, profile 3 is `sos`. The modem requests profile 2 on its own — the first request arrives before `xap_core` has even started. The 16 s spacing is the standard NAS retransmission timer for a PDU session request that got no session-level answer (T3580).
- **Is it a problem?** No. The rejection takes ~3 ms, does not delay the internet session, and the timing parser ignores it. It is log noise.
- **Do not fix it in the core.** Adding an "ims" DNN for the subscriber makes the dongle bring up two PDU sessions, which makes both the data path and the measurement ambiguous.
- **To remove it:** delete profile 2 on the dongle. The requests stop from the next registration, and the deletion survives a reboot. Clearing only the profile's IMS flags (`AT$QCPDPIMSCFGE=2,0,0,0`) is **not** enough.

```bash
# on the dongle — save the current state first
at_cmd 'AT+CGDCONT?' -t 3
at_cmd 'AT$QCPDPIMSCFGE?' -t 3

# delete the "ims" profile
at_cmd 'AT+CGDCONT=2' -t 4

# restore it (values as shipped; compare with what you saved)
at_cmd 'AT+CGDCONT=2,"IPV4V6","ims"' -t 4
at_cmd 'AT$QCPDPIMSCFGE=2,1,0,1' -t 4
```

Removing it does not make the dongle come back faster after a reboot.

---

## AT Commands on the Dongle

The dongle has an `at_cmd` tool for the modem's AT channel: `at_cmd '<command>' -t <seconds>`.

- **Always give it a command.** Started without one, it spins in a busy loop until killed.
- Useful read-only queries: `AT+CGDCONT?` (profiles), `AT+CGACT?` (which are active), `AT+CGPADDR` (addresses), `AT+C5GREG?` (registration; `0,5` = registered, roaming), `AT+CFUN?` (`1` = radio on, `4` = airplane mode), `at@mbn?` (active carrier configuration).
- Do not poll it while the dongle is booting (see [What the dongle does after a reboot](#what-the-dongle-does-after-a-reboot)).
- From the VPLMN PC: `SSH_HOST=<dongle> VPLMN/lib/dsk/dongle_exec.sh at_cmd 'AT+CGDCONT?' -t 3`.
- `AT+COPS=?` (network scan) blocks the AT channel for one to two minutes; other queries return nothing until it finishes.

---

## USB Link Speed: Dongles Are Kept on USB 2

**Symptom this prevents:** a few seconds into a webpage load test, the dongle stops responding — no ping, no SSH — while it still shows as connected and the core and gNB log nothing. Only unplugging it brings it back.

**Cause:** at SuperSpeed (USB 3.x) the dongle's RNDIS/IPA data path stalls for good under traffic forwarded across the USB link. The radio and the PDU session stay up, which is why nothing shows in the core. The webpage test is the only test whose traffic crosses that link, so it is the only one that triggers it. Measured with one dongle, one cable and one port: at 10 Gbps the link died on the first page load every time; at 480 Mbps it survived every run. A dongle that negotiates USB 2 on its own never shows the fault.

**What the scripts do:** `dongle_usb.sh` finds every RNDIS device on the control host that is on a SuperSpeed link and switches off the SuperSpeed half of the port it is plugged into (`/sys/bus/usb/devices/<hub>/<port>/disable`). The dongle re-attaches over the port's USB 2 half within seconds. It runs:

- on every `dongle_status.sh` poll, so a freshly plugged dongle is moved to USB 2 before any test can start, and
- at the start of `dongle_webpage.sh`, as a safety net.

Writing the port's `disable` file needs root; it is done from a one-off privileged Docker container, so no sudo is needed on the control host. The setting belongs to the **host port**: it survives replugging and rebooting the dongle, and resets only when the control host reboots (the next status poll re-applies it). It affects anything else plugged into that physical port too. 480 Mbps is far above what the radio carries.

Set `DONGLE_ALLOW_SUPERSPEED=1` to leave the links alone, e.g. to reproduce the fault.

---

## Ping Target and Its Fallback

`REMOTE_TARGET` in `dongle_env.sh` (default `10.0.0.30`, the perf server behind the core) is the ping target **and** the iperf and download server.

For pinging only, `resolve_ping_target` falls back to `PING_FALLBACK` (default `8.8.8.8`) when the control host cannot reach `REMOTE_TARGET`, so the "is the dongle up" check in `dongle_cp_setup.sh` does not fail just because the perf server is down. The choice is logged and cached for 60 s. An explicit target always wins: the WebUI's ping panel passes the one you type, and `PING_TARGET` skips the check.

iperf and download keep using `REMOTE_TARGET` — a public host cannot stand in for their server — and fail with a clear error while it is down.

---

## Troubleshooting

### Dongle unreachable after a webpage test, but still "connected"

The USB link stalled (see [USB Link Speed](#usb-link-speed-dongles-are-kept-on-usb-2)). Unplug and replug it once. Check the link speed on the control host:

```bash
for d in /sys/bus/usb/devices/*; do [ -f $d/speed ] && grep -q 05c6 $d/idVendor 2>/dev/null && echo "$(basename $d) $(cat $d/speed) Mbps"; done
```

`480` is USB 2 (good); `5000` / `10000` means the switch did not happen — check that the WebUI's status polling runs (a dashboard must be open) or run `VPLMN/lib/dsk/dongle_status.sh` once by hand on the VPLMN PC.

### `dongle_cp_setup.sh`: "Dongle did not answer within 60s"

The dongle must be attached *and* able to ping the resolved ping target. Check the first lines of the output for the target it chose, and that the gNB is up.

### Registration is ~50 ms regardless of the delay

That is the old measurement, which timed the dongle's *second* registration (answered from the AMF's cache). Make sure the control host has the current `dongle_cp_setup.sh` (its log line reads `Registration : … ms (first completed registration)`), or re-parse a capture with `--parse-only`.

### "Docker refused the macvlan network"

A macvlan network from an interrupted webpage run still holds the dongle's subnet. List and remove it on the control host: `docker network ls`, then `docker network rm <name>`.

### Dongle takes minutes to come back after a reboot

About 1.5–2 minutes is normal (see [What the dongle does after a reboot](#what-the-dongle-does-after-a-reboot)). Two things make it longer: every SSH handshake that lands on the dongle's USB link while it is booting makes its tethering stack reset the USB gadget, and AT commands sent during boot delay the modem's registration. The scripts therefore gate SSH behind a ping; avoid SSHing to a dongle by hand while it reboots. For measurements, use the airplane toggle instead of a reboot.

### The dongle has no radio after an aborted airplane run

Switch it back on, on the dongle: `at_cmd 'AT+CFUN=1' -t 5`. The script does this itself when a run fails; a run killed half-way may not get to it.
