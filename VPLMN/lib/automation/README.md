# lib/ — Subscript Libraries for testbed_automation.sh

`testbed_automation.sh` sources all files in this folder at startup.
Each file groups functions by a single, clear responsibility.
When you need to change something, come here first.

---

## config.sh

**What it contains:**
- `record_timing` / `get_elapsed_ms` / `print_startup_metrics` — measure and display startup phase durations
- `generate_sample_config` — writes a commented `.conf` template to disk
- `parse_config_file` — two-pass parser that reads every key from a `.conf` file into global variables
- `print_config_summary` — box-formatted display of the loaded configuration
- `create_env_file_from_config` — writes the local `.env` file from current config state
- `show_delay_preconfiguration_menu` — interactive menu to build the `DELAY_CONFIGS` array
- `select_mode` — full interactive session: roaming mode, IPsec, security, delays, test types, iterations
- `quick_mode` — shortcut interactive mode that skips network startup

**Edit this file when:** you want to add a new config key, change the interactive menus, or modify startup timing display.

---

## preflight.sh

**What it contains:**
- `preflight_check` — validates Docker, SSH to HPLMN, SSH to perf-server, PacketRusher image, and config folder before a run starts
- `check_service_health_local` / `check_service_health_remote` — check whether the critical containers are running
- `wait_for_services_ready` — polls health checks until services are up or timeout is reached

**Edit this file when:** you want to add or change pre-run checks (new dependency, new SSH target, new config requirement).

---

## delays.sh

**What it contains:**
- `validate_delay_format` / `parse_delay_value` / `build_netem_delay_cmd` — parse and validate `50ms` / `50ms:10ms` delay strings
- `is_host_network_service` / `is_port_delay_service` — predicates used by the delay dispatcher
- `apply_tc_delay` — applies `tc netem` on a host interface (gtpu / ipsec / pfcp / full modes)
- `apply_container_eth0_delay` / `apply_container_port_delay` — inject delay inside a Docker container
- `apply_upf_delay` / `apply_sepp_delay` / `apply_smf_delay` — service-specific delay wrappers
- `apply_preconfigured_delays` — iterates `DELAY_CONFIGS` and dispatches to the right function
- `remove_all_delays` / `remove_n6_delays` — tear down all active `tc` rules
- `apply_n6_ogstun_delay` / `apply_n6_server_delay` / `apply_n6_delays` — N6 merged delay (UPF ogstun + server interface simultaneously)
- `reapply_preconfigured_delays` — called after a testbed restart to restore delays

**Edit this file when:** you want to add a new delay mode, support a new service, or change how `tc netem` rules are built.

---

## networks.sh

**What it contains:**
- `get_host_default_interface` / `get_docker_bridge_for_network` / `get_control_plane_bridge_interface` / `get_n3_bridge_interface` / `get_container_name_for_service` — look up interfaces and container names locally or via SSH
- `check_local_ipsec_status` / `check_remote_ipsec_status` / `check_ipsec_status` — query strongSwan tunnel state
- `stop_all_ipsec` / `start_all_ipsec` / `configure_ipsec` — manage IPsec tunnels on both PCs; `configure_ipsec` also calls `esp_config.sh` for mode selection
- `ensure_docker_networks` / `ensure_remote_docker_networks` — create VPLMN and HPLMN Docker networks if missing
- `start_home_network_internal` / `start_visited_network_internal` — bring up HPLMN and VPLMN containers (run as background subprocesses)
- `start_networks_parallel` — launches both starts in the background and waits for both to finish
- `wait_for_all_services` — runs health checks in parallel then waits for `MIN_NETWORK_STABILIZE_TIME`
- `start_home_network` / `start_visited_network` — legacy sequential versions kept for backward compatibility
- `restart_testbed` — full restart: remove delays → stop containers → reload gtp5g → parallel start → health checks → IPsec → reapply delays

**Edit this file when:** you change Docker network subnets, IPsec configuration, SSH startup logic, or testbed restart behavior.

---

## tests.sh

**What it contains:**
- `strip_ansi` / `docker_timestamp_to_ms` — parsing helpers for PacketRusher log processing
- `cleanup_packetrusher_fast` — removes the PacketRusher container and `val*` interfaces in parallel
- `start_packetrusher_with_timing` — starts the container, waits for PDU session completion, extracts T0/T1/T2/T3 timestamps
- `configure_container_dns` — sets `nameserver 8.8.8.8` inside the container
- `stop_packetrusher` — alias for `cleanup_packetrusher_fast`
- `perform_ping_tests` — runs ping through the UE VRF, live table output, stores `PING_*` globals
- `perform_download_test` / `perform_video_test` — curl-based download tests, stores `DL_*` / `VID_*` globals
- `get_streaming_quality` — maps Mbps to a quality label (4K / 1080p / 720p / etc.)
- `perform_iperf_test` — iperf3 with `--get-server-output`, stores `IPERF_*` globals for both client and server sides
- `test_single_webpage` / `perform_webpage_test` — real-browser page-load timing via the `sitespeedio/browsertime` Docker image (run through the UE's network namespace). URLs are a configurable list (`WEBPAGE_URL_1..N`); `WEBPAGE_BROWSER` (firefox/chrome), `WEBPAGE_ITERATIONS`, and `WEBPAGE_TIMEOUT` control it. Captures TTFB / FCP / LCP / DOM-content-loaded / page-load / total per URL

**Edit this file when:** you add a new test type, change how PacketRusher is started, or modify timing extraction logic.

---

## results.sh

**What it contains:**
- `init_results` — creates the `BATCH_RESULTS_FILE` JSON with test metadata and an empty iterations array
- `add_iteration_result` — appends one iteration's results (ping, download, video, iperf, webpage) as a JSON object using `jq`
- `add_summary` — computes min/max/avg across all iterations and appends a summary block to the JSON
- `print_summary` — reads the JSON and prints a human-readable formatted summary to the log
- `run_batch` — main iteration loop: starts PacketRusher → runs enabled tests → records results → optionally restarts testbed
- `prune_pr_logs` / `prune_browsertime_logs` / `prune_old_logs` — delete old PacketRusher/batch log files and old `browsertime_<timestamp>/` directories, keeping the most recent `MAX_LOG_FILES` of each
- `cleanup` — EXIT trap: removes the PacketRusher container and `val*` interfaces on script exit

**Edit this file when:** you add a new test type (needs new fields in `add_iteration_result` and `add_summary`), change the JSON schema, or modify the batch loop logic.

---

## Scripts that use these libraries

### `testbed_automation.sh`
Sources all 6 lib files. Full automation: starts networks, runs PacketRusher, executes all test types (ping/download/video/iperf/webpage), collects JSON results, and supports config-file mode (`--config`), interactive mode, and quick mode.
