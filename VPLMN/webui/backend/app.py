#!/usr/bin/env python3
"""
Open5GS Roaming Testbed - Backend API Server v2.2
Integrated with testbed_automation.sh, batch_runner.sh, and esp_config.sh.
The IPsec tab now drives the user-supplied esp_config.sh to change ESP cipher
on both peers and restart the tunnel — output streams via the existing job
manager, so the WebUI sees the same nice colored progress that the CLI shows.
"""

from flask import Flask, jsonify, request, Response
from flask_cors import CORS
from flask_socketio import SocketIO, emit
import subprocess
import threading
import time
import json
import os
import re
import base64
import uuid
import signal
import select
import shlex
import shutil
import getpass
import tempfile
from datetime import datetime
from collections import deque
from concurrent.futures import ThreadPoolExecutor, as_completed

try:
    import plotting
    PLOTTING_AVAILABLE = True
    _PLOT_IMPORT_ERROR = None
except Exception as _plot_err:  # matplotlib/numpy missing → degrade gracefully
    PLOTTING_AVAILABLE = False
    _PLOT_IMPORT_ERROR = str(_plot_err)

app = Flask(__name__)
CORS(app, origins="*")
socketio = SocketIO(app, cors_allowed_origins="*", async_mode='threading', logger=False, engineio_logger=False)

# ── Testbed IPs — update via configure_ip_from_env.sh ──
HPLMN_IP = "10.162.149.24"  # HPLMN_IP
VPLMN_IP = "10.162.149.192"   # VPLMN_IP
VPLMN_USER = "wassim"         # VPLMN_USER
HPLMN_USER = "wassim"         # HPLMN_USER
PERF_SERVER_IP = "10.162.149.185"  # PERF_SERVER_IP
PERF_SERVER_USER = "roaming"       # PERF_SERVER_USER
DEFAULT_DN_INTERFACE = "ens18"

# ── Commercial RAN (DSK gNB + USB dongle UE) — optional, OFF by default ──
# Enabled per machine by lib/features/set-dongle-mode.sh (asked by setup.sh),
# which writes webui/dongle.env (gitignored). It is deliberately NOT kept in
# VPLMN/.env: that file is regenerated from scratch by the WebUI core start,
# set-open5gs-mode.sh and the automation, which would silently drop it.
# When disabled, the /api/dongle/* and /api/gnb/* routes answer 404, the SSH
# state watcher is not started and the dashboard hides every dongle/gNB panel.
DONGLE_ENV_FILE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "dongle.env")


def _read_env_file(path):
    vals = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.split("#", 1)[0].strip()
                if "=" in line:
                    k, v = line.split("=", 1)
                    vals[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return vals


_DONGLE_ENV = _read_env_file(DONGLE_ENV_FILE)
DONGLE_ENABLED = _DONGLE_ENV.get("DONGLE_ENABLED", "false").lower() in ("1", "true", "yes", "on")
DSK_DISABLED_MSG = ("Commercial RAN (dongle) support is disabled — "
                    "enable it with lib/features/set-dongle-mode.sh on")


def _dsk_requested_while_disabled(params):
    """True if form params ask for the dongle UE on a testbed without it."""
    return not DONGLE_ENABLED and str((params or {}).get('ue_type') or '').lower() == 'dsk'


def _is_dsk_config(path):
    """A run config that drives the dongle (UE_TYPE=dsk)."""
    try:
        with open(path) as f:
            return any(re.match(r'\s*UE_TYPE\s*=\s*"?dsk"?\s*$', line, re.I) for line in f)
    except OSError:
        return False

# Derived from PERF_SERVER_IP on purpose — configure_ip_from_env.sh / setup.sh
# rewrite that one line, and these follow. Keep them derived, not literal.
DEFAULT_DOWNLOAD_URL = f"http://{PERF_SERVER_IP}:9000/10MB.bin"
DEFAULT_DOWNLOAD_SIZE_LABEL = "10MB"

# Local VPLMN repo dir — derived from this file's location (.../VPLMN/
# webui/backend/app.py) so local paths are correct regardless of which user runs the
# backend. (The backend often runs as root, whose ~ is /root, not the repo's home — using
# ~ there made "start VPLMN" cd into a nonexistent /root/LKN_5G_Roaming_Testbed and silently fail.)
VPLMN_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REPO_ROOT = os.path.dirname(VPLMN_DIR)
# The dongle scripts (dongle_*.sh) live in the repo and run on this host; they
# reach the dongle through the control host (lib/dsk/dongle_env.sh).
DSK_SCRIPT_DIR = os.path.join(VPLMN_DIR, "lib", "dsk")

CONFIG = {
    "local": {"name": "Visited Network (VPLMN)", "host": "localhost", "user": VPLMN_USER, "path": VPLMN_DIR, "ip": VPLMN_IP},
    "remote": {"name": "Home Network (HPLMN)", "host": HPLMN_IP, "user": HPLMN_USER, "path": "~/LKN_5G_Roaming_Testbed/HPLMN", "ip": HPLMN_IP},
    "packetrusher": {"container": "packetrusher", "image": "packetrusher:20250225", "network": "my_second_network", "ip": "192.168.70.190", "config_path": os.path.join(VPLMN_DIR, "configs", "Packetrusher_Configs")},

    # ── Dongle UE (real hardware UE sitting on ANOTHER machine) ──────────
    # The alternative to PacketRusher: a USB dongle attached to a separate
    # PC, the control host. The backend runs the dongle scripts in lib/dsk on
    # THIS host and streams their stdout back to the WebUI (websocket event
    # 'dongle_output'); the scripts reach the dongle by jumping through the
    # control host, which stores nothing (see lib/dsk/dongle_env.sh).
    #
    # IMPORTANT (operator): the gNB must already be UP on that PC *before*
    # the dongle is started from the WebUI, and the attach itself can take
    # a while — watch the VPLMN live logs while it comes up.
    #
    # host / user / port / key_path (the control host, key auth) and
    # DONGLE_SSH_PASS (the dongles' root password; needs `sshpass` here) come
    # from webui/dongle.env, written by lib/features/set-dongle-mode.sh.
    "dongle": {
        "host": _DONGLE_ENV.get("DONGLE_HOST", ""),   # control host of the dongle bench
        "user": _DONGLE_ENV.get("DONGLE_USER", ""),
        "port": int(_DONGLE_ENV.get("DONGLE_PORT") or 22),
        # Unused since the scripts run here: they log in to the control host
        # with the key above (lib/dsk/dongle_env.sh). Kept empty.
        "password": "",
        "key_path": _DONGLE_ENV.get("DONGLE_KEY_PATH", "~/.ssh/id_ed25519"),
        # Control-plane half of the old ping_pcap.sh: reboots the dongle, waits
        # for it to re-register, and prints the NGAP-derived setup timings as a
        # final "RESULT_JSON {...}" line. The user-plane half is dongle_ping.sh,
        # which the ping button will drive separately.
        "script_path": os.path.join(DSK_SCRIPT_DIR, "dongle_cp_setup.sh"),
        "script_args": "",                 # the script takes no arguments
        # User-plane half, driven by the ping panel when the dongle (rather
        # than PacketRusher) is the UE that is up.
        "ping_script_path": os.path.join(DSK_SCRIPT_DIR, "dongle_ping.sh"),
        # Cheap liveness probe the dashboard polls, so the dongle's state is
        # discovered the same way PacketRusher's container state is.
        "status_script_path": os.path.join(DSK_SCRIPT_DIR, "dongle_status.sh"),
        # Throughput and download halves, driven by the iperf/download panels
        # when the dongle (rather than PacketRusher) is the UE that is up.
        # The dongle carries a real iperf3 and curl, so these measure the same
        # things the PacketRusher versions do.
        "iperf_script_path": os.path.join(DSK_SCRIPT_DIR, "dongle_iperf.sh"),
        "download_script_path": os.path.join(DSK_SCRIPT_DIR, "dongle_download.sh"),
        # Page-load half. Unlike the three above it does NOT run on the dongle:
        # the dongle is a modem and cannot host a browser, so browsertime runs
        # in Docker on the control host with its traffic pinned through the
        # dongle by a macvlan network. The script ships itself there for each
        # run and removes itself afterwards. See the script's header for why.
        "webpage_script_path": os.path.join(DSK_SCRIPT_DIR, "dongle_webpage.sh"),
    },

    # ── Which dongle the scripts above talk to ───────────────────────────
    # The settings above describe the CONTROL HOST. The dongle itself is one
    # more SSH hop beyond it, and there is more than one of them on the bench.
    # lib/dsk/dongle_env.sh resolves every setting as
    # "${SSH_HOST:-192.168.44.1}", so pointing a script at a different dongle
    # is a matter of exporting SSH_HOST/SSH_PORT in the command — no second
    # copy of any script.
    #
    # The selection is deliberately explicit rather than auto-detected: both
    # dongles can be attached at once, and a testbed that silently picks one
    # produces measurements nobody can attribute afterwards. Whichever is
    # selected here is the one that gets probed, pinged and measured — the
    # other is not touched at all.
    #
    # Both attach to the SAME gNB, so CONFIG["gnb"] is independent of this.
    "dongles": [
        {"id": "a", "label": "Dongle A", "ssh_host": "192.168.44.1", "ssh_port": 8822},
        {"id": "b", "label": "Dongle B", "ssh_host": "192.168.43.1", "ssh_port": 8822},
    ],
    "active_dongle": "a",

    # ── gNB (the radio the dongle attaches to, on its own machine) ───────
    # gnbup / gnbdown / gnblogs on that host are *aliases* in ~/.bash_aliases,
    # so they only exist in an interactive shell and a plain `ssh host gnbup`
    # cannot find them. We invoke the compose file they expand to instead,
    # which is the real source of truth:
    #   gnbup   -> docker compose -f <compose_file> up -d
    #   gnbdown -> docker compose -f <compose_file> down
    #   gnblogs -> docker compose -f <compose_file> logs -f --tail 10
    # docker runs without sudo as this user (sudo there needs a password).
    # host / user / port / key_path / container / compose_file come from
    # webui/dongle.env (GNB_*), written by lib/features/set-dongle-mode.sh.
    "gnb": {
        "host": _DONGLE_ENV.get("GNB_HOST", ""),
        "user": _DONGLE_ENV.get("GNB_USER", ""),
        "port": int(_DONGLE_ENV.get("GNB_PORT") or 22),
        "key_path": _DONGLE_ENV.get("GNB_KEY_PATH", "~/.ssh/id_ed25519"),
        "container": _DONGLE_ENV.get("GNB_CONTAINER", ""),
        "compose_file": _DONGLE_ENV.get("GNB_COMPOSE_FILE", ""),
        "connect_timeout": 8,
        # No sudo for the script itself: dongle_cp_setup.sh sudo's only for
        # its tshark capture (passwordless `sudo bash` on this host).
        "use_sudo": False,
        # cd here before running. Empty = the directory the script itself
        # lives in (lib/dsk).
        "workdir": "",
        "connect_timeout": 15,
    },

    "results_dir": os.path.join(VPLMN_DIR, "results"),
    "configs_dir": os.path.join(VPLMN_DIR, "configs"),
    "plots_dir": os.path.join(os.path.dirname(os.path.abspath(__file__)), "plots_cache"),
    # Dongle (UE_TYPE=dsk) runs write here instead (lib/automation/dsk.sh), and
    # get their own plots cache: the two UE types are never mixed in one chart.
    "results_dsk_dir": os.path.join(VPLMN_DIR, "results_dsk"),
    "plots_dsk_dir": os.path.join(os.path.dirname(os.path.abspath(__file__)), "plots_cache_dsk"),
    "testbed_dir": VPLMN_DIR,
    "automation_script": os.path.join(VPLMN_DIR, "testbed_automation.sh"),
    "batch_runner_script": os.path.join(VPLMN_DIR, "batch_runner.sh"),
    "esp_config_script_candidates": [
        os.path.join(VPLMN_DIR, "docker", "ipsectunnel", "ipsec_update_configs", "esp_config.sh"),
        os.path.join(VPLMN_DIR, "esp_config.sh"),
        os.path.join(VPLMN_DIR, "scripts", "esp_config.sh"),
        os.path.join(REPO_ROOT, "esp_config.sh"),
    ],
    "post_quantum": {
        # The PQ testbed runs LOCALLY — on the same machine as this WebUI
        # backend — so there's no host/user here and no SSH involved.
        # First match wins. Canonical location: the repo's pq-ike-docker/.
        # ~/ike_eval.sh is the symlink the project suggests for the WebUI —
        # the backend readlink -f's whatever it finds, so results stay
        # anchored to the real project directory either way.
        # ('~' expands through bash to the home of the user running app.py.)
        "script_path_candidates": [
            os.path.join(VPLMN_DIR, "docker", "pq-ike-docker", "ike_eval_docker.sh"),
            "~/pq-ike-docker/ike_eval_docker.sh",
            "~/ike_eval.sh",
            "~/pq-ike-docker/ike_eval.sh",
        ],
        # Docker bits — must match the project's docker-compose.yml / .env
        "vplmn_container": "pq-vplmn",        # PC1 / initiator
        "hplmn_container": "pq-hplmn",        # PC2 / responder
        "image": "pq-ike-strongswan:local",
        # Where the script writes ${TIMESTAMP}_ike_<name>.json / pcaps,
        # relative to the project dir. (The script also symlinks the legacy
        # ike_pq_results name to results/json for back-compat.)
        "results_subdir": "results/json",
        "pcaps_subdir": "results/pcaps",
    },
}

os.makedirs(CONFIG["results_dir"], exist_ok=True)
os.makedirs(CONFIG["configs_dir"], exist_ok=True)
os.makedirs(CONFIG["plots_dir"], exist_ok=True)


def _resolve_esp_config_script():
    for p in CONFIG["esp_config_script_candidates"]:
        if os.path.isfile(p):
            return p
    return CONFIG["esp_config_script_candidates"][0]


CONFIG["esp_config_script"] = _resolve_esp_config_script()

# NOTE: no UPF_IMAGES map anymore. v2.8.0 uses ONE unified UPF for every roaming
# mode, and docker-compose.yml defaults all images (incl. the UPF) to :v2.8.0,
# so the webui no longer writes UPF_IMAGE / OPEN5GS_TAG into .env.

GTPU_PORT = 2152
IPSEC_NAT_T_PORT = 4500
IPSEC_IKE_PORT = 500
ESP_PROTOCOL = 50
PFCP_PORT = 8805            # N4 (SMF <-> UPF)

# `tc filter show` prints u32 matches in hex, never the decimal port/protocol
# numbers used to install them, so delay-mode detection has to match on these.
# Offset 8 = IP protocol byte, offset 20 = UDP src/dst ports.
TC_MATCH_GTPU_DPORT = "00000868/0000ffff"   # udp dport 2152
TC_MATCH_GTPU_SPORT = "08680000/ffff0000"   # udp sport 2152
TC_MATCH_ESP_PROTO = "00320000/00ff0000"    # ip protocol 50 (ESP)
TC_MATCH_NATT_DPORT = "00001194/0000ffff"   # udp dport 4500
TC_MATCH_NATT_SPORT = "11940000/ffff0000"   # udp sport 4500
SEPP_N32_PORTS = (8080, 8081)  # N32 (SEPP <-> SEPP)
CONTROL_PLANE_NETWORK = "my_custom_network"  # docker bridge carrying N4/PFCP

IPSEC_CONN_NAMES = {
    "local": "pc1-to-pc2-gtpu-tunnel-cert",
    "remote": "pc2-to-pc1-gtpu-tunnel-cert"
}

# Mirrors esp_config.sh — keep in sync if that script changes.
IPSEC_MODE_NAMES = {
    "1": "AES-128-GCM (AEAD)",
    "2": "AES-256-GCM (AEAD)",
    "3": "AES-128-CBC + HMAC-SHA256",
    "4": "AES-256-CBC + HMAC-SHA256",
    "5": "NULL + SHA256 (NO ENCRYPTION)",
    "6": "NULL + GMAC (NO ENCRYPTION)",
}

IPSEC_VALID_MODES = set(IPSEC_MODE_NAMES.keys())

# ── PQ config-number -> human label (mirrors ike_eval.sh) ─────────────
PQ_CONFIG_NAMES = {
    "1": "Classical (ECP-256 + RSA)",
    "2": "PQ Key Exchange (ML-KEM-768 + RSA)",
    "3": "PQ Auth (ECP-256 + ML-DSA-65)",
    "4": "Fully PQ (ML-KEM-768 + ML-DSA-65)",
    "5": "All four (full comparison)",
}
PQ_VALID_CONFIGS = set(PQ_CONFIG_NAMES.keys())


# ============================================================================
# DELAY MODES
# ============================================================================

class DelayMode:
    FULL_INTERFACE = "full"
    GTPU_PORT = "gtpu-port"
    # User plane delay that holds whether or not IPsec is up. The N9 SA is
    # scoped to udp/2152 (see /etc/ipsec.conf), so on the wire ESP carries
    # GTP-U and nothing else — matching both is still exactly the user plane,
    # and never touches N32/control plane.
    GTPU_COMBINED = "gtpu-combined"
    IPSEC_TUNNEL = "ipsec-tunnel"
    IPSEC_PEER = "ipsec-peer"
    IPSEC_ESP_ONLY = "ipsec-esp"


# ============================================================================
# CONTAINER CACHE
# ============================================================================

class ContainerCache:
    def __init__(self, ttl_seconds=5):
        self.cache = {}
        self.ttl = ttl_seconds
        self.lock = threading.Lock()

    def get(self, location):
        with self.lock:
            if location in self.cache:
                data, timestamp = self.cache[location]
                if time.time() - timestamp < self.ttl:
                    return data
        return None

    def set(self, location, data):
        with self.lock:
            self.cache[location] = (data, time.time())

    def invalidate(self, location=None):
        with self.lock:
            if location:
                self.cache.pop(location, None)
            else:
                self.cache.clear()

container_cache = ContainerCache(ttl_seconds=5)


# ============================================================================
# SCRIPT JOB MANAGER - Manages running automation/batch/ipsec scripts
# ============================================================================

class ScriptJobManager:
    def __init__(self):
        self.current_job = None
        self.job_history = deque(maxlen=50)
        self.lock = threading.Lock()
        self._process = None
        self._last_completed_job = None

    def start_job(self, job_type, config, command, cwd=None):
        with self.lock:
            if self.current_job and self.current_job['status'] == 'running':
                pid = self.current_job.get('pid')
                if pid:
                    try:
                        os.kill(pid, 0)
                        return None, "Another job is already running"
                    except ProcessLookupError:
                        self.current_job['status'] = 'error'
                        self.current_job['output_lines'] = list(self.current_job['output_lines'])
                        self._last_completed_job = self.current_job.copy()
                        self.job_history.append(self.current_job.copy())
                else:
                    return None, "Another job is already running"
            job_id = str(uuid.uuid4())[:8]
            self.current_job = {
                'id': job_id,
                'type': job_type,
                'config': config,
                'command': command,
                'status': 'running',
                'started_at': datetime.now().isoformat(),
                'output_lines': deque(maxlen=5000),
                'results': None,
                'error': None,
                'pid': None,
                'cwd': cwd or CONFIG["testbed_dir"],
            }
            return job_id, None

    def append_output(self, line):
        with self.lock:
            if self.current_job:
                self.current_job['output_lines'].append(line)
                socketio.emit('script_output', {
                    'job_id': self.current_job['id'],
                    'job_type': self.current_job['type'],
                    'line': line,
                    'timestamp': datetime.now().isoformat()
                })

    def set_pid(self, pid):
        with self.lock:
            if self.current_job:
                self.current_job['pid'] = pid

    def complete_job(self, results=None, error=None, exit_code=None, status=None):
        with self.lock:
            if self.current_job:
                self.current_job['status'] = status or ('error' if error else 'completed')
                self.current_job['completed_at'] = datetime.now().isoformat()
                self.current_job['results'] = results
                self.current_job['error'] = error
                self.current_job['exit_code'] = exit_code
                self.current_job['output_lines'] = list(self.current_job['output_lines'])
                self.job_history.append(self.current_job.copy())
                socketio.emit('script_completed', {
                    'job_id': self.current_job['id'],
                    'job_type': self.current_job['type'],
                    'status': self.current_job['status'],
                    'exit_code': exit_code,
                    'error': error
                })
                self._last_completed_job = self.current_job.copy()
                self.current_job = None
                self._process = None

    def get_current_job(self):
        with self.lock:
            if self.current_job:
                job = self.current_job.copy()
                job['output_lines'] = list(self.current_job['output_lines'])
                return job
            if self._last_completed_job:
                return self._last_completed_job
            return None

    def get_recent_output(self, n=100):
        with self.lock:
            if self.current_job:
                return list(self.current_job['output_lines'])[-n:]
            if self._last_completed_job:
                lines = self._last_completed_job.get('output_lines', [])
                if isinstance(lines, deque):
                    lines = list(lines)
                return lines[-n:]
            return []

    def get_history(self):
        with self.lock:
            history = []
            for job in self.job_history:
                j = job.copy()
                j['output_lines'] = len(job.get('output_lines', []))
                history.append(j)
            return history

    def cancel_job(self):
        # Read the target under the lock, then terminate OUTSIDE it: the script's
        # INT/TERM trap runs its own cleanup (stops PacketRusher + N4/N9 IPsec,
        # removes netem — up to ~10s incl. an SSH round-trip to PC2), and holding
        # the lock that whole time would stall status polls.
        with self.lock:
            if not (self.current_job and self.current_job['status'] == 'running'):
                return False
            job_type = self.current_job.get('type')
            pid = self.current_job.get('pid')

        # Cooperative cancel: testbed_automation.sh polls this flag at every
        # checkpoint (check_cancel), so a cancel is honored within ~1 iteration
        # even when SIGINT is deferred deep in its sudo/docker/ssh call tree.
        if job_type in ("automation", "batch"):
            try:
                flag = os.path.join(CONFIG["testbed_dir"], "logs", ".automation_cancel")
                os.makedirs(os.path.dirname(flag), exist_ok=True)
                with open(flag, "w") as fh:
                    fh.write("cancel\n")
            except Exception as e:
                print(f"Could not write cancel flag: {e}")

        if pid:
            try:
                pgid = os.getpgid(pid)
            except ProcessLookupError:
                pgid = None
            except Exception as e:
                print(f"Error resolving process group: {e}")
                pgid = None
            if pgid is not None:
                try:
                    os.killpg(pgid, signal.SIGINT)
                except ProcessLookupError:
                    pgid = None
                except Exception as e:
                    print(f"Error signaling process: {e}")
                    pgid = None
            if pgid is not None:
                # Wait for the script to finish its cleanup and exit. Only SIGKILL
                # if it's still alive after the grace period (a 2s window used to
                # SIGKILL mid-cleanup, leaving IPsec/PacketRusher up).
                deadline = time.time() + 20
                while time.time() < deadline:
                    try:
                        os.kill(pid, 0)
                    except ProcessLookupError:
                        break
                    time.sleep(0.5)
                else:
                    try:
                        os.killpg(pgid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

        with self.lock:
            # The output-reader thread may have already finalized the job when the
            # process exited after cleanup — if so, nothing left to cancel here.
            if not (self.current_job and self.current_job['status'] == 'running'):
                return True

            if True:
                # Local cleanup for PQ jobs — the SIGINT to the process
                # group reaches the script (whose INT/TERM trap removes
                # netem, stops tcpdump and charon in both containers);
                # this follow-up is belt-and-braces for anything that
                # survived sudo's signal relay.
                if job_type == "pq_eval":
                    try:
                        pq_cfg = CONFIG["post_quantum"]
                        vctr = pq_cfg["vplmn_container"]
                        hctr = pq_cfg["hplmn_container"]
                        cleanup = (
                            "sudo -n pkill -f ike_eval_docker.sh 2>/dev/null; "
                            "sudo -n pkill -f ike_eval.sh 2>/dev/null; "
                            f"sudo -n docker exec {vctr} pkill -x tcpdump 2>/dev/null; "
                            f"sudo -n docker exec {vctr} tc qdisc del dev eth0 root 2>/dev/null; "
                            f"sudo -n docker exec {hctr} tc qdisc del dev eth0 root 2>/dev/null; "
                            f"sudo -n docker exec {vctr} swan-stop 2>/dev/null; "
                            f"sudo -n docker exec {hctr} swan-stop 2>/dev/null; "
                            "true"
                        )
                        subprocess.run(["bash", "-c", cleanup],
                                       timeout=20, capture_output=True)
                    except Exception as e:
                        print(f"PQ cleanup failed: {e}")

                self.current_job['status'] = 'cancelled'
                self.current_job['completed_at'] = datetime.now().isoformat()
                self.current_job['output_lines'] = list(self.current_job['output_lines'])
                self._last_completed_job = self.current_job.copy()
                self.job_history.append(self.current_job.copy())
                socketio.emit('script_completed', {
                    'job_id': self.current_job['id'],
                    'job_type': self.current_job['type'],
                    'status': 'cancelled'
                })
                self.current_job = None
                self._process = None
                return True
            return False


script_job_manager = ScriptJobManager()


# ============================================================================
# COMMAND EXECUTION HELPERS
# ============================================================================

def run_local_command(cmd, timeout=60):
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return {"success": result.returncode == 0, "stdout": result.stdout, "stderr": result.stderr, "returncode": result.returncode}
    except subprocess.TimeoutExpired:
        return {"success": False, "error": "Command timed out", "returncode": -1}
    except Exception as e:
        return {"success": False, "error": str(e), "returncode": -1}

def run_ssh_command(host, user, cmd, timeout=60):
    ssh_cmd = f'ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no {user}@{host} "{cmd}"'
    return run_local_command(ssh_cmd, timeout)

def run_command(location, cmd, timeout=60):
    if location == "local":
        return run_local_command(cmd, timeout)
    return run_ssh_command(CONFIG["remote"]["host"], CONFIG["remote"]["user"], cmd, timeout)


def run_script_in_background(script_path, args=None, cwd=None, job_type="automation",
                             config=None, use_sudo=False, auto_yes=True):
    """Run a shell script in background, streaming output via websocket.

    use_sudo=True wraps the invocation with sudo -n (non-interactive).
    auto_yes=False skips writing 'Y' to stdin (esp_config.sh has no prompts).
    """
    if use_sudo:
        cmd_parts = ["sudo", "-n", "bash", script_path]
    else:
        cmd_parts = ["bash", script_path]
    if args:
        cmd_parts.extend([str(a) for a in args])

    command_str = " ".join(cmd_parts)
    working_dir = cwd or CONFIG["testbed_dir"]

    job_id, err = script_job_manager.start_job(job_type, config or {}, command_str, working_dir)
    if err:
        return None, err

    def _run():
        try:
            process = subprocess.Popen(
                cmd_parts,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                cwd=working_dir,
                preexec_fn=os.setsid,
                bufsize=1,
                env={**os.environ, 'TERM': 'dumb', 'COLUMNS': '200'}
            )
            if auto_yes:
                try:
                    process.stdin.write("Y\n" * 10)
                    process.stdin.flush()
                except Exception:
                    pass
            try:
                process.stdin.close()
            except Exception:
                pass

            script_job_manager.set_pid(process.pid)
            script_job_manager._process = process

            for line in iter(process.stdout.readline, ''):
                if line:
                    clean_line = line.rstrip('\n\r')
                    clean_line = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', clean_line)
                    clean_line = re.sub(r'\x1b\[[0-9;]*m', '', clean_line)
                    if clean_line:
                        script_job_manager.append_output(clean_line)

            process.wait()
            exit_code = process.returncode

            results = None
            if job_type == "automation" and exit_code == 0:
                results = _find_latest_result()

            if exit_code == 0:
                script_job_manager.complete_job(results=results, exit_code=exit_code)
            elif exit_code == 130:
                # 130 = our cancel convention: the script's INT/TERM trap or the
                # cooperative CANCEL_FLAG ran cleanup and exited 130. Report it as
                # cancelled, not a script error.
                script_job_manager.complete_job(status='cancelled', exit_code=exit_code)
            else:
                script_job_manager.complete_job(
                    error=f"Script exited with code {exit_code}",
                    exit_code=exit_code
                )
        except Exception as e:
            script_job_manager.complete_job(error=str(e))

    thread = threading.Thread(target=_run, daemon=True)
    thread.start()
    return job_id, None


def run_pq_command_in_background(cmd_parts, cwd=None, job_type="pq_eval",
                                 config=None):
    """Run a LOCAL command (the PQ eval script or a docker compose action),
    streaming output via websocket. Mirrors run_script_in_background's
    contract so the frontend sees identical script_output / script_completed
    events, but takes a ready-made argv (typically prefixed with
    ["sudo","-n", ...]) and never feeds stdin.
    Cancellation: cancel_job SIGINTs the process group; sudo relays it to
    the eval script, whose INT/TERM trap tidies the containers."""
    cmd_parts = [str(p) for p in cmd_parts]
    command_str = " ".join(shlex.quote(p) for p in cmd_parts)
    job_id, err = script_job_manager.start_job(job_type, config or {}, command_str, cwd)
    if err:
        return None, err

    def _run():
        try:
            process = subprocess.Popen(
                cmd_parts,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                cwd=cwd,
                preexec_fn=os.setsid,
                bufsize=1,
                env={**os.environ, 'TERM': 'dumb', 'COLUMNS': '200'},
            )
            script_job_manager.set_pid(process.pid)
            script_job_manager._process = process

            for line in iter(process.stdout.readline, ''):
                if not line:
                    continue
                clean = line.rstrip('\r\n')
                clean = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', clean)
                clean = re.sub(r'\x1b\[[0-9;]*m', '', clean)
                if clean:
                    script_job_manager.append_output(clean)

            process.wait()
            exit_code = process.returncode

            if exit_code == 0:
                script_job_manager.complete_job(exit_code=exit_code)
            else:
                script_job_manager.complete_job(
                    error=f"Command exited with code {exit_code}",
                    exit_code=exit_code,
                )
        except Exception as e:
            script_job_manager.complete_job(error=str(e))

    thread = threading.Thread(target=_run, daemon=True)
    thread.start()
    return job_id, None


def _find_latest_result():
    # Newest by mtime: file names start with the config name, so sorting them
    # does not find the newest. A dongle run writes to results_dsk/ instead.
    dirs = [CONFIG["results_dir"]] + ([CONFIG["results_dsk_dir"]] if DONGLE_ENABLED else [])
    files = [os.path.join(d, f) for d in dirs if os.path.isdir(d)
             for f in os.listdir(d) if f.endswith('.json')]
    if not files:
        return None
    latest = max(files, key=os.path.getmtime)
    try:
        with open(latest) as f:
            return json.load(f)
    except Exception:
        return None


# ============================================================================
# IPSEC STATUS
# ============================================================================

def check_ipsec_status(location="local"):
    prefix = "sudo "
    result = run_command(location, f"{prefix}ipsec status 2>/dev/null || {prefix}swanctl --list-sas 2>/dev/null")
    ipsec_active = False
    tunnel_info = {}
    if result["success"] and result["stdout"]:
        output = result["stdout"]
        if "ESTABLISHED" in output or "established" in output:
            ipsec_active = True
            peer_match = re.search(r'(\d+\.\d+\.\d+\.\d+).*ESTABLISHED', output)
            if peer_match:
                tunnel_info["peer_ip"] = peer_match.group(1)
            tunnel_info["nat_t"] = "NAT" in output or "4500" in output
    esp_check = run_command(location, f"{prefix}ip xfrm state 2>/dev/null | head -20")
    if esp_check["success"] and "proto esp" in esp_check["stdout"]:
        ipsec_active = True
        tunnel_info["esp_active"] = True
    return {"active": ipsec_active, "tunnel_info": tunnel_info, "raw_output": result.get("stdout", "")[:500]}


def check_ipsec_status_detailed(location="local"):
    """N9 tunnel status, SCOPED to the N9 conn for this side.

    The host's charon is now SHARED with the N4 (SMF<->UPF) tunnel, so
    'charon is running' or 'some ESP SA exists' must NOT be read as 'N9 is up' —
    otherwise toggling N4 would make N9 look active. Every signal below is scoped
    to the N9 conn name / N9 peer IP so the two tunnels report independently.
    """
    prefix = "sudo "
    conn = IPSEC_CONN_NAMES.get(location, "")
    conn_re = re.escape(conn) if conn else ""
    # N9 peer: for VPLMN(local) it's the HPLMN, and vice versa. Used to keep the
    # N4 tunnel's ESP SAs (192.168.50.193 <-> VPLMN_IP) out of the N9 count.
    n9_peer = CONFIG["remote"]["ip"] if location == "local" else CONFIG["local"]["ip"]
    result_data = {"service_running": False, "tunnel_established": False, "tunnel_info": {}, "connections": [], "security_associations": [], "raw_status": "", "error": None, "esp_proposal": None}

    # 'statusall' lists loaded-but-not-established conns by name (unlike 'status'),
    # so we can tell "N9 conn loaded" from "charon up only for N4".
    service_check = run_command(location, f"{prefix}ipsec statusall 2>&1")
    output = (service_check.get("stdout", "") or "") + (service_check.get("stderr", "") or "")
    result_data["raw_status"] = output[:1000]
    if not (service_check.get("success") or service_check.get("stdout")):
        result_data["error"] = service_check.get("stderr", "") or service_check.get("error", "Unknown error")

    # N9 "running" = the N9 conn has an actual IKE_SA (CONNECTING or ESTABLISHED),
    # i.e. a 'conn[N]:' line — NOT merely the loaded conn definition ('conn:'),
    # which is always present whenever charon runs (e.g. for the N4 tunnel). This
    # keeps a down N9 from showing as "PARTIAL/connecting" while N4 is up.
    if conn_re and re.search(rf'(?m)^\s*{conn_re}\[\d+\]:', output):
        result_data["service_running"] = True
    # N9 "established" = the N9 conn has an ESTABLISHED IKE_SA.
    if conn_re and re.search(rf'(?m)^\s*{conn_re}\[\d+\]:\s+ESTABLISHED', output):
        result_data["tunnel_established"] = True
        for m in re.findall(rf'({conn_re})\[\d+\]:\s+ESTABLISHED\s+(\d+\s+\w+)\s+ago,\s+(\S+)\[(\S+)\]\.\.\.(\S+)\[(\S+)\]', output):
            result_data["connections"].append({"name": m[0], "established": m[1], "local_ip": m[2], "local_id": m[3], "remote_ip": m[4], "remote_id": m[5]})
        result_data["tunnel_info"]["peer_ip"] = n9_peer
    # N9 CHILD_SA installed?
    if conn_re and re.search(rf'(?m)^\s*{conn_re}\{{\d+\}}:\s+INSTALLED', output):
        result_data["tunnel_info"]["sa_installed"] = True
    esp_match = re.search(r'ESP[:=]\s*([A-Z0-9_/-]+)', output)
    if esp_match:
        result_data["esp_proposal"] = esp_match.group(1)

    # Kernel ESP SAs — scoped to the N9 peer so the N4 tunnel's SAs (same global
    # 'ip xfrm state') are never counted as N9.
    xfrm_raw = run_command(location, f"{prefix}ip xfrm state 2>/dev/null").get("stdout", "") or ""
    esp_count, cur_hdr = 0, ""
    for line in xfrm_raw.splitlines():
        s = line.strip()
        if s.startswith("src "):
            cur_hdr = s
        elif s.startswith("proto esp") and n9_peer and n9_peer in cur_hdr:
            esp_count += 1
    if esp_count:
        result_data["tunnel_info"]["esp_active"] = True
        result_data["tunnel_info"]["esp_sa_count"] = esp_count
        result_data["tunnel_established"] = True

    if result_data["tunnel_established"] or result_data["service_running"]:
        nat_check = run_command(location, f"{prefix}ss -ulnp 2>/dev/null | grep -E ':(4500|500)\\s' || {prefix}netstat -ulnp 2>/dev/null | grep -E ':(4500|500)'")
        result_data["tunnel_info"]["nat_t_active"] = "4500" in nat_check.get("stdout", "")
        result_data["tunnel_info"]["ike_port_active"] = "500" in nat_check.get("stdout", "")

    return result_data


# Read the active esp= line from /etc/ipsec.conf (so the UI can show what's
# currently configured even before the tunnel comes up).
def read_active_esp_line(location="local"):
    # /etc/ipsec.conf is world-readable (0644), so read it WITHOUT sudo. `sudo -n
    # grep` is not covered by the host's NOPASSWD allowlist (only bash/docker/ip/…
    # are), so it would prompt for a password and fail — which silently blanked
    # the "active esp" display. Plain grep needs no elevation here.
    r = run_command(location, "grep -E '^[[:space:]]*esp=' /etc/ipsec.conf 2>/dev/null | head -1")
    if not r["success"]:
        return None
    line = r.get("stdout", "").strip()
    if not line:
        return None
    m = re.search(r'esp\s*=\s*([A-Za-z0-9_!-]+)', line)
    if not m:
        return None
    proposal = m.group(1).rstrip('!')
    # Map back to mode number if we recognize it
    PROPOSAL_TO_MODE = {
        "aes128gcm16": "1", "aes256gcm16": "2",
        "aes128-sha256": "3", "aes256-sha256": "4",
        "null-sha256": "5", "null-aes128gmac": "6",
    }
    return {"proposal": proposal, "mode": PROPOSAL_TO_MODE.get(proposal), "raw": line}


def _ensure_charon(location, prefix):
    """Make charon available WITHOUT disturbing conns already up on it. On the
    VPLMN host charon is shared with the N4 tunnel, so we reload (not restart)
    when it's already running, and only 'ipsec start' when it isn't."""
    up = run_command(location, f"{prefix}pgrep -x charon >/dev/null 2>&1 && echo UP", timeout=10).get("stdout", "").strip() == "UP"
    if up:
        run_command(location, f"{prefix}ipsec reload", timeout=20)
    else:
        run_command(location, f"{prefix}ipsec start", timeout=30)
        time.sleep(2)


def start_ipsec_service(location="local"):
    prefix = "sudo "
    conn_name = IPSEC_CONN_NAMES.get(location, "")
    status = check_ipsec_status_detailed(location)
    if status["tunnel_established"]:
        return {"success": True, "message": "N9 tunnel already established", "status": status, "tunnel_established": True}
    _ensure_charon(location, prefix)
    # The N9 conn is auto=add, so initiate it explicitly. Only the VPLMN (PC1)
    # initiates; the HPLMN (PC2) responds once its conn is loaded (reload above).
    if conn_name and location == "local":
        run_command(location, f"{prefix}ipsec up {conn_name} 2>/dev/null || true", timeout=25)
    time.sleep(2)
    new_status = check_ipsec_status_detailed(location)
    ok = bool(new_status["tunnel_established"] or new_status["service_running"])
    return {"success": ok, "message": "N9 IPsec started" if ok else "N9 IPsec failed to start", "status": new_status, "tunnel_established": new_status["tunnel_established"]}


def stop_ipsec_service(location="local"):
    prefix = "sudo "
    conn_name = IPSEC_CONN_NAMES.get(location, "")
    # Bring down ONLY the N9 conn. Never 'ipsec stop' / killall charon: on the
    # VPLMN host charon is shared with the N4 (SMF<->UPF) tunnel, which must
    # survive an N9 stop (and vice versa).
    if conn_name:
        run_command(location, f"{prefix}ipsec down {conn_name} 2>/dev/null || true", timeout=20)
    time.sleep(3)  # allow the IKE_SA delete to complete before re-checking
    new_status = check_ipsec_status_detailed(location)
    ok = not new_status["tunnel_established"]
    return {"success": ok, "message": "N9 IPsec stopped" if ok else "N9 IPsec still established", "status": new_status}


def restart_ipsec_service(location="local"):
    prefix = "sudo "
    conn_name = IPSEC_CONN_NAMES.get(location, "")
    if conn_name:
        run_command(location, f"{prefix}ipsec down {conn_name} 2>/dev/null || true", timeout=20)
    _ensure_charon(location, prefix)
    if conn_name and location == "local":
        run_command(location, f"{prefix}ipsec up {conn_name} 2>/dev/null || true", timeout=25)
    time.sleep(2)
    new_status = check_ipsec_status_detailed(location)
    return {"success": bool(new_status["tunnel_established"]), "message": "N9 IPsec restarted" if new_status["tunnel_established"] else "N9 IPsec restart incomplete", "status": new_status}


# ============================================================================
# N4 (PFCP) IPsec — SMF <-> UPF, intra-VPLMN (local only). Drives the
# docker/n4-ipsec/n4_ipsec.sh orchestrator (host responder + SMF-in-container
# initiator). Toggling this does NOT touch the N9 tunnel above.
# ============================================================================
N4_IPSEC_CONN = "n4-smf-upf"
# Local (VPLMN) orchestrator path; the remote (HPLMN) one lives under the HPLMN
# repo on PC2 (CONFIG["remote"]["path"], '~'-based — expanded by the remote shell).
N4_IPSEC_SCRIPT_LOCAL = os.path.join(VPLMN_DIR, "docker", "n4-ipsec", "n4_ipsec.sh")


def _n4_script(location):
    if location == "local":
        return N4_IPSEC_SCRIPT_LOCAL
    return f'{CONFIG["remote"]["path"]}/docker/n4-ipsec/n4_ipsec.sh'


def check_n4_ipsec_status(location="local"):
    """N4 is up when THAT host's charon shows the n4-smf-upf conn
    ESTABLISHED/INSTALLED. Grep by the conn name so this never confuses N4 with
    the N9 tunnel. location='local' (VPLMN) runs locally; 'remote' (HPLMN) over SSH."""
    r = run_command(location,
        f"sudo -n ipsec statusall 2>/dev/null | grep -E '^\\s*{N4_IPSEC_CONN}'", timeout=20)
    out = r.get("stdout", "") or ""
    established = "ESTABLISHED" in out
    installed = "INSTALLED" in out
    return {
        "active": established or installed,
        "established": established,
        "installed": installed,
        "conn": N4_IPSEC_CONN,
        "location": location,
        "raw_output": out[:800],
    }


def _run_n4_ipsec(action, location="local"):
    script = _n4_script(location)
    if location == "local" and not os.path.isfile(script):
        return {"success": False, "error": f"n4_ipsec.sh not found at {script} "
                f"(run ./docker/n4-ipsec/n4_ipsec.sh deploy or the setup.sh)"}
    # start re-applies the SMF-side config (docker exec) + brings the tunnel up;
    # give it headroom (extra for the SSH round-trips on the remote side).
    timeout = 150 if action == "start" else 90
    r = run_command(location, f"sudo -n bash {script} {action}", timeout=timeout)
    status = check_n4_ipsec_status(location)
    tail = ((r.get("stdout", "") or "") + (r.get("stderr", "") or ""))[-1800:]
    if action == "start":
        ok = status["active"]
        msg = "N4 IPsec started — PFCP now encrypted" if ok else "N4 IPsec did not come up (see output)"
    else:
        ok = not status["active"]
        msg = "N4 IPsec stopped — PFCP back to cleartext" if ok else "N4 IPsec still up (see output)"
    return {"success": ok, "message": msg, "status": status, "output": tail}


# N4 ESP cipher uses the SAME 6-mode numbering as N9 (IPSEC_MODE_NAMES). Each
# PLMN's N4 is a self-contained tunnel on its own host, so the two sides — and N9
# — can each run a different cipher.
_N4_PROPOSAL_TO_MODE = {
    "aes128gcm16": "1", "aes256gcm16": "2",
    "aes128-sha256": "3", "aes256-sha256": "4",
    "null-sha256": "5", "null-aes128gmac": "6",
}


def read_n4_esp_line(location="local"):
    """Read the esp= this host's N4 conn is configured with, from the live
    drop-in /etc/ipsec.d/n4-smf-upf.conf (the source of truth for what charon
    loaded). Mirrors read_active_esp_line for N9. Returns {proposal, mode, raw}."""
    # Drop-in is world-readable (0644, dir 0755), so read it WITHOUT sudo — see
    # read_active_esp_line: `sudo -n grep` is not NOPASSWD-allowed and would fail,
    # which is exactly why the VPLMN (local) panel showed no cipher while HPLMN
    # (a host with a broader sudoers) did.
    r = run_command(location,
        "grep -E '^[[:space:]]*esp=' /etc/ipsec.d/n4-smf-upf.conf 2>/dev/null | head -1", timeout=20)
    if not r["success"]:
        return None
    line = (r.get("stdout") or "").strip()
    if not line:
        return None
    m = re.search(r'esp\s*=\s*([A-Za-z0-9_!-]+)', line)
    if not m:
        return None
    proposal = m.group(1).rstrip('!')
    return {"proposal": proposal, "mode": _N4_PROPOSAL_TO_MODE.get(proposal), "raw": line}


def _run_n4_cipher(location, mode):
    """Switch THIS PLMN's N4 ESP cipher to <mode> (1-6) and restart N4 only.
    Runs synchronously (like N4 start/stop) — locally for VPLMN, over the
    backend's SSH path for HPLMN, so it never hits the root-ssh host-key issue
    the standalone N9 esp_config.sh had."""
    if mode not in IPSEC_VALID_MODES:
        return {"success": False, "error": f"Invalid mode '{mode}'. Use 1-6."}
    script = _n4_script(location)
    if location == "local" and not os.path.isfile(script):
        return {"success": False, "error": f"n4_ipsec.sh not found at {script} "
                f"(run ./docker/n4-ipsec/n4_ipsec.sh deploy or the setup.sh)"}
    # cipher = stop + start with the new esp; same headroom as start plus the
    # SSH round-trips on the remote side.
    r = run_command(location, f"sudo -n bash {script} cipher {mode}", timeout=220)
    status = check_n4_ipsec_status(location)
    active_esp = read_n4_esp_line(location)
    tail = ((r.get("stdout", "") or "") + (r.get("stderr", "") or ""))[-2000:]
    name = IPSEC_MODE_NAMES.get(mode)
    applied_mode = (active_esp or {}).get("mode")
    up = status["active"]
    switched = applied_mode == mode
    # Success requires BOTH: the tunnel is up AND the drop-in now carries the
    # requested cipher. Verifying the esp= (not just "tunnel up") stops a no-op
    # from reporting a false success.
    ok = up and switched
    if ok:
        msg = f"N4 cipher applied: mode {mode} ({name})"
    elif up and applied_mode and not switched:
        # Tunnel up but still on a different cipher — the script ran without
        # changing esp=. On the remote (HPLMN) side this almost always means
        # PC2's copy of the N4 scripts predates cipher/--esp support.
        msg = (f"Requested mode {mode} ({name}) but N4 is still on mode "
               f"{applied_mode} ({IPSEC_MODE_NAMES.get(applied_mode, '?')}) — cipher NOT switched"
               + (". Update PC2's docker/n4-ipsec scripts (they lack cipher/--esp support)."
                  if location == "remote" else " (see output)."))
    else:
        msg = f"N4 cipher requested (mode {mode}) but the tunnel did not come up (see output)."
    return {
        "success": ok, "mode": mode, "mode_name": name, "applied_mode": applied_mode,
        "active_esp": active_esp, "status": status, "output": tail, "message": msg,
    }


# ============================================================================
# DELAY MODE DETECTION
# ============================================================================

def detect_current_delay_mode(interface, location="local"):
    prefix = "sudo "
    qdisc_result = run_command(location, f"{prefix}tc qdisc show dev {interface} 2>/dev/null")
    filter_result = run_command(location, f"{prefix}tc filter show dev {interface} 2>/dev/null")
    if not qdisc_result["success"]:
        return {"mode": "none", "delay": None}
    qdisc_output = qdisc_result["stdout"]
    filter_output = filter_result.get("stdout", "")
    delay_match = re.search(r'netem.*delay\s+([\d.]+\s*\w+)', qdisc_output)
    delay_value = delay_match.group(1).replace(" ", "") if delay_match else None
    if not delay_value:
        return {"mode": "none", "delay": None}
    if "prio" not in qdisc_output:
        return {"mode": DelayMode.FULL_INTERFACE, "delay": delay_value}

    # tc prints u32 matches in hex, so the decimal port/protocol numbers used to
    # install the filters never appear in this output — match on the hex.
    has_gtpu = TC_MATCH_GTPU_DPORT in filter_output or TC_MATCH_GTPU_SPORT in filter_output
    has_esp = TC_MATCH_ESP_PROTO in filter_output
    has_natt = TC_MATCH_NATT_DPORT in filter_output or TC_MATCH_NATT_SPORT in filter_output

    # Check combined first: it carries the GTP-U *and* ESP signatures, so the
    # narrower ESP-only / GTP-U-only tests below would misreport it.
    if has_gtpu and has_esp:
        return {"mode": DelayMode.GTPU_COMBINED, "delay": delay_value}
    if has_esp:
        if has_natt:
            return {"mode": DelayMode.IPSEC_TUNNEL, "delay": delay_value}
        return {"mode": DelayMode.IPSEC_ESP_ONLY, "delay": delay_value}
    if HPLMN_IP in filter_output or VPLMN_IP in filter_output:
        return {"mode": DelayMode.IPSEC_PEER, "delay": delay_value}
    if has_gtpu:
        return {"mode": DelayMode.GTPU_PORT, "delay": delay_value}
    return {"mode": "custom", "delay": delay_value}


# ============================================================================
# DELAY FUNCTIONS
# ============================================================================

def set_gtpu_port_delay(interface, delay, location="local"):
    """Delay the N9 user plane, whether or not IPsec is up.

    With IPsec off, GTP-U is on the wire as udp/2152. With IPsec on, it is
    encapsulated in ESP and the port is no longer visible, so a udp/2152 filter
    silently matches nothing. Both filter sets are installed against the same
    netem band: they are mutually exclusive (plaintext 2152 xor ESP), so a
    packet is classified once and delayed once, and the result is measurement-
    identical in both modes. IKE (udp/500) is deliberately not matched — it is
    tunnel management, not user plane, and delaying it would skew rekeying.

    Every filter is scoped to the N9 PEER, which is what makes this N9 and not
    "all GTP-U". N3 (gNB <-> vUPF) is also udp/2152 and, with a real gNB, rides
    the same host interface as N9 — so a port-only filter delays it too. Since
    netem on a root qdisc shapes egress only, that used to add the delay three
    times over a round trip instead of twice:

        gNB   -> vUPF   N3 uplink     ingress on the VPLMN  — not delayed
        vUPF  -> hUPF   N9 uplink     EGRESS on the VPLMN   — delayed (wanted)
        hUPF  -> vUPF   N9 downlink   EGRESS on the HPLMN   — delayed (wanted)
        vUPF  -> gNB    N3 downlink   EGRESS on the VPLMN   — delayed (NOT wanted)

    i.e. a 50ms setting produced +150ms RTT. Matching the peer address confines
    each end to its own N9 egress, so the round trip crosses the shaper once per
    direction and 50ms means +100ms RTT. (PacketRusher never showed this: its N3
    runs over a docker bridge, not this interface.)
    """
    prefix = "sudo "
    if not interface:
        return {"success": False, "error": "Interface not found"}
    if not re.fullmatch(r'\d+(\.\d+)?(ms|s)', delay.strip()):
        return {"success": False, "error": "Invalid delay format"}
    # The far end of N9, seen from this host. Only egress matters (netem root),
    # so destination alone identifies the segment.
    peer = HPLMN_IP if location == "local" else VPLMN_IP
    dst = f"match ip dst {peer}/32"
    commands = [
        f"{prefix}tc qdisc del dev {interface} root 2>/dev/null || true",
        f"{prefix}tc qdisc add dev {interface} root handle 1: prio",
        f"{prefix}tc qdisc add dev {interface} parent 1:3 handle 30: netem limit {NETEM_LIMIT} delay {delay}",
        # IPsec off: plaintext GTP-U, to the N9 peer only
        f"{prefix}tc filter add dev {interface} protocol ip parent 1:0 prio 1 u32 {dst} match ip dport {GTPU_PORT} 0xffff flowid 1:3",
        f"{prefix}tc filter add dev {interface} protocol ip parent 1:0 prio 1 u32 {dst} match ip sport {GTPU_PORT} 0xffff flowid 1:3",
        # IPsec on: the N9 SA is scoped to udp/2152, so ESP here is GTP-U only
        f"{prefix}tc filter add dev {interface} protocol ip parent 1:0 prio 2 u32 {dst} match ip protocol {ESP_PROTOCOL} 0xff flowid 1:3",
        # NAT-T fallback, in case the peers ever end up behind NAT
        f"{prefix}tc filter add dev {interface} protocol ip parent 1:0 prio 3 u32 {dst} match ip protocol 17 0xff match ip dport {IPSEC_NAT_T_PORT} 0xffff flowid 1:3",
        f"{prefix}tc filter add dev {interface} protocol ip parent 1:0 prio 3 u32 {dst} match ip protocol 17 0xff match ip sport {IPSEC_NAT_T_PORT} 0xffff flowid 1:3",
        # A full-size GTP-U packet does not fit the 1500-byte link and is
        # IP-fragmented; only the first fragment carries the UDP port, so the
        # rest bypassed netem and overtook it. The dongle's iperf3 then counted
        # 0 packets and 0 jitter. Match all UDP to the peer (every fragment has
        # the IP header) so a packet's fragments share one delay — same rule as
        # lib/automation/delays.sh. IKE (udp/500) is passed undelayed first.
        f"{prefix}tc filter add dev {interface} protocol ip parent 1:0 prio 4 u32 match ip protocol 17 0xff match ip dport {IPSEC_IKE_PORT} 0xffff flowid 1:2",
        f"{prefix}tc filter add dev {interface} protocol ip parent 1:0 prio 4 u32 match ip protocol 17 0xff match ip sport {IPSEC_IKE_PORT} 0xffff flowid 1:2",
        f"{prefix}tc filter add dev {interface} protocol ip parent 1:0 prio 5 u32 match ip protocol 17 0xff {dst} flowid 1:3",
    ]
    for cmd in commands:
        result = run_command(location, cmd)
        if not result["success"] and "del dev" not in cmd:
            return {"success": False, "error": f"Failed: {result.get('stderr', result.get('error', 'Unknown'))}"}
    container_cache.invalidate(location)
    return {"success": True, "message": f"Delay {delay} applied to N9 user plane toward {peer} (GTP-U, plain and IPsec)",
            "interface": interface, "port": GTPU_PORT, "peer": peer, "mode": DelayMode.GTPU_COMBINED}


def set_ipsec_tunnel_delay(interface, delay, location="local"):
    prefix = "sudo "
    if not re.fullmatch(r'\d+(\.\d+)?(ms|s)', delay.strip()):
        return {"success": False, "error": "Invalid delay format"}
    commands = [
        f"{prefix}tc qdisc del dev {interface} root 2>/dev/null || true",
        f"{prefix}tc qdisc add dev {interface} root handle 1: prio",
        f"{prefix}tc qdisc add dev {interface} parent 1:3 handle 30: netem limit {NETEM_LIMIT} delay {delay}",
        f"{prefix}tc filter add dev {interface} protocol ip parent 1:0 prio 1 u32 match ip protocol {ESP_PROTOCOL} 0xff flowid 1:3",
        f"{prefix}tc filter add dev {interface} protocol ip parent 1:0 prio 1 u32 match ip protocol 17 0xff match ip dport {IPSEC_NAT_T_PORT} 0xffff flowid 1:3",
        f"{prefix}tc filter add dev {interface} protocol ip parent 1:0 prio 1 u32 match ip protocol 17 0xff match ip sport {IPSEC_NAT_T_PORT} 0xffff flowid 1:3",
        f"{prefix}tc filter add dev {interface} protocol ip parent 1:0 prio 1 u32 match ip protocol 17 0xff match ip dport {IPSEC_IKE_PORT} 0xffff flowid 1:3",
        f"{prefix}tc filter add dev {interface} protocol ip parent 1:0 prio 1 u32 match ip protocol 17 0xff match ip sport {IPSEC_IKE_PORT} 0xffff flowid 1:3",
    ]
    for cmd in commands:
        result = run_command(location, cmd)
        if not result["success"] and "del dev" not in cmd:
            return {"success": False, "error": f"Failed: {result.get('stderr', result.get('error', 'Unknown'))}"}
    container_cache.invalidate(location)
    return {"success": True, "message": f"Delay {delay} applied to IPsec tunnel traffic", "interface": interface, "mode": DelayMode.IPSEC_TUNNEL}


def set_full_interface_delay(interface, delay, location="local"):
    prefix = "sudo "
    if not re.fullmatch(r'\d+(\.\d+)?(ms|s)', delay.strip()):
        return {"success": False, "error": "Invalid delay format"}
    run_command(location, f"{prefix}tc qdisc del dev {interface} root 2>/dev/null || true")
    result = run_command(location, f"{prefix}tc qdisc add dev {interface} root netem limit {NETEM_LIMIT} delay {delay}")
    container_cache.invalidate(location)
    if result["success"]:
        return {"success": True, "message": f"Delay {delay} applied to ALL traffic on {interface}", "interface": interface, "mode": DelayMode.FULL_INTERFACE}
    return {"success": False, "error": result.get("stderr", "Failed to apply delay")}


def remove_interface_delay(interface, location="local"):
    prefix = "sudo "
    run_command(location, f"{prefix}tc qdisc del dev {interface} root 2>/dev/null || true")
    container_cache.invalidate(location)
    return {"success": True, "message": f"Delay removed from {interface}"}


# ============================================================================
# CONTAINER FUNCTIONS
# ============================================================================

def get_all_containers_batch(location):
    path = CONFIG[location]["path"]
    prefix = "sudo "
    cmd = f"""cd {path} && {prefix}docker compose ps -a --format json 2>/dev/null"""
    result = run_command(location, cmd)
    if not result["success"] or not result["stdout"].strip():
        return []
    containers = []
    container_names = []
    for line in result["stdout"].strip().split('\n'):
        try:
            c = json.loads(line)
            container_names.append(c.get("Name", ""))
            containers.append({"id": c.get("Name", ""), "name": c.get("Name", ""), "service": c.get("Service", ""), "state": c.get("State", ""), "status": c.get("Status", "")})
        except json.JSONDecodeError:
            continue
    if not container_names:
        return containers
    names_str = " ".join(container_names)
    inspect_format = '{{.Name}}|{{.HostConfig.NetworkMode}}|{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
    inspect_cmd = f"{prefix}docker inspect --format '{inspect_format}' {names_str} 2>/dev/null"
    inspect_result = run_command(location, inspect_cmd)
    network_info = {}
    if inspect_result["success"]:
        for line in inspect_result["stdout"].strip().split('\n'):
            parts = line.strip().split('|')
            if len(parts) >= 3:
                name = parts[0].lstrip('/')
                network_info[name] = {"network_mode": parts[1], "ip": parts[2] if parts[2] else CONFIG[location]["ip"]}
    for container in containers:
        name = container["name"]
        if name in network_info:
            container["network_mode"] = network_info[name]["network_mode"]
            container["is_host_network"] = network_info[name]["network_mode"] == "host"
            container["ip"] = CONFIG[location]["ip"] if container["is_host_network"] else (network_info[name]["ip"] or "N/A")
        else:
            container["network_mode"] = "unknown"
            container["ip"] = "N/A"
            container["is_host_network"] = False
        container["is_upf"] = "upf" in container["service"].lower()
    return containers


def get_host_interface(location="local"):
    # NOTE: avoid awk '{print $5}' here — for the remote case the command is
    # wrapped in double quotes for SSH and run with shell=True, so the local
    # shell would expand $5 to empty before it ever reaches the remote awk,
    # returning the whole route line. grep -oP 'dev \K\S+' has no $ to expand.
    iface_cmd = r"ip route | grep default | grep -oP 'dev \K\S+' | head -1"
    iface_result = run_command(location, iface_cmd)
    iface = iface_result["stdout"].strip() if iface_result["success"] else ""
    # Guard against a multi-token result leaking through
    return iface.split()[0] if iface else "eth0"


def get_delays_batch(containers, location):
    if not containers:
        return containers
    prefix = "sudo "
    host_containers = [c for c in containers if c.get("is_host_network") and c["state"] == "running"]
    docker_containers = [c for c in containers if not c.get("is_host_network") and c["state"] == "running"]
    if host_containers:
        host_iface = get_host_interface(location)
        delay_info = detect_current_delay_mode(host_iface, location)
        for c in host_containers:
            c["interface"] = host_iface
            c["delay"] = delay_info["delay"] or "None"
            c["delay_mode"] = delay_info["mode"]
    if docker_containers:
        delays = {}
        def check_container_delay(container):
            name = container["name"]
            tc_cmd = f"{prefix}docker exec {name} tc qdisc show dev eth0 2>/dev/null"
            result = run_command(location, tc_cmd, timeout=5)
            delay = "None"
            if result["success"] and "netem" in result["stdout"]:
                match = re.search(r'delay\s+([\d.]+\s*\w+)', result["stdout"])
                if match:
                    delay = match.group(1).replace(" ", "")
            return name, delay
        with ThreadPoolExecutor(max_workers=5) as executor:
            futures = {executor.submit(check_container_delay, c): c for c in docker_containers}
            for future in as_completed(futures):
                try:
                    name, delay = future.result()
                    delays[name] = delay
                except Exception:
                    pass
        for c in docker_containers:
            c["interface"] = "eth0"
            c["delay"] = delays.get(c["name"], "N/A")
            c["delay_mode"] = "container" if c["delay"] not in ["None", "N/A"] else "none"
    for c in containers:
        if c["state"] != "running":
            c["delay"] = "N/A (stopped)"
            c["interface"] = "N/A"
            c["delay_mode"] = "none"
    return containers


def get_network_containers_optimized(location):
    cached = container_cache.get(location)
    if cached is not None:
        return cached
    containers = get_all_containers_batch(location)
    containers = get_delays_batch(containers, location)
    container_cache.set(location, containers)
    return containers


def set_container_delay_optimized(container_id, delay, location="local", delay_mode=None):
    if not re.fullmatch(r'\d+(\.\d+)?(ms|s)', delay.strip()):
        return {"success": False, "error": "Invalid delay format"}
    containers = get_network_containers_optimized(location)
    container = next((c for c in containers if c["id"] == container_id), None)
    if not container:
        return {"success": False, "error": "Container not found"}
    if container["state"] != "running":
        return {"success": False, "error": "Container is not running"}
    is_host = container.get("is_host_network", False)
    interface = container.get("interface", "eth0")
    prefix = "sudo "
    if is_host:
        if delay_mode in [DelayMode.IPSEC_TUNNEL, "ipsec-tunnel"]:
            return set_ipsec_tunnel_delay(interface, delay, location)
        elif delay_mode in [DelayMode.GTPU_PORT, "gtpu-port"]:
            return set_gtpu_port_delay(interface, delay, location)
        elif delay_mode in [DelayMode.FULL_INTERFACE, "full"]:
            return set_full_interface_delay(interface, delay, location)
        else:
            ipsec_status = check_ipsec_status(location)
            if ipsec_status["active"]:
                return set_ipsec_tunnel_delay(interface, delay, location)
            return set_gtpu_port_delay(interface, delay, location)
    cmd = f"{prefix}docker exec {container_id} tc qdisc replace dev eth0 root netem limit {NETEM_LIMIT} delay {delay}"
    result = run_command(location, cmd)
    container_cache.invalidate(location)
    if result["success"]:
        return {"success": True, "message": f"Delay {delay} applied to {container_id}", "interface": "eth0", "mode": "container"}
    error_msg = result.get("stderr", result.get("error", "Failed"))
    if "Operation not permitted" in error_msg:
        return {"success": False, "error": "Container needs NET_ADMIN capability"}
    return {"success": False, "error": error_msg}


def remove_container_delay_optimized(container_id, location="local"):
    containers = get_network_containers_optimized(location)
    container = next((c for c in containers if c["id"] == container_id), None)
    if not container:
        return {"success": False, "error": "Container not found"}
    is_host = container.get("is_host_network", False)
    interface = container.get("interface", "eth0")
    prefix = "sudo "
    if is_host:
        cmd = f"{prefix}tc qdisc del dev {interface} root 2>/dev/null || true"
    else:
        cmd = f"{prefix}docker exec {container_id} tc qdisc del dev eth0 root 2>/dev/null || true"
    run_command(location, cmd)
    container_cache.invalidate(location)
    return {"success": True, "message": f"Delay removed from {container_id}"}


def remove_all_delays_optimized(location):
    containers = get_network_containers_optimized(location)
    results = []
    prefix = "sudo "
    host_interface = None
    for c in containers:
        if c.get("is_host_network") and c.get("interface"):
            host_interface = c["interface"]
            break
    if host_interface:
        run_command(location, f"{prefix}tc qdisc del dev {host_interface} root 2>/dev/null || true")
        results.append({"container": "host:" + host_interface, "success": True})
    docker_containers = [c for c in containers if not c.get("is_host_network") and c["state"] == "running" and c["delay"] not in ["None", "N/A", "N/A (stopped)"]]
    def remove_delay(container):
        name = container["name"]
        cmd = f"{prefix}docker exec {name} tc qdisc del dev eth0 root 2>/dev/null || true"
        run_command(location, cmd, timeout=5)
        return {"container": name, "success": True}
    with ThreadPoolExecutor(max_workers=5) as executor:
        futures = [executor.submit(remove_delay, c) for c in docker_containers]
        for future in as_completed(futures):
            try:
                results.append(future.result())
            except Exception:
                pass
    container_cache.invalidate(location)
    return {"success": True, "results": results}


# ============================================================================
# CONFIG FILE HELPERS
# ============================================================================

def generate_env_content(security_mode, roaming_mode=None, include_upf=False, include_credentials=True):
    suffix = "_tls.yaml" if security_mode == "tls" else ".yaml"
    lines = [f"# Generated by WebUI - {datetime.now().isoformat()}", f"# Security: {security_mode}"]
    if roaming_mode:
        lines.append(f"# Roaming: {roaming_mode}")
    lines.append("")
    lines.extend([f"HPLMN_IP={HPLMN_IP}", f"VPLMN_IP={VPLMN_IP}", ""])
    if include_credentials:
        lines.extend([f"HPLMN_USER={HPLMN_USER}", f"VPLMN_USER={VPLMN_USER}",
                      f"PERF_SERVER_IP={PERF_SERVER_IP}", f"PERF_SERVER_USER={PERF_SERVER_USER}", ""])
    # v2.8.0: no UPF_IMAGE / OPEN5GS_TAG line — compose defaults every image to
    # :v2.8.0 (single unified UPF). include_upf kept for backward-compat callers.
    lines.extend([f"{nf}_CONFIG={nf.lower()}{suffix}" for nf in ["NRF", "SCP", "AMF", "SMF", "UPF", "AUSF", "UDM", "PCF", "NSSF", "BSF", "UDR", "SEPP"]])
    return "\n".join(lines)


def webpage_urls_from(params):
    """The webpage-test URLs, de-duplicated and safe to write into a config.

    batch_runner.sh sources the main config, so a URL carrying a double quote
    would end the quoted value and let the rest run as shell — these come
    straight from an operator-typed field, so drop anything with a quote or
    whitespace in it rather than trying to escape it. Non-http(s) entries are
    dropped too: browsertime cannot load them.
    """
    seen, urls = set(), []
    for raw in (params.get('webpage_urls') or []):
        url = str(raw).strip()
        if not url or url in seen:
            continue
        if not url.startswith(('http://', 'https://')):
            continue
        if '"' in url or any(c.isspace() for c in url):
            continue
        seen.add(url)
        urls.append(url)
    return urls


def generate_config_content(params):
    lines = [
        "# ============================================================================",
        f"# Open5GS Batch Automation Configuration File",
        f"# Generated by WebUI at {datetime.now().isoformat()}",
        "# ============================================================================",
        "",
        "# ROAMING CONFIGURATION",
        f"ROAMING_MODE={params.get('roaming_mode', 'hr')}",
        f"IPSEC_ENABLED={str(params.get('ipsec_enabled', False)).lower()}",
        # N4 (SMF<->UPF PFCP) IPsec — per PLMN (each side is an independent tunnel
        # on its own host). VPLMN applies to every roaming mode; HPLMN only when a
        # home network exists (roaming modes).
        f"N4_IPSEC_VPLMN_ENABLED={str(params.get('n4_vplmn_ipsec_enabled', False)).lower()}",
        f"N4_IPSEC_HPLMN_ENABLED={str(params.get('n4_hplmn_ipsec_enabled', False)).lower()}",
    ]
    # Which UE runs the tests: PacketRusher (default), or the commercial RAN —
    # a real gNB with a USB dongle (lib/automation/dsk.sh). Written only when
    # the dongle is chosen, so configs for PacketRusher look as they always did.
    if str(params.get('ue_type') or '').lower() == 'dsk':
        dongle = str(params.get('dsk_dongle') or 'a').lower()
        cycle = str(params.get('dsk_cycle') or 'airplane').lower()
        lines += [
            "",
            "# UE: commercial RAN (gNB + USB dongle) instead of PacketRusher",
            "UE_TYPE=dsk",
            f"DSK_DONGLE={dongle if dongle in ('a', 'b') else 'a'}",
            f"DSK_CYCLE={cycle if cycle in ('airplane', 'reboot') else 'airplane'}",
            "",
        ]
    if params.get('ipsec_mode'):
        lines.append(f"IPSEC_MODE={params['ipsec_mode']}")
    # Empty N4 mode = keep each side's current/last cipher; 1-6 = apply that cipher.
    if params.get('n4_vplmn_ipsec_mode'):
        lines.append(f"N4_IPSEC_VPLMN_MODE={params['n4_vplmn_ipsec_mode']}")
    if params.get('n4_hplmn_ipsec_mode'):
        lines.append(f"N4_IPSEC_HPLMN_MODE={params['n4_hplmn_ipsec_mode']}")
    lines.extend([
        "",
        "# SECURITY CONFIGURATION",
        f"VPLMN_SECURITY={params.get('vplmn_security', 'tls')}",
        f"HPLMN_SECURITY={params.get('hplmn_security', 'tls')}",
        "",
        "# TEST PARAMETERS",
        f"ITERATIONS={params.get('iterations', 10)}",
        f"PING_COUNT={params.get('ping_count', 10)}",
        f"PING_TARGET={params.get('ping_target') or PERF_SERVER_IP}",
        f"ITERATION_DELAY={params.get('iteration_delay', 2)}",
        f"TESTBED_RESTART_INTERVAL={params.get('testbed_restart_interval', 0)}",
    ])
    if params.get('ping_interval'):
        lines.append(f"PING_INTERVAL={params['ping_interval']}")
    if params.get('ping_payload_size'):
        lines.append(f"PING_PAYLOAD_SIZE={params['ping_payload_size']}")
    lines.extend([
        "",
        "# PERFORMANCE TUNING",
        f"NETWORK_READY_TIMEOUT={params.get('network_ready_timeout', 30)}",
        f"SERVICE_CHECK_INTERVAL={params.get('service_check_interval', 1)}",
        f"IPSEC_ESTABLISH_TIMEOUT={params.get('ipsec_establish_timeout', 10)}",
        f"MIN_NETWORK_STABILIZE_TIME={params.get('min_network_stabilize_time', 10)}",
    ])
    if params.get('server_ip') or params.get('server_user') or params.get('server_interface'):
        lines.extend(["", "# SERVER CONFIGURATION"])
        if params.get('server_ip'):
            lines.append(f"SERVER_IP={params['server_ip']}")
        if params.get('server_user'):
            lines.append(f"SERVER_USER={params['server_user']}")
        if params.get('server_interface'):
            lines.append(f"SERVER_INTERFACE={params['server_interface']}")
    lines.extend(["", "# TEST MODES", f"PING_TEST_ENABLED={str(params.get('ping_test_enabled', True)).lower()}"])
    if params.get('download_test_enabled'):
        # Fall back rather than writing an empty DOWNLOAD_TEST_URL=: the test
        # then runs against nothing and reports failure with no obvious cause.
        lines.extend([f"DOWNLOAD_TEST_ENABLED=true",
                      f"DOWNLOAD_TEST_URL={params.get('download_test_url') or DEFAULT_DOWNLOAD_URL}",
                      f"DOWNLOAD_TEST_SIZE_LABEL={params.get('download_test_size_label') or DEFAULT_DOWNLOAD_SIZE_LABEL}"])
    else:
        lines.append("DOWNLOAD_TEST_ENABLED=false")
    if params.get('video_test_enabled'):
        lines.extend([f"VIDEO_TEST_ENABLED=true", f"VIDEO_TEST_URL={params.get('video_test_url', '')}", f"VIDEO_TEST_SIZE_LABEL={params.get('video_test_size_label', '')}"])
    else:
        lines.append("VIDEO_TEST_ENABLED=false")
    if params.get('iperf_test_enabled'):
        lines.extend([
            f"IPERF_TEST_ENABLED=true",
            f"IPERF_SERVER_IP={params.get('iperf_server_ip') or PERF_SERVER_IP}",
            f"IPERF_SERVER_PORT={params.get('iperf_server_port', '5201')}",
            f"IPERF_DURATION={params.get('iperf_duration', '10')}",
            f"IPERF_PARALLEL={params.get('iperf_parallel', '1')}",
            f"IPERF_REVERSE={str(params.get('iperf_reverse', False)).lower()}",
            f"IPERF_UDP={str(params.get('iperf_udp', False)).lower()}",
        ])
        if params.get('iperf_bandwidth'):
            # The batch keeps the UDP rate and the TCP cap apart (a UDP rate in
            # main.conf must not cap TCP runs), so write the one that applies.
            key = "IPERF_BANDWIDTH" if params.get('iperf_udp') else "IPERF_TCP_BANDWIDTH"
            lines.append(f"{key}={params['iperf_bandwidth']}")
    else:
        lines.append("IPERF_TEST_ENABLED=false")
    if params.get('webpage_test_enabled'):
        lines.extend([
            "WEBPAGE_TEST_ENABLED=true",
            f"WEBPAGE_BROWSER={params.get('webpage_browser', 'firefox')}",
            f"WEBPAGE_ITERATIONS={params.get('webpage_iterations', '1')}",
            f"WEBPAGE_TIMEOUT={params.get('webpage_timeout', '120')}",
        ])
        # One WEBPAGE_URL_N line per URL — lib/automation/config.sh collects them into
        # WEBPAGE_URLS, and an empty list makes the test skip itself.
        # Quoted because batch_runner.sh *sources* the main config: these URLs
        # carry ?, & and = (e.g. the Google preset), which would otherwise be
        # parsed as shell. lib/automation/config.sh's parser strips the quotes back off.
        for i, url in enumerate(webpage_urls_from(params), 1):
            lines.append(f'WEBPAGE_URL_{i}="{url}"')
    else:
        lines.append("WEBPAGE_TEST_ENABLED=false")
    if params.get('n6_delay_enabled'):
        lines.extend(["", "# N6 DELAY CONFIGURATION", "N6_DELAY_ENABLED=true", f"N6_DELAY_VALUE={params.get('n6_delay_value', '50ms')}"])
        if params.get('n6_delay_jitter'):
            lines.append(f"N6_DELAY_JITTER={params['n6_delay_jitter']}")
    else:
        lines.extend(["", "N6_DELAY_ENABLED=false"])
    delay_enabled = params.get('delay_enabled', False)
    delay_rules = params.get('delay_rules', [])
    lines.extend(["", "# NETWORK DELAY CONFIGURATION", f"DELAY_ENABLED={str(delay_enabled).lower()}"])
    if delay_enabled and delay_rules:
        for i, rule in enumerate(delay_rules, 1):
            lines.append(f"DELAY_RULE_{i}={rule}")
    lines.append("")
    return "\n".join(lines)


# ============================================================================
# API: IPSEC CONTROL
# ============================================================================

@app.route('/api/ipsec/<location>/status', methods=['GET'])
def api_get_ipsec_status(location):
    if location not in ["local", "remote"]:
        return jsonify({"success": False, "error": "Invalid location"}), 400
    status = check_ipsec_status_detailed(location)
    active_esp = read_active_esp_line(location)
    return jsonify({"success": True, "location": location, "location_name": CONFIG[location]["name"], "ip": CONFIG[location]["ip"], "active_esp": active_esp, **status})


@app.route('/api/ipsec/<location>/start', methods=['POST'])
def api_start_ipsec(location):
    if location not in ["local", "remote"]:
        return jsonify({"success": False, "error": "Invalid location"}), 400
    return jsonify(start_ipsec_service(location))


@app.route('/api/ipsec/<location>/stop', methods=['POST'])
def api_stop_ipsec(location):
    if location not in ["local", "remote"]:
        return jsonify({"success": False, "error": "Invalid location"}), 400
    return jsonify(stop_ipsec_service(location))


@app.route('/api/ipsec/<location>/restart', methods=['POST'])
def api_restart_ipsec(location):
    if location not in ["local", "remote"]:
        return jsonify({"success": False, "error": "Invalid location"}), 400
    return jsonify(restart_ipsec_service(location))


@app.route('/api/ipsec/status-all', methods=['GET'])
def api_get_all_ipsec_status():
    local_status = check_ipsec_status_detailed("local")
    remote_status = check_ipsec_status_detailed("remote")
    local_esp = read_active_esp_line("local")
    remote_esp = read_active_esp_line("remote")
    return jsonify({
        "success": True,
        "local": {"location_name": CONFIG["local"]["name"], "ip": CONFIG["local"]["ip"], "active_esp": local_esp, **local_status},
        "remote": {"location_name": CONFIG["remote"]["name"], "ip": CONFIG["remote"]["ip"], "active_esp": remote_esp, **remote_status},
    })


# ---- N4 (PFCP) IPsec: SMF <-> UPF, per-PLMN (local=VPLMN, remote=HPLMN) -----

@app.route('/api/n4ipsec/<location>/status', methods=['GET'])
def api_get_n4_ipsec_status(location):
    if location not in ("local", "remote"):
        return jsonify({"success": False, "error": "Invalid location"}), 400
    return jsonify({"success": True, "ip": CONFIG[location]["ip"],
                    "location_name": CONFIG[location]["name"],
                    "active_esp": read_n4_esp_line(location),
                    **check_n4_ipsec_status(location)})


@app.route('/api/n4ipsec/<location>/start', methods=['POST'])
def api_start_n4_ipsec(location):
    if location not in ("local", "remote"):
        return jsonify({"success": False, "error": "Invalid location"}), 400
    return jsonify(_run_n4_ipsec("start", location))


@app.route('/api/n4ipsec/<location>/stop', methods=['POST'])
def api_stop_n4_ipsec(location):
    if location not in ("local", "remote"):
        return jsonify({"success": False, "error": "Invalid location"}), 400
    return jsonify(_run_n4_ipsec("stop", location))


@app.route('/api/n4ipsec/<location>/cipher', methods=['POST'])
def api_n4_ipsec_cipher(location):
    """Switch this PLMN's N4 ESP cipher (mode 1-6) and restart N4 only."""
    if location not in ("local", "remote"):
        return jsonify({"success": False, "error": "Invalid location"}), 400
    data = request.get_json(silent=True) or {}
    mode = str(data.get("mode", "")).strip()
    if mode not in IPSEC_VALID_MODES:
        return jsonify({"success": False, "error": f"Invalid mode '{mode}'. Use 1-6."}), 400
    return jsonify(_run_n4_cipher(location, mode))


# ---- ESP cipher mode via esp_config.sh ------------------------------------

@app.route('/api/ipsec/esp-script-info', methods=['GET'])
def api_esp_script_info():
    """Tell the frontend whether esp_config.sh exists and where."""
    candidates = CONFIG["esp_config_script_candidates"]
    found = next((p for p in candidates if os.path.isfile(p)), None)
    return jsonify({
        "success": True,
        "found": found is not None,
        "path": found,
        "candidates": candidates,
        "modes": IPSEC_MODE_NAMES,
    })


@app.route('/api/ipsec/apply-cipher', methods=['POST'])
def api_apply_cipher():
    """Run esp_config.sh <mode> in background. Output streams via the same
    websocket events used by automation/batch_runner. Refuses if another job
    is already running."""
    data = request.get_json(silent=True) or {}
    mode = str(data.get('mode', '')).strip()
    if mode not in IPSEC_VALID_MODES:
        return jsonify({"success": False, "error": f"Invalid mode '{mode}'. Use 1-6."}), 400

    script = CONFIG["esp_config_script"]
    if not os.path.isfile(script):
        return jsonify({
            "success": False,
            "error": f"esp_config.sh not found. Looked at: {', '.join(CONFIG['esp_config_script_candidates'])}",
        }), 400

    if not os.access(script, os.R_OK):
        return jsonify({"success": False, "error": f"esp_config.sh exists but is not readable: {script}"}), 400

    job_id, err = run_script_in_background(
        script,
        args=[mode],
        cwd=os.path.dirname(script) or CONFIG["testbed_dir"],
        job_type="ipsec_cipher",
        config={"script": "esp_config.sh", "mode": mode, "mode_name": IPSEC_MODE_NAMES.get(mode)},
        use_sudo=True,
        auto_yes=False,
    )
    if err:
        return jsonify({"success": False, "error": err}), 409

    return jsonify({
        "success": True,
        "job_id": job_id,
        "mode": mode,
        "mode_name": IPSEC_MODE_NAMES.get(mode),
        "script": script,
        "message": f"Applying ESP cipher: {IPSEC_MODE_NAMES.get(mode)}",
    })


# ============================================================================
# API: POST-QUANTUM IKE EVALUATION (local Dockerized testbed)
# ============================================================================
#
# The PQ testbed runs ON THIS MACHINE — the same box as the WebUI backend.
# ike_eval_docker.sh benchmarks IKE handshakes between two local Docker
# containers (pq-vplmn ⇄ pq-hplmn), so everything below executes locally;
# no SSH is involved. Passwordless sudo is still required, because the
# eval script and docker compose run via `sudo -n` (same pattern as the
# other tabs' automation scripts).

def run_pq_shell(snippet, timeout=30, sudo=False):
    """Run a (possibly multi-line) shell snippet LOCALLY via bash and return
    {success, stdout, stderr, returncode}. The snippet is passed as a single
    argv element, so $vars / loops / quoting behave exactly as written.
    With sudo=True the whole snippet runs under `sudo -n bash -c` — used for
    listing/reading/deleting result files, which the eval script may have
    created as root."""
    cmd = (["sudo", "-n"] if sudo else []) + ["bash", "-c", snippet]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return {"success": result.returncode == 0, "stdout": result.stdout,
                "stderr": result.stderr, "returncode": result.returncode}
    except subprocess.TimeoutExpired:
        return {"success": False, "stdout": "", "stderr": "",
                "error": "Command timed out", "returncode": -1}
    except Exception as e:
        return {"success": False, "stdout": "", "stderr": "",
                "error": str(e), "returncode": -1}


try:
    _PQ_LOCAL_USER = getpass.getuser()
except Exception:
    _PQ_LOCAL_USER = os.environ.get("USER", "user")
_PQ_LOCAL_HOST = os.uname().nodename


# Cache for the resolved project dir so the 3s results polling doesn't
# re-run the candidate walk every tick.
_PQ_PROJ_CACHE = {"dir": None, "script": None, "ts": 0}


def _pq_probe(light=False):
    """One-shot diagnostic of the local PQ testbed. Returns sudo state, the
    resolved script + project dir (the script may be reached via a symlink
    such as ~/ike_eval.sh, so we readlink -f to anchor results to the REAL
    project directory, exactly like the script itself does), and — unless
    light=True — the state of the Docker testbed (engine, compose v2, image,
    both containers, strongSwan version when reachable)."""
    pq = CONFIG["post_quantum"]
    out = {
        "sudo_ok": False, "sudo_error": None,
        "script_path": None, "script_real": None, "project_dir": None,
        "docker": None,
    }

    # '~' in the candidates must expand through the shell -> keep unquoted.
    cand_words = " ".join(pq["script_path_candidates"])
    vctr, hctr, image = pq["vplmn_container"], pq["hplmn_container"], pq["image"]

    probe = f'''
SUDO=FAIL; sudo -n true 2>/dev/null && SUDO=OK; echo "SUDO:$SUDO"
FOUND=""; REAL=""
for p in {cand_words}; do
  if [ -f "$p" ]; then FOUND="$p"; REAL="$(readlink -f "$p")"; break; fi
done
echo "FOUND:$FOUND"
echo "REAL:$REAL"
PROJ=""; [ -n "$REAL" ] && PROJ="$(dirname "$REAL")"
echo "PROJ:$PROJ"
'''
    if not light:
        probe += f'''
command -v docker >/dev/null 2>&1 && echo "DOCKER:yes" || echo "DOCKER:no"
sudo -n docker compose version >/dev/null 2>&1 && echo "COMPOSEV2:yes" || echo "COMPOSEV2:no"
sudo -n docker image inspect {image} >/dev/null 2>&1 && echo "IMAGE:yes" || echo "IMAGE:no"
echo "VPLMN:$(sudo -n docker inspect -f '{{{{.State.Running}}}}' {vctr} 2>/dev/null || echo missing)"
echo "HPLMN:$(sudo -n docker inspect -f '{{{{.State.Running}}}}' {hctr} 2>/dev/null || echo missing)"
if [ -n "$PROJ" ] && [ -f "$PROJ/docker-compose.yml" ]; then echo "COMPOSEFILE:yes"; else echo "COMPOSEFILE:no"; fi
if [ "$(sudo -n docker inspect -f '{{{{.State.Running}}}}' {vctr} 2>/dev/null)" = "true" ]; then
  echo "SWANVER:$(sudo -n docker exec {vctr} swanctl --version 2>/dev/null | head -1)"
fi
'''
    res = run_pq_shell(probe, timeout=25)
    kv = {}
    for line in (res.get("stdout") or "").splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            kv.setdefault(k.strip(), v.strip())

    out["sudo_ok"] = kv.get("SUDO") == "OK"
    if not out["sudo_ok"]:
        out["sudo_error"] = "passwordless sudo not configured (sudo -n failed)"
    out["script_path"] = kv.get("FOUND") or None
    out["script_real"] = kv.get("REAL") or None
    out["project_dir"] = kv.get("PROJ") or None
    if out["project_dir"]:
        _PQ_PROJ_CACHE.update({
            "dir": out["project_dir"],
            "script": out["script_real"] or out["script_path"],
            "ts": time.time(),
        })

    if not light:
        def _state(s):
            return "running" if s == "true" else ("stopped" if s == "false" else "missing")
        sudo_ok = out["sudo_ok"]
        out["docker"] = {
            "engine": kv.get("DOCKER") == "yes",
            # docker compose / image / container state are probed THROUGH
            # sudo, so without passwordless sudo they are unknown, not "no".
            "compose_v2": (kv.get("COMPOSEV2") == "yes") if sudo_ok else None,
            "image": image,
            "image_built": (kv.get("IMAGE") == "yes") if sudo_ok else None,
            "vplmn": {"name": vctr, "state": _state(kv.get("VPLMN", "missing")) if sudo_ok else "unknown"},
            "hplmn": {"name": hctr, "state": _state(kv.get("HPLMN", "missing")) if sudo_ok else "unknown"},
            "compose_file": kv.get("COMPOSEFILE") == "yes",
            "swan_version": kv.get("SWANVER") or None,
        }
    return out


def _pq_project_dir(max_age=60):
    """Absolute path of the pq-ike-docker project on this machine (cached
    for max_age seconds so the 3s results polling stays cheap)."""
    if _PQ_PROJ_CACHE["dir"] and (time.time() - _PQ_PROJ_CACHE["ts"]) < max_age:
        return _PQ_PROJ_CACHE["dir"]
    p = _pq_probe(light=True)
    return p["project_dir"]


def _pq_path(filename):
    """Map a result filename to its absolute path inside the project:
    *.csv -> project root, *.pcap -> results/pcaps, everything else ->
    results/json. Returns (path, kind) or (None, None) if the project
    can't be located."""
    pq = CONFIG["post_quantum"]
    project_dir = _pq_project_dir()
    if not project_dir:
        return None, None
    low = filename.lower()
    if low.endswith(".csv"):
        return f"{project_dir}/{filename}", "csv"
    if low.endswith(".pcap"):
        return f"{project_dir}/{pq['pcaps_subdir']}/{filename}", "pcap"
    return f"{project_dir}/{pq['results_subdir']}/{filename}", "json"


@app.route('/api/pq/script-info', methods=['GET'])
def api_pq_script_info():
    """Diagnostic endpoint — what's the state of the local PQ testbed
    (sudo / script / Docker engine / image / pq-vplmn / pq-hplmn)?"""
    pq = CONFIG["post_quantum"]
    p = _pq_probe()
    return jsonify({
        "success": True,
        "local": True,
        "host": _PQ_LOCAL_HOST,
        "user": _PQ_LOCAL_USER,
        "candidates": pq["script_path_candidates"],
        "sudo_ok": p["sudo_ok"],
        "sudo_error": p["sudo_error"],
        "script_found": p["script_path"] is not None,
        "script_path": p["script_path"],
        "script_real": p["script_real"],
        "project_dir": p["project_dir"],
        "docker": p["docker"],
        "results_subdir": pq["results_subdir"],
        "pcaps_subdir": pq["pcaps_subdir"],
        "configs": PQ_CONFIG_NAMES,
    })


@app.route('/api/pq/run', methods=['POST'])
def api_pq_run():
    """Start ike_eval_docker.sh locally. Output streams via the same
    websocket events as automation/batch/ipsec. The script auto-starts the
    containers if they're down (provided the image is built)."""
    data = request.get_json(silent=True) or {}
    config_num = str(data.get('config', '')).strip()
    iterations_raw = data.get('iterations', 30)
    delay_ms_raw = data.get('delay_ms', 0)

    if config_num not in PQ_VALID_CONFIGS:
        return jsonify({"success": False, "error": "config must be one of 1,2,3,4,5"}), 400
    try:
        iterations = int(iterations_raw)
    except (TypeError, ValueError):
        return jsonify({"success": False, "error": "iterations must be an integer"}), 400
    if iterations < 1 or iterations > 1000:
        return jsonify({"success": False, "error": "iterations must be between 1 and 1000"}), 400
    try:
        delay_ms = int(delay_ms_raw)
    except (TypeError, ValueError):
        return jsonify({"success": False, "error": "delay_ms must be an integer"}), 400
    if delay_ms < 0 or delay_ms > 10000:
        return jsonify({"success": False, "error": "delay_ms must be between 0 and 10000"}), 400

    pq = CONFIG["post_quantum"]
    p = _pq_probe()
    if not p["sudo_ok"]:
        return jsonify({"success": False, "error": f"Passwordless sudo not configured on this machine: {p['sudo_error']}"}), 400
    if not p["script_path"]:
        return jsonify({
            "success": False,
            "error": f"ike_eval_docker.sh not found. Tried: {', '.join(pq['script_path_candidates'])}",
        }), 400
    docker = p.get("docker") or {}
    if not docker.get("engine"):
        return jsonify({"success": False, "error": "Docker is not installed on this machine."}), 400
    if docker.get("image_built") is False:
        return jsonify({
            "success": False,
            "error": f"Image {pq['image']} is not built yet — run 'Build image' first (docker compose build).",
        }), 400

    script = p["script_real"] or p["script_path"]
    project_dir = p["project_dir"] or os.path.dirname(script) or os.path.expanduser("~")

    # Pass all 3 args every time — the script ignores delay_ms=0 internally.
    # NOTE: deliberately no `stdbuf` here. stdbuf line-buffers via
    # LD_PRELOAD=/usr/libexec/coreutils/libstdbuf.so, which a snap-confined
    # docker (/snap/bin/docker) cannot see from its own mount namespace — every
    # docker call the script makes would then print "ld.so: object ...
    # libstdbuf.so from LD_PRELOAD cannot be preloaded: ignored". The script is
    # bash-based (echo writes straight through), so it streams fine without it.
    cmd_parts = ["sudo", "-n", "bash", script,
                 config_num, str(iterations), str(delay_ms)]

    job_id, err = run_pq_command_in_background(
        cmd_parts,
        cwd=project_dir,
        job_type="pq_eval",
        config={
            "script": os.path.basename(script),
            "script_path": script,
            "project_dir": project_dir,
            "containers": [pq["vplmn_container"], pq["hplmn_container"]],
            "config_num": config_num,
            "config_name": PQ_CONFIG_NAMES[config_num],
            "iterations": iterations,
            "delay_ms": delay_ms,
        },
    )
    if err:
        return jsonify({"success": False, "error": err}), 409

    return jsonify({
        "success": True,
        "job_id": job_id,
        "host": _PQ_LOCAL_HOST,
        "config_num": config_num,
        "config_name": PQ_CONFIG_NAMES[config_num],
        "iterations": iterations,
        "delay_ms": delay_ms,
        "script_path": script,
        "project_dir": project_dir,
        "containers": [pq["vplmn_container"], pq["hplmn_container"]],
        "message": f"Started {os.path.basename(script)} locally: {PQ_CONFIG_NAMES[config_num]}",
    })


# docker compose actions exposed to the UI -> (compose args, human label)
PQ_DOCKER_ACTIONS = {
    "up":    ("up -d",          "Start containers (docker compose up -d)"),
    "down":  ("down",           "Stop containers (docker compose down)"),
    "build": ("build",          "Build image (docker build)"),
    "certs": ("run --rm certs", "Regenerate certificates (docker compose run --rm certs)"),
}


@app.route('/api/pq/docker', methods=['POST'])
def api_pq_docker():
    """Run a docker compose action (up/down/build/certs) in the local
    project dir, streamed through the same job channel as the eval script
    (job_type='pq_eval'), so e.g. a long image build is visible live."""
    data = request.get_json(silent=True) or {}
    action = str(data.get('action', '')).strip()
    if action not in PQ_DOCKER_ACTIONS:
        return jsonify({"success": False, "error": f"action must be one of: {', '.join(PQ_DOCKER_ACTIONS)}"}), 400

    pq = CONFIG["post_quantum"]
    p = _pq_probe()
    if not p["sudo_ok"]:
        return jsonify({"success": False, "error": f"Passwordless sudo not configured on this machine: {p['sudo_error']}"}), 400
    if not p["project_dir"]:
        return jsonify({
            "success": False,
            "error": "Could not locate the pq-ike-docker project (ike_eval_docker.sh not found).",
        }), 400
    docker = p.get("docker") or {}
    if not docker.get("engine"):
        return jsonify({"success": False, "error": "Docker is not installed on this machine."}), 400
    if not docker.get("compose_file"):
        return jsonify({"success": False, "error": f"docker-compose.yml not found in {p['project_dir']}."}), 400

    compose_args, label = PQ_DOCKER_ACTIONS[action]
    # No `stdbuf`: docker/buildkit streams its own progress, and stdbuf's
    # LD_PRELOAD is invisible to a snap-confined docker -> spurious
    # "libstdbuf.so ... cannot be preloaded" noise on every invocation.
    if action == "build":
        # `docker compose build` is broken under snap-confined docker: it writes
        # a build metadata file to a hardcoded /tmp path (TMPDIR is ignored) that
        # it then cannot read back from the snap's private /tmp, so it exits 1
        # with "open /tmp/.tmp-compose-build-metadataFile-...: no such file or
        # directory" — even though the image built fine. COMPOSE_BAKE=false and
        # dropping sudo don't help. `docker build` takes no metadata file and
        # exits 0. The compose build config is just {context: ., args: SWAN_REF},
        # so this is equivalent; SWAN_REF is read from the project's .env.
        swan_ref = "ml-dsa"
        env_file = os.path.join(p["project_dir"], ".env")
        try:
            with open(env_file) as fh:
                for line in fh:
                    line = line.strip()
                    if line.startswith("SWAN_REF="):
                        swan_ref = line.split("=", 1)[1].strip().strip('"').strip("'") or swan_ref
                        break
        except OSError:
            pass
        cmd_parts = ["sudo", "-n", "docker", "build",
                     "-t", pq["image"],
                     "--build-arg", f"SWAN_REF={swan_ref}",
                     "."]
    else:
        cmd_parts = ["sudo", "-n", "docker", "compose"] + compose_args.split()
    job_id, err = run_pq_command_in_background(
        cmd_parts,
        cwd=p["project_dir"],
        job_type="pq_eval",
        config={
            "script": f"docker compose {compose_args}",
            "action": action,
            "config_name": label,
            "project_dir": p["project_dir"],
        },
    )
    if err:
        return jsonify({"success": False, "error": err}), 409

    return jsonify({
        "success": True,
        "job_id": job_id,
        "action": action,
        "label": label,
        "script": f"docker compose {compose_args}",
        "project_dir": p["project_dir"],
        "message": f"Started '{label}' in {p['project_dir']}",
    })


@app.route('/api/pq/results', methods=['GET'])
def api_pq_results():
    """List PQ result files on this machine:
       - everything in <project>/results/json (per-run JSON; the script's
         legacy ike_pq_results symlink points at the same directory)
       - any *.csv in the project root (e.g. analyze_ike_results.py output)
       - *.pcap in <project>/results/pcaps (listed for reference/cleanup —
         they're binary, so they aren't fetchable through this API)
    Runs under sudo because the eval script (running as root) may have
    created the files with root ownership."""
    pq = CONFIG["post_quantum"]
    project_dir = _pq_project_dir()
    if not project_dir:
        return jsonify({"success": False, "error": "Could not locate the pq-ike-docker project (script lookup failed)"}), 400

    results_dir = f"{project_dir}/{pq['results_subdir']}"
    pcaps_dir = f"{project_dir}/{pq['pcaps_subdir']}"
    q = shlex.quote
    listing = f'''
echo "---JSON---"
if [ -d {q(results_dir)} ]; then cd {q(results_dir)} && for f in *; do [ -f "$f" ] && stat -c '%s|%Y|%n' "$f"; done; fi
echo "---CSV---"
if cd {q(project_dir)} 2>/dev/null; then for f in *.csv; do [ -f "$f" ] && stat -c '%s|%Y|%n' "$f"; done; fi
echo "---PCAP---"
if [ -d {q(pcaps_dir)} ]; then cd {q(pcaps_dir)} && for f in *.pcap; do [ -f "$f" ] && stat -c '%s|%Y|%n' "$f"; done; fi
'''
    result = run_pq_shell(listing, timeout=20, sudo=True)
    files = []
    if result["success"] and result.get("stdout"):
        section = "results"
        for line in result["stdout"].split('\n'):
            line = line.rstrip()
            if line == '---JSON---':
                section = "results"
                continue
            if line == '---CSV---':
                section = "parent"
                continue
            if line == '---PCAP---':
                section = "pcaps"
                continue
            if not line or '|' not in line:
                continue
            parts = line.split('|', 2)
            if len(parts) != 3:
                continue
            size_s, mtime_s, filename = parts
            try:
                size = int(size_s)
            except ValueError:
                size = 0
            try:
                mtime = datetime.fromtimestamp(int(mtime_s)).isoformat()
            except ValueError:
                mtime = ""
            ext = filename.rsplit('.', 1)[-1].lower() if '.' in filename else ''
            if ext == "csv":
                ftype = "csv"
            elif ext == "json":
                ftype = "json"
            elif ext == "pcap":
                ftype = "pcap"
            else:
                ftype = ext or "file"
            files.append({
                "filename": filename,
                "type": ftype,
                "location": section,         # "results" | "parent" | "pcaps"
                "size": size,
                "modified": mtime,
                "summary": "",               # populated on click
            })
    files.sort(key=lambda f: f.get("modified", ""), reverse=True)
    return jsonify({
        "success": True,
        "files": files,
        "host": _PQ_LOCAL_HOST,
        "project_dir": project_dir,
        "results_dir": results_dir,
        "pcaps_dir": pcaps_dir,
        "parent_dir": project_dir,           # kept for frontend back-compat
    })


@app.route('/api/pq/results/<path:filename>', methods=['GET'])
def api_pq_get_result(filename):
    """Fetch a single PQ result file. Returns parsed JSON when possible,
    raw text always, and the file type so the frontend can render
    appropriately. CSVs live in the project root; JSON files in
    results/json. Pcaps are binary and are not served through this API."""
    if '/' in filename or '..' in filename:
        return jsonify({"success": False, "error": "Invalid filename"}), 400

    full_path, kind = _pq_path(filename)
    if not full_path:
        return jsonify({"success": False, "error": "Could not locate the pq-ike-docker project"}), 400
    if kind == "pcap":
        return jsonify({
            "success": False,
            "error": f"{filename} is a binary capture — open it with Wireshark/tshark from {full_path}",
            "path": full_path,
            "type": "pcap",
        }), 400

    # Cap content size at 5 MB; sudo because the script may have written
    # the file as root.
    result = run_pq_shell(f"head -c 5242880 {shlex.quote(full_path)}", timeout=30, sudo=True)
    if not result["success"] or result.get("stdout") is None:
        return jsonify({"success": False, "error": f"Could not read {filename}"}), 404

    raw = result["stdout"]
    response = {
        "success": True,
        "filename": filename,
        "type": "csv" if kind == "csv" else ("json" if filename.lower().endswith(".json") else "text"),
        "raw": raw,
        "path": full_path,
    }
    if response["type"] == "json":
        try:
            response["data"] = json.loads(raw)
        except Exception as e:
            response["parse_error"] = str(e)
    return jsonify(response)


@app.route('/api/pq/results/<path:filename>', methods=['DELETE'])
def api_pq_delete_result(filename):
    """Delete a result file (JSON / CSV / pcap) from the project."""
    if '/' in filename or '..' in filename:
        return jsonify({"success": False, "error": "Invalid filename"}), 400
    full_path, _kind = _pq_path(filename)
    if not full_path:
        return jsonify({"success": False, "error": "Could not locate the pq-ike-docker project"}), 400
    result = run_pq_shell(f"rm -f {shlex.quote(full_path)}", timeout=10, sudo=True)
    return jsonify({
        "success": result["success"],
        "message": f"Deleted {filename}" if result["success"] else "Failed to delete",
    })



# ============================================================================
# API: DELAY CONTROLLER
# ============================================================================

@app.route('/api/delay/<location>/containers', methods=['GET'])
def get_delay_containers(location):
    if location not in ["local", "remote"]:
        return jsonify({"success": False, "error": "Invalid location"}), 400
    if request.args.get('refresh') == 'true':
        container_cache.invalidate(location)
    containers = get_network_containers_optimized(location)
    ipsec_status = check_ipsec_status(location)
    host_interface = get_host_interface(location)
    return jsonify({"success": True, "containers": containers, "location": location, "gtpu_port": GTPU_PORT, "ipsec": ipsec_status, "host_interface": host_interface, "delay_modes": {"gtpu-port": f"GTP-U N9 user plane (port {GTPU_PORT} + ESP, works with or without IPsec)", "ipsec-tunnel": f"IPsec tunnel (ESP + UDP {IPSEC_NAT_T_PORT}/{IPSEC_IKE_PORT})", "full": "All traffic on interface"}})


@app.route('/api/delay/<location>/set', methods=['POST'])
def api_set_delay(location):
    if location not in ["local", "remote"]:
        return jsonify({"success": False, "error": "Invalid location"}), 400
    data = request.get_json() or {}
    container_id = data.get('container')
    delay = data.get('delay')
    delay_mode = data.get('mode')
    if not container_id or not delay:
        return jsonify({"success": False, "error": "Container ID and delay are required"}), 400
    return jsonify(set_container_delay_optimized(container_id, delay, location, delay_mode))


@app.route('/api/delay/<location>/set-host', methods=['POST'])
def api_set_host_delay(location):
    if location not in ["local", "remote"]:
        return jsonify({"success": False, "error": "Invalid location"}), 400
    data = request.get_json() or {}
    delay = data.get('delay')
    mode = data.get('mode', 'auto')
    if not delay:
        return jsonify({"success": False, "error": "Delay is required"}), 400
    interface = get_host_interface(location)
    if mode == 'auto':
        ipsec_status = check_ipsec_status(location)
        result = set_ipsec_tunnel_delay(interface, delay, location) if ipsec_status["active"] else set_gtpu_port_delay(interface, delay, location)
    elif mode == 'ipsec-tunnel':
        result = set_ipsec_tunnel_delay(interface, delay, location)
    elif mode == 'gtpu-port':
        result = set_gtpu_port_delay(interface, delay, location)
    elif mode == 'full':
        result = set_full_interface_delay(interface, delay, location)
    else:
        return jsonify({"success": False, "error": f"Invalid mode: {mode}"}), 400
    return jsonify(result)


@app.route('/api/delay/<location>/remove', methods=['POST'])
def api_remove_delay(location):
    if location not in ["local", "remote"]:
        return jsonify({"success": False, "error": "Invalid location"}), 400
    data = request.get_json() or {}
    container_id = data.get('container')
    if not container_id:
        return jsonify({"success": False, "error": "Container ID is required"}), 400
    return jsonify(remove_container_delay_optimized(container_id, location))


@app.route('/api/delay/<location>/remove-host', methods=['POST'])
def api_remove_host_delay(location):
    if location not in ["local", "remote"]:
        return jsonify({"success": False, "error": "Invalid location"}), 400
    interface = get_host_interface(location)
    return jsonify(remove_interface_delay(interface, location))


@app.route('/api/delay/<location>/remove-all', methods=['POST'])
def api_remove_all_delays(location):
    if location not in ["local", "remote"]:
        return jsonify({"success": False, "error": "Invalid location"}), 400
    return jsonify(remove_all_delays_optimized(location))


@app.route('/api/delay/cache/clear', methods=['POST'])
def clear_delay_cache():
    container_cache.invalidate()
    return jsonify({"success": True, "message": "Cache cleared"})


# ============================================================================
# API: QUICK DELAY (Dashboard — SEPP / UPF / DN)
# ============================================================================

# ── Bidirectional quick-delay helpers ───────────────────────────────────────
# Each "link" is delayed on BOTH endpoints so traffic is delayed in both
# directions. The interface/filter for each endpoint mirrors the automation
# script (lib/automation/delays.sh):
#   SEPP-SEPP (N32) : netem inside each open5gs-sepp container eth0, ports 8080/8081
#   UPF-UPF (GTP-U) : netem on each host's default interface, port 2152
#                     (UPF is host-network, so its GTP-U rides the host NIC)
#   hSMF-hUPF (N4)  : kept in the backend, hidden from the dashboard for demos
#   UPF-DN (N6)     : netem on both UPF ogstun interfaces and the DN interface

def _service_container(service_substr, location):
    """Resolve the running container name for an Open5GS service on a PC."""
    for c in get_all_containers_batch(location):
        if service_substr in c.get("service", "").lower():
            return c["name"]
    return None


def get_docker_bridge_interface(network_name, location="local"):
    """Host bridge interface (br-<id>) backing a docker bridge network."""
    r = run_command(location, f"docker network inspect '{network_name}' -f '{{{{.Id}}}}' 2>/dev/null")
    nid = r["stdout"].strip()[:12] if r["success"] else ""
    return f"br-{nid}" if nid else None


def set_container_port_delay(service, location, delay, ports):
    """Port-filtered netem on a bridged container's eth0 (inside the container)."""
    name = _service_container(service, location)
    if not name:
        return {"success": False, "error": f"{service} container not found on {location}"}
    inner = ["tc qdisc del dev eth0 root 2>/dev/null || true",
             "tc qdisc add dev eth0 root handle 1: prio",
             f"tc qdisc add dev eth0 parent 1:3 handle 30: netem limit {NETEM_LIMIT} delay {delay}"]
    for p in ports:
        inner.append(f"tc filter add dev eth0 protocol ip parent 1:0 prio 1 u32 match ip dport {p} 0xffff flowid 1:3")
        inner.append(f"tc filter add dev eth0 protocol ip parent 1:0 prio 1 u32 match ip sport {p} 0xffff flowid 1:3")
    r = run_command(location, f"sudo docker exec {name} sh -c '{'; '.join(inner)}'")
    container_cache.invalidate(location)
    if r["success"]:
        return {"success": True, "container": name}
    return {"success": False, "error": r.get("stderr") or r.get("error") or "Failed"}


def set_interface_port_delay(interface, location, delay, ports):
    """Port-filtered netem on a host interface (default NIC or docker bridge)."""
    if not interface:
        return {"success": False, "error": "Interface not found"}
    cmds = [f"sudo tc qdisc del dev {interface} root 2>/dev/null || true",
            f"sudo tc qdisc add dev {interface} root handle 1: prio",
            f"sudo tc qdisc add dev {interface} parent 1:3 handle 30: netem limit {NETEM_LIMIT} delay {delay}"]
    for p in ports:
        cmds.append(f"sudo tc filter add dev {interface} protocol ip parent 1:0 prio 1 u32 match ip dport {p} 0xffff flowid 1:3")
        cmds.append(f"sudo tc filter add dev {interface} protocol ip parent 1:0 prio 1 u32 match ip sport {p} 0xffff flowid 1:3")
    for cmd in cmds:
        r = run_command(location, cmd)
        if not r["success"] and "del dev" not in cmd:
            return {"success": False, "error": f"Failed: {r.get('stderr', r.get('error', '?'))}"}
    container_cache.invalidate(location)
    return {"success": True, "interface": interface}


def remove_container_eth0_delay(service, location):
    name = _service_container(service, location)
    if not name:
        return {"success": False, "error": f"{service} container not found on {location}"}
    run_command(location, f"sudo docker exec {name} sh -c 'tc qdisc del dev eth0 root 2>/dev/null || true'")
    container_cache.invalidate(location)
    return {"success": True, "container": name}


def get_container_eth0_delay(service, location):
    name = _service_container(service, location)
    if not name:
        return None
    r = run_command(location, f"sudo docker exec {name} tc qdisc show dev eth0 2>/dev/null", timeout=5)
    if r["success"] and "netem" in r["stdout"]:
        m = re.search(r'delay\s+([\d.]+\s*\w+)', r["stdout"])
        if m:
            return m.group(1).replace(" ", "")
    return None


def _upf_container(location):
    """Resolve the primary UPF container, avoiding upf2 when it exists."""
    containers = get_all_containers_batch(location)
    for c in containers:
        if c.get("name") == "open5gs-upf":
            return c["name"]
    for c in containers:
        service = c.get("service", "").lower()
        if service == "upf" or service == "open5gs-upf":
            return c["name"]
    for c in containers:
        name = c.get("name", "").lower()
        if "upf" in name and "upf2" not in name:
            return c["name"]
    return None


# Both directions of the N6 delay are applied on the UPF, never on the DN.
# That is deliberate: the DN may be a host we do not control (8.8.8.8 as
# easily as our own perf server), so anything that needs to SSH into the far
# end only works for one kind of target. Shaping both directions at the UPF
# behaves identically whichever DN is in use.
#
# netem on a root qdisc shapes EGRESS only. On ogstun (the UE-side TUN,
# 10.45.0.0/16) egress is the downlink, DN->UE. The uplink arrives as ingress,
# which netem cannot touch, so it is mirrored into an IFB device and shaped
# there — before the UPF's MASQUERADE rewrites the source address.
# Same netem queue size as the automation (lib/automation/delays.sh): the
# 1000-packet default drops traffic at high rate x delay, which a real link
# would not.
NETEM_LIMIT = 10000
N6_IFB_DEV = "ifb-n6"


def set_upf_dn_delay(location, delay):
    """Apply the N6/DN delay in BOTH directions at the UPF."""
    name = _upf_container(location)
    if not name:
        return {"success": False, "error": f"UPF container not found on {location}"}
    # The container cannot modprobe; load the module on the host first.
    run_command(location, "sudo modprobe ifb 2>/dev/null || true")
    cmd = (
        f"ip link show {N6_IFB_DEV} >/dev/null 2>&1 || ip link add {N6_IFB_DEV} type ifb; "
        f"ip link set {N6_IFB_DEV} up; "
        # Recreate the ingress qdisc so repeated applies don't stack filters.
        "tc qdisc del dev ogstun ingress 2>/dev/null || true; "
        "tc qdisc add dev ogstun handle ffff: ingress; "
        "tc filter add dev ogstun parent ffff: protocol ip u32 match u32 0 0 "
        f"action mirred egress redirect dev {N6_IFB_DEV}; "
        f"tc qdisc replace dev {N6_IFB_DEV} root netem limit {NETEM_LIMIT} delay {delay}; "   # uplink
        f"tc qdisc replace dev ogstun root netem limit {NETEM_LIMIT} delay {delay}"           # downlink
    )
    r = run_command(location, f"sudo docker exec {name} sh -c {shlex.quote(cmd)}")
    container_cache.invalidate(location)
    if r["success"]:
        return {"success": True, "container": name, "interface": "ogstun",
                "uplink_device": N6_IFB_DEV, "directions": "both"}
    return {"success": False, "error": r.get("stderr") or r.get("error") or "Failed"}


def remove_upf_dn_delay(location):
    name = _upf_container(location)
    if not name:
        return {"success": False, "error": f"UPF container not found on {location}"}
    cmd = (
        "tc qdisc del dev ogstun root 2>/dev/null || true; "
        "tc qdisc del dev ogstun ingress 2>/dev/null || true; "
        f"tc qdisc del dev {N6_IFB_DEV} root 2>/dev/null || true; "
        f"ip link del {N6_IFB_DEV} 2>/dev/null || true"
    )
    run_command(location, f"sudo docker exec {name} sh -c {shlex.quote(cmd)}")
    container_cache.invalidate(location)
    return {"success": True, "container": name, "interface": "ogstun"}


def _netem_delay_of(text):
    if not text or "netem" not in text:
        return None
    m = re.search(r'delay\s+([\d.]+\s*\w+)', text)
    return m.group(1).replace(" ", "") if m else None


def get_upf_dn_delay(location):
    """Returns {"downlink": d, "uplink": u} — either may be None."""
    name = _upf_container(location)
    if not name:
        return None
    cmd = (f"echo DOWN:$(tc qdisc show dev ogstun 2>/dev/null | head -1); "
           f"echo UP:$(tc qdisc show dev {N6_IFB_DEV} 2>/dev/null | head -1)")
    r = run_command(location, f"sudo docker exec {name} sh -c {shlex.quote(cmd)}", timeout=8)
    if not r["success"]:
        return None
    down = up = None
    for line in (r["stdout"] or "").splitlines():
        if line.startswith("DOWN:"):
            down = _netem_delay_of(line)
        elif line.startswith("UP:"):
            up = _netem_delay_of(line)
    if not down and not up:
        return None
    return {"downlink": down, "uplink": up}


def _combine_delay_results(label, delay, parts):
    """parts = [(endpoint_name, result_dict), ...]"""
    fails = [(n, r) for n, r in parts if not r.get("success")]
    if not fails:
        suffix = " (all endpoints)" if len(parts) > 2 else " (both endpoints)" if len(parts) > 1 else ""
        return {"success": True, "message": f"Delay {delay} applied to {label}{suffix}"}
    detail = "; ".join(f"{n}: {r.get('error')}" for n, r in fails)
    if len(fails) == len(parts):
        return {"success": False, "error": f"{label} — {detail}"}
    return {"success": True, "partial": True, "message": f"Delay {delay} applied to {label}, but {detail}"}


@app.route('/api/delay/quick/status', methods=['GET'])
def quick_delay_status():
    local_iface  = get_host_interface("local")
    remote_iface = get_host_interface("remote")
    cp_bridge    = get_docker_bridge_interface(CONTROL_PLANE_NETWORK, "remote")
    with ThreadPoolExecutor(max_workers=9) as ex:
        f_sepp_l = ex.submit(get_container_eth0_delay, "sepp", "local")
        f_sepp_r = ex.submit(get_container_eth0_delay, "sepp", "remote")
        f_upf_l  = ex.submit(detect_current_delay_mode, local_iface, "local")
        f_upf_r  = ex.submit(detect_current_delay_mode, remote_iface, "remote")
        f_smf_r  = ex.submit(get_container_eth0_delay, "smf", "remote")
        f_hupf_r = ex.submit(detect_current_delay_mode, cp_bridge, "remote") if cp_bridge else None
        f_dn_l   = ex.submit(get_upf_dn_delay, "local")
        f_dn_r   = ex.submit(get_upf_dn_delay, "remote")
        sepp_l, sepp_r = f_sepp_l.result(), f_sepp_r.result()
        upf_l, upf_r   = f_upf_l.result()["delay"], f_upf_r.result()["delay"]
        smf_r          = f_smf_r.result()
        hupf_r         = f_hupf_r.result()["delay"] if f_hupf_r else None
        dn_l, dn_r     = f_dn_l.result(), f_dn_r.result()

    # The tile compares "delay" against its presets, so report a plain value
    # when both directions match, and flag it when they don't.
    dn = dn_l or dn_r or {}
    down, up = dn.get("downlink"), dn.get("uplink")
    if down and up and down == up:
        dn_delay, symmetric = down, True
    elif down or up:
        dn_delay, symmetric = (down or up), False
    else:
        dn_delay, symmetric = None, True

    return jsonify({
        "success": True,
        "sepp-sepp": {"delay": sepp_l or sepp_r, "vsepp": sepp_l, "hsepp": sepp_r},
        "upf-upf":   {"delay": upf_l or upf_r,   "vupf": upf_l,   "hupf": upf_r},
        "hsmf-hupf": {"delay": smf_r or hupf_r,  "hsmf": smf_r,   "hupf": hupf_r},
        "upfs-dn":   {"delay": dn_delay, "symmetric": symmetric,
                      "downlink": down, "uplink": up, "vupf": dn_l, "hupf": dn_r},
    })


@app.route('/api/delay/quick/set', methods=['POST'])
def quick_delay_set():
    data   = request.get_json() or {}
    target = data.get('target')
    delay  = (data.get('delay') or '').strip()
    if not re.fullmatch(r'\d+(\.\d+)?(ms|s)', delay):
        return jsonify({"success": False, "error": "Invalid delay format (e.g. 50ms)"}), 400

    if target == 'sepp-sepp':
        r1 = set_container_port_delay("sepp", "local",  delay, SEPP_N32_PORTS)
        r2 = set_container_port_delay("sepp", "remote", delay, SEPP_N32_PORTS)
        return jsonify(_combine_delay_results("SEPP-SEPP (N32)", delay, [("vSEPP", r1), ("hSEPP", r2)]))
    elif target == 'upf-upf':
        r1 = set_gtpu_port_delay(get_host_interface("local"),  delay, "local")
        r2 = set_gtpu_port_delay(get_host_interface("remote"), delay, "remote")
        return jsonify(_combine_delay_results("UPF-UPF (GTP-U)", delay, [("vUPF", r1), ("hUPF", r2)]))
    elif target == 'hsmf-hupf':
        r1 = set_container_port_delay("smf", "remote", delay, [PFCP_PORT])
        r2 = set_interface_port_delay(get_docker_bridge_interface(CONTROL_PLANE_NETWORK, "remote"), "remote", delay, [PFCP_PORT])
        return jsonify(_combine_delay_results("hSMF-hUPF (N4/PFCP)", delay, [("hSMF", r1), ("hUPF", r2)]))
    elif target == 'upfs-dn':
        # Both UPFs only — nothing is applied on the DN, so this behaves the
        # same whether the DN is our perf server or an external host.
        r1 = set_upf_dn_delay("local", delay)
        r2 = set_upf_dn_delay("remote", delay)
        return jsonify(_combine_delay_results("UPFs-DN (N6, both directions)", delay, [("vUPF", r1), ("hUPF", r2)]))
    return jsonify({"success": False, "error": "Invalid target"}), 400


@app.route('/api/delay/quick/remove', methods=['POST'])
def quick_delay_remove():
    data   = request.get_json() or {}
    target = data.get('target')
    if target == 'sepp-sepp':
        remove_container_eth0_delay("sepp", "local")
        remove_container_eth0_delay("sepp", "remote")
        return jsonify({"success": True, "message": "Delay removed from SEPP-SEPP (both)"})
    elif target == 'upf-upf':
        remove_interface_delay(get_host_interface("local"),  "local")
        remove_interface_delay(get_host_interface("remote"), "remote")
        return jsonify({"success": True, "message": "Delay removed from UPF-UPF (both)"})
    elif target == 'hsmf-hupf':
        remove_container_eth0_delay("smf", "remote")
        remove_interface_delay(get_docker_bridge_interface(CONTROL_PLANE_NETWORK, "remote"), "remote")
        return jsonify({"success": True, "message": "Delay removed from hSMF-hUPF (both)"})
    elif target == 'upfs-dn':
        remove_upf_dn_delay("local")
        remove_upf_dn_delay("remote")
        return jsonify({"success": True, "message": "Delay removed from both UPF-DN links"})
    return jsonify({"success": False, "error": "Invalid target"}), 400


# ============================================================================
# API: CONFIG FILES
# ============================================================================

@app.route('/api/configs', methods=['GET'])
def list_configs():
    configs_dir = CONFIG["configs_dir"]
    files = []
    if os.path.exists(configs_dir):
        for f in sorted(os.listdir(configs_dir)):
            if f.endswith('.conf'):
                path = os.path.join(configs_dir, f)
                # Dongle configs can't run without commercial RAN support — hide them
                if not DONGLE_ENABLED and _is_dsk_config(path):
                    continue
                stat = os.stat(path)
                summary = ""
                try:
                    with open(path) as fh:
                        for line in fh:
                            line = line.strip()
                            if line.startswith("ROAMING_MODE="):
                                summary += f"Roaming: {line.split('=')[1]} "
                            elif line.startswith("IPSEC_ENABLED="):
                                summary += f"N9: {line.split('=')[1]} "
                            elif line.startswith("N4_IPSEC_ENABLED="):
                                summary += f"N4: {line.split('=')[1]} "
                            elif line.startswith("N4_IPSEC_VPLMN_ENABLED="):
                                summary += f"N4·V: {line.split('=')[1]} "
                            elif line.startswith("N4_IPSEC_HPLMN_ENABLED="):
                                summary += f"N4·H: {line.split('=')[1]} "
                            elif line.startswith("ITERATIONS="):
                                summary += f"Iter: {line.split('=')[1]} "
                            elif line.lower() == "ue_type=dsk":
                                summary += "UE: dongle "
                except Exception:
                    pass
                files.append({"filename": f, "size": stat.st_size, "modified": datetime.fromtimestamp(stat.st_mtime).isoformat(), "summary": summary.strip()})
    generated_dir = os.path.join(configs_dir, "generated")
    if os.path.exists(generated_dir):
        for f in sorted(os.listdir(generated_dir)):
            if f.endswith('.conf'):
                path = os.path.join(generated_dir, f)
                stat = os.stat(path)
                files.append({"filename": f"generated/{f}", "size": stat.st_size, "modified": datetime.fromtimestamp(stat.st_mtime).isoformat(), "summary": "(generated)"})
    return jsonify({"success": True, "files": files, "configs_dir": configs_dir})


@app.route('/api/configs/<path:filename>', methods=['GET'])
def get_config(filename):
    path = os.path.join(CONFIG["configs_dir"], filename)
    if not os.path.exists(path):
        return jsonify({"error": "Not found"}), 404
    with open(path) as f:
        content = f.read()
    return jsonify({"success": True, "filename": filename, "content": content})


@app.route('/api/configs', methods=['POST'])
def create_config():
    data = request.get_json() or {}
    filename = data.get('filename')
    if not filename:
        return jsonify({"success": False, "error": "Filename required"}), 400
    if not filename.endswith('.conf'):
        filename += '.conf'
    if data.get('raw_content'):
        content = data['raw_content']
    else:
        if _dsk_requested_while_disabled(data.get('params', data)):
            return jsonify({"success": False, "error": DSK_DISABLED_MSG}), 400
        content = generate_config_content(data.get('params', data))
    path = os.path.join(CONFIG["configs_dir"], filename)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        f.write(content)
    return jsonify({"success": True, "filename": filename, "path": path, "message": f"Config file '{filename}' created"})


@app.route('/api/configs/<path:filename>', methods=['PUT'])
def update_config(filename):
    data = request.get_json() or {}
    path = os.path.join(CONFIG["configs_dir"], filename)
    if not os.path.exists(path):
        return jsonify({"error": "Not found"}), 404
    content = data.get('content')
    if not content:
        return jsonify({"success": False, "error": "Content required"}), 400
    with open(path, 'w') as f:
        f.write(content)
    return jsonify({"success": True, "message": f"Config '{filename}' updated"})


@app.route('/api/configs/<path:filename>', methods=['DELETE'])
def delete_config(filename):
    path = os.path.join(CONFIG["configs_dir"], filename)
    if not os.path.exists(path):
        return jsonify({"error": "Not found"}), 404
    os.remove(path)
    return jsonify({"success": True, "message": f"Config '{filename}' deleted"})


# ============================================================================
# API: SCRIPT EXECUTION
# ============================================================================

@app.route('/api/scripts/automation/run', methods=['POST'])
def run_automation_script():
    data = request.get_json() or {}
    config_file = data.get('config_file')
    if not config_file:
        return jsonify({"success": False, "error": "config_file is required"}), 400
    if not os.path.isabs(config_file):
        config_file = os.path.join(CONFIG["configs_dir"], config_file)
    if not os.path.exists(config_file):
        return jsonify({"success": False, "error": f"Config file not found: {config_file}"}), 400
    script = CONFIG["automation_script"]
    if not os.path.exists(script):
        return jsonify({"success": False, "error": f"Automation script not found: {script}"}), 400
    job_id, err = run_script_in_background(
        script, args=["--config", config_file], cwd=CONFIG["testbed_dir"],
        job_type="automation", config={"config_file": os.path.basename(config_file), "script": "testbed_automation.sh"}
    )
    if err:
        return jsonify({"success": False, "error": err}), 400
    return jsonify({"success": True, "job_id": job_id, "message": f"Automation started with {os.path.basename(config_file)}"})


@app.route('/api/scripts/automation/run-inline', methods=['POST'])
def run_automation_inline():
    data = request.get_json() or {}
    if _dsk_requested_while_disabled(data):
        return jsonify({"success": False, "error": DSK_DISABLED_MSG}), 400
    content = generate_config_content(data)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    filename = f"webui_run_{timestamp}.conf"
    path = os.path.join(CONFIG["configs_dir"], filename)
    with open(path, 'w') as f:
        f.write(content)
    script = CONFIG["automation_script"]
    if not os.path.exists(script):
        return jsonify({"success": False, "error": "Automation script not found"}), 400
    job_id, err = run_script_in_background(
        script, args=["--config", path], cwd=CONFIG["testbed_dir"],
        job_type="automation", config={"config_file": filename, "script": "testbed_automation.sh", "params": data}
    )
    if err:
        return jsonify({"success": False, "error": err}), 400
    return jsonify({"success": True, "job_id": job_id, "config_file": filename, "message": "Automation started"})


@app.route('/api/scripts/batch-runner/run', methods=['POST'])
def run_batch_runner_script():
    data = request.get_json() or {}
    script = CONFIG["batch_runner_script"]
    if not os.path.exists(script):
        return jsonify({"success": False, "error": "Batch runner script not found"}), 400
    args = []
    iterations = data.get('iterations', 1)
    args.extend(["-i", str(iterations)])
    reload_interval = data.get('reload_interval', 10)
    args.extend(["-r", str(reload_interval)])
    # Continue an interrupted batch (Ctrl+C, crash, or a dongle SIM that had to
    # be swapped): batch_runner.sh skips the configs that already finished.
    if data.get('resume', False):
        args.append("--resume")
    if data.get('run_all', False):
        args.append("--all")
    else:
        config_files = data.get('config_files', [])
        if not config_files:
            return jsonify({"success": False, "error": "No config files specified"}), 400
        for cf in config_files:
            if not cf.startswith('/'):
                abs_path = os.path.join(CONFIG["configs_dir"], cf)
                if os.path.exists(abs_path):
                    cf = abs_path
                else:
                    alt_path = os.path.join(CONFIG["testbed_dir"], "configs", cf)
                    cf = alt_path if os.path.exists(alt_path) else abs_path
            args.append(cf)
    job_id, err = run_script_in_background(
        script, args=args, cwd=CONFIG["testbed_dir"],
        job_type="batch_runner",
        config={"script": "batch_runner.sh", "iterations": iterations, "run_all": data.get('run_all', False), "config_files": data.get('config_files', [])}
    )
    if err:
        return jsonify({"success": False, "error": err}), 400
    return jsonify({"success": True, "job_id": job_id, "message": "Batch runner started"})


def _last_batch_info():
    """The batch `batch_runner.sh --resume` would continue: its saved command
    (logs/batch_runner.last, NUL-separated arguments) and how many runs its
    state file marks done. None when there is no unfinished batch."""
    last = os.path.join(CONFIG["testbed_dir"], "logs", "batch_runner.last")
    try:
        with open(last, "rb") as f:
            args = [a.decode() for a in f.read().split(b"\0") if a]
    except OSError:
        return None
    if not args:
        return None
    # Which state file: a single matrix file (MODE_NAMES=, not main.conf) has
    # its own, as in batch_runner.sh; everything else uses batch_runner.state.
    state_name = "batch_runner.state"
    takes_value = {"-i", "--iterations", "-r", "--reload-interval", "-ris",
                   "--restart-iperf-server", "-rds", "--restart-download-server"}
    configs, skip = [], False
    for a in args:
        if skip:
            skip = False
        elif a in takes_value:
            skip = True
        elif not a.startswith("-"):
            configs.append(a)
    if "-a" not in args and "--all" not in args and len(configs) == 1:
        path = configs[0] if configs[0].startswith("/") else os.path.join(CONFIG["configs_dir"], configs[0])
        try:
            with open(path) as f:
                is_matrix = any(l.lstrip().startswith("MODE_NAMES=") for l in f)
        except OSError:
            is_matrix = False
        if is_matrix and os.path.realpath(path) != os.path.realpath(os.path.join(CONFIG["configs_dir"], "main.conf")):
            state_name = f"batch_runner_{os.path.splitext(os.path.basename(path))[0]}.state"
    done = 0
    try:
        with open(os.path.join(CONFIG["testbed_dir"], "logs", state_name)) as f:
            done = sum(1 for l in f if l.startswith("DONE "))
    except OSError:
        pass
    return {"args": args, "command": "batch_runner.sh " + " ".join(os.path.basename(a) for a in args),
            "state_file": state_name, "runs_done": done,
            "saved_at": datetime.fromtimestamp(os.path.getmtime(last)).isoformat(timespec="seconds")}


@app.route('/api/scripts/batch-runner/last', methods=['GET'])
def get_last_batch():
    return jsonify({"success": True, "last": _last_batch_info()})


@app.route('/api/scripts/batch-runner/resume-last', methods=['POST'])
def resume_last_batch():
    """Continue the last batch: batch_runner.sh --resume repeats its saved
    command and skips the runs already done."""
    script = CONFIG["batch_runner_script"]
    if not os.path.exists(script):
        return jsonify({"success": False, "error": "Batch runner script not found"}), 400
    info = _last_batch_info()
    if not info:
        return jsonify({"success": False, "error": "No unfinished batch to resume"}), 400
    job_id, err = run_script_in_background(
        script, args=["--resume"], cwd=CONFIG["testbed_dir"],
        job_type="batch_runner",
        config={"script": "batch_runner.sh", "resume_last": True, "command": info["command"]}
    )
    if err:
        return jsonify({"success": False, "error": err}), 400
    return jsonify({"success": True, "job_id": job_id, "message": f"Resuming: {info['command']}"})


@app.route('/api/scripts/status', methods=['GET'])
def get_script_status():
    job = script_job_manager.get_current_job()
    return jsonify({"success": True, "job": job})


@app.route('/api/scripts/output', methods=['GET'])
def get_script_output():
    n = int(request.args.get('lines', 200))
    lines = script_job_manager.get_recent_output(n)
    return jsonify({"success": True, "lines": lines, "total": len(lines)})


@app.route('/api/scripts/cancel', methods=['POST'])
def cancel_script():
    success = script_job_manager.cancel_job()
    return jsonify({"success": success, "message": "Cancelled" if success else "No running job"})


@app.route('/api/scripts/history', methods=['GET'])
def get_script_history():
    return jsonify({"success": True, "history": script_job_manager.get_history()})


@app.route('/api/scripts/output/stream')
def stream_script_output():
    def generate():
        last_count = 0
        while True:
            job = script_job_manager.get_current_job()
            if not job:
                yield f"data: {json.dumps({'type': 'no_job'})}\n\n"
                break
            lines = script_job_manager.get_recent_output(5000)
            new_lines = lines[last_count:]
            last_count = len(lines)
            for line in new_lines:
                yield f"data: {json.dumps({'type': 'output', 'line': line})}\n\n"
            if job['status'] != 'running':
                yield f"data: {json.dumps({'type': 'completed', 'status': job['status'], 'exit_code': job.get('exit_code')})}\n\n"
                break
            time.sleep(0.3)
    return Response(generate(), mimetype='text/event-stream', headers={'Cache-Control': 'no-cache', 'Connection': 'keep-alive', 'X-Accel-Buffering': 'no'})


# ============================================================================
# NETWORK ENDPOINTS
# ============================================================================

@app.route('/api/network/<location>/status', methods=['GET'])
def get_network_status(location):
    if location not in ["local", "remote"]:
        return jsonify({"error": "Invalid location"}), 400
    path = CONFIG[location]["path"]
    result = run_command(location, f"cd {path} && sudo docker compose ps --format json")
    containers = []
    if result["success"] and result["stdout"].strip():
        for line in result["stdout"].strip().split('\n'):
            try:
                c = json.loads(line)
                containers.append({"name": c.get("Name", ""), "service": c.get("Service", ""), "state": c.get("State", ""), "status": c.get("Status", "")})
            except Exception:
                pass
    env_result = run_command(location, f"cd {path} && cat .env 2>/dev/null || echo ''")
    _env_stdout = env_result.get("stdout", "")
    # v2.8.0: the core has no roaming mode (one unified image set), so status
    # reports only the security (TLS/plain) config the .env selects.
    mode = {"security": "tls" if "_tls.yaml" in _env_stdout else "plain" if ".yaml" in _env_stdout else "unknown"}
    all_running = all(c["state"] == "running" for c in containers) if containers else False
    ipsec = check_ipsec_status_detailed(location)
    # Include the configured N9 esp= so the IPsec page's combined box + per-peer
    # panels can show which cipher is active (this aggregate status is what feeds
    # localStatus/remoteStatus; the per-location /ipsec/<loc>/status adds it too).
    ipsec["active_esp"] = read_active_esp_line(location)
    resp = {"status": "running" if all_running else ("partial" if containers else "stopped"), "containers": containers, "current_mode": mode, "ipsec": ipsec}
    # N4 (SMF<->UPF) IPsec is per-PLMN — surface each side's on its own box.
    resp["n4ipsec"] = check_n4_ipsec_status(location)
    return jsonify(resp)


@app.route('/api/network/<location>/start', methods=['POST'])
def start_network(location):
    if location not in ["local", "remote"]:
        return jsonify({"error": "Invalid"}), 400
    data = request.get_json() or {}
    path = CONFIG[location]["path"]
    if data.get('security_mode'):
        # v2.8.0: the core is a single unified image set for every roaming mode,
        # so starting a PLMN no longer takes a roaming mode — only the security
        # (TLS/plain) config suffix. HR vs LBO vs Non-Roaming is chosen per
        # subscriber (lbo_roaming_allowed) and by which PacketRusher config runs.
        env = generate_env_content(data['security_mode'], None, location == "local", include_credentials=(location == "local"))
        run_command(location, f"cd {path} && cat > .env << 'EOF'\n{env}\nEOF")
    run_command(location, f"cd {path} && sudo docker compose down", timeout=120)
    result = run_command(location, f"cd {path} && sudo docker compose up -d", timeout=180)
    container_cache.invalidate(location)
    return jsonify({"success": result["success"], "message": "Started" if result["success"] else result.get("stderr", "Failed")})


@app.route('/api/network/<location>/stop', methods=['POST'])
def stop_network(location):
    if location not in ["local", "remote"]:
        return jsonify({"error": "Invalid"}), 400
    result = run_command(location, f"cd {CONFIG[location]['path']} && sudo docker compose down", timeout=120)
    container_cache.invalidate(location)
    return jsonify({"success": result["success"]})


@app.route('/api/container/<location>/<container>/logs', methods=['GET'])
def get_container_logs(location, container):
    if location not in ["local", "remote"]:
        return jsonify({"error": "Invalid"}), 400
    result = run_command(location, f"cd {CONFIG[location]['path']} && docker compose logs --tail={request.args.get('lines', '100')} {container}")
    return jsonify({"success": result["success"], "logs": result.get("stdout", "")})


@app.route('/api/network/<location>/logs/stream')
def stream_compose_logs(location):
    """Live `docker compose logs -f` for a whole testbed, as SSE.

    Mainly there to watch the VPLMN while a dongle UE attaches — that can
    take a while and the compose log is the only place you see it happen.
    The follower is killed as soon as the browser closes the stream."""
    if location not in ["local", "remote"]:
        return jsonify({"error": "Invalid"}), 400
    tail = str(request.args.get('tail', '200'))
    if not re.match(r'^\d+$', tail):
        tail = '200'
    service = (request.args.get('service') or '').strip()
    if service and not re.match(r'^[\w.-]+$', service):
        return jsonify({"error": "Invalid service"}), 400

    log_cmd = f"cd {CONFIG[location]['path']} && sudo docker compose logs -f --no-color --tail={tail}"
    if service:
        log_cmd += f" {service}"
    if location == "local":
        argv = ["bash", "-c", log_cmd]
    else:
        argv = ["ssh", "-o", "ConnectTimeout=10", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
                f"{CONFIG['remote']['user']}@{CONFIG['remote']['host']}", log_cmd]

    def generate():
        proc = None
        try:
            proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True, bufsize=1, preexec_fn=os.setsid)
            yield f"data: {json.dumps({'type': 'start', 'location': location, 'command': log_cmd})}\n\n"
            last_beat = time.time()
            while True:
                ready, _, _ = select.select([proc.stdout], [], [], 1.0)
                if ready:
                    line = proc.stdout.readline()
                    if not line:
                        break
                    # Open5GS colorizes its own log lines; --no-color only
                    # drops compose's prefix coloring, so strip the rest here.
                    clean = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', line.rstrip())
                    payload = json.dumps({'type': 'line', 'line': clean})
                    yield f"data: {payload}\n\n"
                else:
                    if proc.poll() is not None:
                        break
                    if time.time() - last_beat > 10:
                        last_beat = time.time()
                        yield f"data: {json.dumps({'type': 'heartbeat'})}\n\n"
            yield f"data: {json.dumps({'type': 'end', 'exit_code': proc.poll()})}\n\n"
        except GeneratorExit:
            raise
        except Exception as e:
            yield f"data: {json.dumps({'type': 'error', 'message': str(e)})}\n\n"
        finally:
            if proc and proc.poll() is None:
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                except Exception:
                    pass
    return Response(generate(), mimetype='text/event-stream',
                    headers={'Cache-Control': 'no-cache', 'Connection': 'keep-alive', 'X-Accel-Buffering': 'no'})


# ============================================================================
# PACKETRUSHER
# ============================================================================

@app.route('/api/packetrusher/status', methods=['GET'])
def get_packetrusher_status():
    result = run_local_command(f"sudo docker ps -a --filter name={CONFIG['packetrusher']['container']} --format json")
    if result["success"] and result["stdout"].strip():
        try:
            d = json.loads(result["stdout"].strip().split('\n')[0])
            return jsonify({"status": "running" if d.get("State") == "running" else "stopped"})
        except Exception:
            pass
    return jsonify({"status": "not_found"})


@app.route('/api/packetrusher/stop', methods=['POST'])
def stop_packetrusher():
    stop_packetrusher_internal()
    return jsonify({"success": True})


@app.route('/api/packetrusher/reset', methods=['POST'])
def reset_packetrusher():
    run_local_command(f"sudo docker rm -f {CONFIG['packetrusher']['container']} 2>/dev/null || true")
    cleanup_packetrusher_interfaces()
    return jsonify({"success": True, "message": "Container removed and stale GTP interfaces cleaned up"})


@app.route('/api/packetrusher/logs', methods=['GET'])
def get_packetrusher_logs():
    result = run_local_command(f"sudo docker logs --tail={request.args.get('lines', '100')} {CONFIG['packetrusher']['container']} 2>&1")
    return jsonify({"success": result["success"], "logs": result.get("stdout", "")})


@app.route('/api/packetrusher/configs', methods=['GET'])
def get_packetrusher_configs():
    result = run_local_command(f"ls {os.path.expanduser(CONFIG['packetrusher']['config_path'])}/*.yml 2>/dev/null | xargs -n1 basename")
    return jsonify({"success": True, "configs": result["stdout"].strip().split('\n') if result["success"] and result["stdout"].strip() else []})


# ============================================================================
# DONGLE UE — real UE on another PC, driven over SSH (alternative to
# PacketRusher). Runs ping_pcap.sh there and streams its stdout back.
# ============================================================================

# The dongle scripts end with this prefix followed by a JSON object;
# dongle_ping.sh additionally emits one PING_JSON line per reply.
DONGLE_RESULT_PREFIX = "RESULT_JSON "
DONGLE_PING_PREFIX = "PING_JSON "
# dongle_iperf.sh emits the whole `iperf3 -J` document on one line; the download
# script emits curl's --write-out object the same way.
DONGLE_IPERF_PREFIX = "IPERF_JSON "
DONGLE_DOWNLOAD_PREFIX = "DL_JSON "
DONGLE_WEBPAGE_PREFIX = "WEBPAGE_JSON "

# The dongle scripts keep their own multiplexed SSH connection to the control
# host (lib/dsk/dongle_env.sh, /tmp/dsk-ctrl-*), shared by every dongle command.
GNB_SSH_CONTROL_PATH = "/tmp/webui-gnb-%r@%h-%p"
# How often the background watcher re-probes the UE while a browser is open.
DONGLE_WATCH_INTERVAL = 2.0
# ...and how often while it is NOT answering. Deliberately much slower: a dongle
# that is away is usually rebooting or being replugged, and traffic landing on
# its RNDIS link during that window makes its IPA/tethering stack reset the USB
# gadget, lengthening the outage. Polling harder to notice it sooner is exactly
# backwards — it delays the thing being waited for.
DONGLE_DOWN_WATCH_INTERVAL = 10.0


def dongle_missing_settings():
    """Which dongle settings still need to be filled in."""
    d = CONFIG["dongle"]
    missing = [k for k in ("host", "user", "script_path") if not str(d.get(k) or "").strip()]
    if not _DONGLE_ENV.get("DONGLE_SSH_PASS"):
        missing.append("DONGLE_SSH_PASS")
    return missing


# ── Which dongle is selected ────────────────────────────────────────────
# Server-side on purpose. The state watcher thread decides what to probe and
# what to push over the websocket, so it has to be able to read the selection;
# a value living only in the browser would also be lost on every reload.
_active_dongle_lock = threading.Lock()
_active_dongle_id = CONFIG["active_dongle"]


def dongle_by_id(dongle_id):
    return next((d for d in CONFIG["dongles"] if d["id"] == dongle_id), None)


def active_dongle_id():
    with _active_dongle_lock:
        return _active_dongle_id


def active_dongle():
    """The selected dongle's entry, falling back to the first configured one."""
    return dongle_by_id(active_dongle_id()) or CONFIG["dongles"][0]


def select_dongle(dongle_id):
    """Point every dongle script at a different dongle.

    Refused while a dongle script is running: DongleSession tracks a single
    process, and switching under it would leave that run executing against the
    old dongle while its output was attributed to the new one."""
    global _active_dongle_id
    if dongle_by_id(dongle_id) is None:
        return False, f"Unknown dongle '{dongle_id}'"
    if dongle_session.is_running():
        return False, "A dongle script is still running — stop it before switching dongles"
    with _active_dongle_lock:
        _active_dongle_id = dongle_id
    # The other dongle's cached state is whatever it was when we last looked at
    # it, which may be old; mark it for re-probing rather than reporting it as
    # current. The watcher picks the new selection up on its next pass.
    probe = dongle_ue_probes.get(dongle_id)
    if probe is not None:
        probe.invalidate()
    return True, None


def dongle_env_prefix(dongle=None):
    """`SSH_HOST=… SSH_PORT=… ` for the script's command line.

    dongle_env.sh resolves both as "${VAR:-default}", so exporting them ahead
    of the script overrides which dongle it talks to."""
    d = dongle or active_dongle()
    return (f"SSH_HOST={shlex.quote(str(d['ssh_host']))} "
            f"SSH_PORT={shlex.quote(str(d.get('ssh_port') or 8822))} ")


def dongle_auth_mode():
    d = CONFIG["dongle"]
    if str(d.get("password") or "").strip():
        return "password"
    if str(d.get("key_path") or "").strip():
        return "key"
    return "agent"


# How a control-plane run cycles the UE (dongle_cp_setup.sh --mode):
#   reboot    reboots the whole dongle (~2 min, two registrations)
#   airplane  switches the modem's radio off and on (a few seconds, one
#             registration) — same capture, parsing and RESULT_JSON
DONGLE_CP_MODES = ("reboot", "airplane")


def dongle_remote_command(dongle=None, mode="reboot"):
    """The command line of a control-plane run (executed on this host).

    Runs from the script's own directory (or an explicit "workdir"), with the
    selected dongle exported ahead of it."""
    d = CONFIG["dongle"]
    script = str(d.get("script_path") or "").strip()
    workdir = str(d.get("workdir") or "").strip() or os.path.dirname(script)
    parts = []
    if workdir and workdir != ".":
        parts.append(f"cd {shlex.quote(workdir)} &&")
    if d.get("use_sudo"):
        parts.append("sudo -n")
    parts.append(dongle_env_prefix(dongle) + f"bash {shlex.quote(script)}")
    args = str(d.get("script_args") or "").strip()
    if args:
        parts.append(args)
    # reboot is the script's default, so it is left off the command line and
    # an older script without --mode keeps working for the reboot button.
    if mode == "airplane":
        parts.append("--mode airplane")
    return " ".join(parts)


def build_dongle_argv(cmd):
    """argv that runs a dongle script's command line on this host.

    `script` gives it a pty, as `ssh -tt` did when the scripts ran on the
    control host: output arrives line by line instead of in 4K blocks, and
    killing `script` hangs the pty up, which fires the script's cleanup trap
    (dongle_cp_setup.sh stops its root-owned tshark there)."""
    return ["script", "-qefc", "bash -c " + shlex.quote(cmd), "/dev/null"]


def dongle_tools_missing():
    """Local tools the dongle scripts need; empty when all are installed."""
    return [t for t in ("sshpass", "script") if shutil.which(t) is None]


class DongleSession:
    """Single dongle_cp_setup.sh run against the dongle, with its output buffered
    for late-joining browsers and mirrored live over the websocket."""

    def __init__(self):
        self.lock = threading.Lock()
        self.proc = None
        self.thread = None
        self.status = "idle"        # idle | starting | running | stopping | stopped | error
        self.started_at = None
        self.stopped_at = None
        self.error = None
        self.exit_code = None
        self.command = None
        self.lines = deque(maxlen=5000)
        # Which dongle this run was launched against, pinned at start so a
        # selection change mid-run cannot re-label the output.
        self.dongle = None
        # How this run cycles the UE (one of DONGLE_CP_MODES).
        self.mode = None
        # Parsed from the script's final "RESULT_JSON {...}" line — the dongle
        # equivalent of what start_packetrusher_internal() returns.
        self.result = None

    def _set_status(self, status, error=None, exit_code=None):
        """Caller must hold self.lock."""
        self.status = status
        self.error = error
        if exit_code is not None:
            self.exit_code = exit_code
        socketio.emit('dongle_status', {
            'status': status, 'error': error, 'exit_code': self.exit_code,
            'started_at': self.started_at, 'command': self.command,
            'dongle': self.dongle,
        })

    def append(self, line):
        with self.lock:
            self.lines.append(line)
        socketio.emit('dongle_output', {'line': line, 'timestamp': datetime.now().isoformat()})

    def capture_result(self, line):
        """Pick the script's machine-readable summary out of the stream.

        dongle_cp_setup.sh ends with `RESULT_JSON {...}` whose "timing" object
        uses the same keys as PacketRusher's, so the dashboard renders both
        the same way."""
        if not line.startswith(DONGLE_RESULT_PREFIX):
            return
        try:
            parsed = json.loads(line[len(DONGLE_RESULT_PREFIX):])
        except json.JSONDecodeError as e:
            print(f"[DONGLE] unparseable RESULT_JSON: {e}", flush=True)
            return
        # Stamp the run's dongle onto the result: with two on the bench, a
        # timing record that does not name its source is not attributable.
        with self.lock:
            parsed["dongle"] = self.dongle
            self.result = parsed
        # A control-plane run just re-registered the UE, so the cached liveness
        # state (and the UE IP, which changes every registration) is stale.
        dongle_ue_probe().invalidate()
        socketio.emit('dongle_result', parsed)

    def is_running(self):
        with self.lock:
            return self.status in ("starting", "running") and self.proc is not None and self.proc.poll() is None

    def snapshot(self, n=500):
        with self.lock:
            return {
                'status': self.status,
                'started_at': self.started_at,
                'stopped_at': self.stopped_at,
                'error': self.error,
                'exit_code': self.exit_code,
                'command': self.command,
                'result': self.result,
                'dongle': self.dongle,
                'mode': self.mode,
                'lines': list(self.lines)[-n:],
            }

    def start(self, mode="reboot"):
        if mode not in DONGLE_CP_MODES:
            return False, f"Invalid mode: {mode} (use one of {', '.join(DONGLE_CP_MODES)})"
        if self.is_running():
            return False, "Dongle script is already running"
        missing = dongle_missing_settings()
        if missing:
            return False, ("Dongle SSH is not configured yet (missing: "
                           + ", ".join(missing)
                           + ") — run lib/features/set-dongle-mode.sh on, or edit webui/dongle.env")
        tools = dongle_tools_missing()
        if tools:
            return False, f"Not installed on the WebUI host: {', '.join(tools)} (sudo apt-get install {' '.join(tools)})"

        # Pin the dongle for the whole run. select_dongle() refuses to switch
        # while this session is live, so this stays true until it finishes.
        dongle = active_dongle()
        remote_cmd = dongle_remote_command(dongle, mode)
        argv = build_dongle_argv(remote_cmd)
        d = CONFIG["dongle"]
        with self.lock:
            self.lines.clear()
            self.result = None
            self.dongle = dongle["id"]
            self.mode = mode
            self.proc = None
            self.started_at = datetime.now().isoformat()
            self.stopped_at = None
            self.exit_code = None
            self.command = remote_cmd
            self._set_status("starting")
        self.append(f"🔌 Reaching the dongle via the control host {d['user']}@{d['host']}:{d.get('port') or 22} ...")
        self.append(f"🎯 Target dongle: {dongle['label']} ({dongle['ssh_host']}:{dongle.get('ssh_port') or 8822})")
        self.append(f"$ {remote_cmd}")

        try:
            proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    stdin=subprocess.DEVNULL, text=True, bufsize=1,
                                    preexec_fn=os.setsid)
        except FileNotFoundError as e:
            with self.lock:
                self._set_status("error", error=str(e))
            return False, str(e)
        with self.lock:
            self.proc = proc
            self._set_status("running")

        def reader():
            try:
                for line in proc.stdout:
                    # `script` gives us a pty, so lines arrive with \r and any
                    # colors the script emits — clean both up for the WebUI.
                    text = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', line).rstrip()
                    self.capture_result(text)
                    self.append(text)
            except Exception as e:
                self.append(f"❌ Stream error: {e}")
            code = proc.wait()
            with self.lock:
                self.stopped_at = datetime.now().isoformat()
                if self.status == "stopping" or code == 0:
                    self._set_status("stopped", exit_code=code)
                else:
                    self._set_status("error", error=f"dongle_cp_setup.sh exited with code {code}", exit_code=code)
            self.append(f"— script finished (exit {code}) —")

        self.thread = threading.Thread(target=reader, daemon=True)
        self.thread.start()
        return True, None

    def stop(self):
        with self.lock:
            proc = self.proc
            if proc is None or proc.poll() is not None:
                proc = None
            else:
                self.status = "stopping"
        if proc is not None:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGINT)
                time.sleep(1.5)
                if proc.poll() is None:
                    os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            except Exception as e:
                print(f"Dongle stop failed: {e}", flush=True)
        # Belt-and-braces: the script should already be gone (the pty hangup
        # fires its cleanup trap, which is what stops the root-owned tshark),
        # but make sure nothing survived. It runs as our own user, so no sudo.
        # Matched by its absolute path, which only the WebUI uses: a batch run
        # on this host starts it as `bash ./dongle_cp_setup.sh` and must not be
        # killed by a Stop here.
        script = str(CONFIG["dongle"].get("script_path") or "").strip()
        if script:
            try:
                subprocess.run(["pkill", "-f", "bash " + re.escape(script)], timeout=20,
                               capture_output=True, stdin=subprocess.DEVNULL)
            except Exception as e:
                print(f"Dongle cleanup failed: {e}", flush=True)
        with self.lock:
            if self.status in ("stopping", "starting", "running"):
                self._set_status("stopped")
        self.append("🛑 Dongle stopped")
        return True


dongle_session = DongleSession()


@app.route('/api/dongle/config', methods=['GET'])
def get_dongle_config():
    """Non-secret view of the dongle SSH settings (never returns the password)."""
    d = CONFIG["dongle"]
    missing = dongle_missing_settings()
    return jsonify({
        "success": True,
        "configured": not missing,
        "missing": missing,
        "host": d.get("host", ""),
        "user": d.get("user", ""),
        "port": d.get("port", 22),
        "script_path": d.get("script_path", ""),
        "script_args": d.get("script_args", ""),
        "use_sudo": bool(d.get("use_sudo")),
        "auth": dongle_auth_mode(),
        "command": dongle_remote_command(),
        "dongle": active_dongle(),
    })


def _dongle_list_payload():
    return {
        "success": True,
        "active": active_dongle()["id"],
        "dongles": [dict(d) for d in CONFIG["dongles"]],
        # The selector has to lock while a run is in flight — see select_dongle().
        "locked": dongle_session.is_running(),
    }


@app.route('/api/dongle/list', methods=['GET'])
def get_dongle_list():
    """Which dongles are configured and which one everything currently uses."""
    return jsonify(_dongle_list_payload())


@app.route('/api/dongle/select', methods=['POST'])
def post_dongle_select():
    """Point the probe, the control-plane script and the ping at one dongle."""
    dongle_id = (request.get_json() or {}).get('id')
    ok, err = select_dongle(dongle_id)
    if not ok:
        return jsonify({"success": False, "error": err, **_dongle_list_payload()}), 400
    # Hand back the newly selected dongle's state right away — cached, so this
    # does not wait on SSH; the watcher refreshes it on its next pass.
    state = dongle_ue_probe().get()
    socketio.emit('dongle_ue', {"success": True, **state})
    return jsonify({**_dongle_list_payload(), "state": state})


@app.route('/api/dongle/status', methods=['GET'])
def get_dongle_status():
    snap = dongle_session.snapshot(int(request.args.get('lines', 500)))
    snap["success"] = True
    snap["configured"] = not dongle_missing_settings()
    snap["dongle"] = active_dongle()["id"]
    return jsonify(snap)


@app.route('/api/dongle/start', methods=['POST'])
def start_dongle():
    # {"mode": "reboot" | "airplane"} — reboot when omitted, as before.
    mode = str((request.get_json(silent=True) or {}).get("mode") or "reboot").strip().lower()
    ok, err = dongle_session.start(mode)
    if not ok:
        return jsonify({"success": False, "error": err}), 400
    return jsonify({"success": True, **dongle_session.snapshot(50)})


@app.route('/api/dongle/stop', methods=['POST'])
def stop_dongle():
    dongle_session.stop()
    return jsonify({"success": True, **dongle_session.snapshot(50)})


class SingleFlightProbe:
    """Cached remote state whose refresh is an SSH round trip.

    Every panel on the dashboard wants this state at once, and the probe costs
    about as long as a poll interval. Two rules keep that from turning into a
    stampede:

      * Single flight — while a probe is running, other callers wait for *its*
        answer instead of opening a second SSH session. Concurrent probes are
        not merely wasteful: they interleave in _commit(), which is where the
        dongle's confirmation streak lives, and a streak counted out of order
        confirms changes that never happened and drops ones that did.
      * Non-blocking reads — get() answers from the cache and leaves the SSH to
        the watcher (or to a background refresh). A request handler that waits
        on the dongle also delays everything the browser batched alongside it,
        which is how a dongle that was merely slow used to freeze
        PacketRusher's badge.

    The TTL must therefore be comfortably LONGER than a probe takes, or the
    entry is stale the moment it is stored and nothing is ever cached at all.
    """

    def __init__(self, ttl_seconds, name="probe"):
        self.ttl = ttl_seconds
        self.name = name
        self.lock = threading.Lock()          # guards value / checked_at / streak
        self.probe_lock = threading.Lock()    # serialises the SSH round trip
        self.value = None
        self.checked_at = 0.0
        self._async_pending = False

    def invalidate(self):
        """Mark the cache stale so the next read refreshes it."""
        with self.lock:
            self.checked_at = 0.0

    def _is_fresh(self):
        """Caller must hold self.lock."""
        return self.value is not None and (time.time() - self.checked_at) < self.ttl

    def get(self, force=False):
        """Current state, without blocking on SSH.

        A stale entry is served as-is (tagged "stale") and refreshed in the
        background. Only two callers ever wait for a probe: a cold cache, which
        has nothing to report yet, and force=True, which is the operator
        pressing refresh and expecting a real answer."""
        if force:
            return self.refresh(force=True)
        with self.lock:
            if self._is_fresh():
                return dict(self.value)
            stale = dict(self.value) if self.value is not None else None
        if stale is None:
            return self.refresh()
        stale["stale"] = True
        self._refresh_async()
        return stale

    def refresh(self, force=False):
        """Probe now — or ride along with the probe already in flight."""
        asked_at = time.time()
        with self.probe_lock:
            with self.lock:
                # Someone else may have probed while we waited for the lock. A
                # forced caller is satisfied only by a probe that finished
                # after they asked; anyone else is satisfied by a fresh entry.
                satisfied = (self.checked_at >= asked_at) if force else self._is_fresh()
                if self.value is not None and satisfied:
                    return dict(self.value)
            probed = self._probe()
            with self.lock:
                return self._commit(probed)

    def _refresh_async(self):
        """Kick off a background refresh, at most one queued at a time."""
        with self.lock:
            if self._async_pending:
                return
            self._async_pending = True

        def run():
            try:
                self.refresh()
            except Exception as e:
                print(f"[{self.name}] background refresh failed: {e}", flush=True)
            finally:
                with self.lock:
                    self._async_pending = False

        threading.Thread(target=run, daemon=True, name=f"{self.name}-refresh").start()

    def _commit(self, probed):
        """Store a completed probe and return what to report.

        Runs under self.lock, and only ever from inside probe_lock — so a
        subclass may keep sequential state here. Caller must hold self.lock."""
        self.value = probed
        self.checked_at = time.time()
        return dict(self.value)

    def _probe(self):
        raise NotImplementedError


class DongleUeProbe(SingleFlightProbe):
    """Cached 'is the dongle UE attached' state, for ONE dongle.

    The dashboard polls this the same way it polls container states, so the
    dongle badge tracks the real UE instead of the script process.

    There is one of these per configured dongle, but only the selected one is
    ever refreshed. Keeping the unselected dongle's last value around costs
    nothing and means switching shows something immediately (tagged stale)
    instead of an empty badge while the first probe runs."""

    def __init__(self, dongle_id, ttl_seconds=6, down_confirmations=2, up_confirmations=2):
        super().__init__(ttl_seconds, name=f"DONGLE:{dongle_id}")
        self.dongle_id = dongle_id
        # Neither answer is trusted from a single probe. A failure can be a
        # momentary radio blip or a slow SSH; a success can be a stale routing
        # cache entry on a dongle that is still booting. Both directions must
        # therefore be seen this many times in a row before the reported state
        # changes — otherwise the badge flickers through a reboot.
        self.down_confirmations = down_confirmations
        self.up_confirmations = up_confirmations
        self._streak = 0

    def invalidate(self):
        # Drop the streak too: a control-plane run just re-registered the UE,
        # so confirmations counted against the pre-run state mean nothing.
        with self.lock:
            self.checked_at = 0.0
            self._streak = 0

    def refresh(self, force=False):
        """Probe — unless a control-plane run is in flight.

        dongle_cp_setup.sh reboots the dongle and then polls it itself, waiting
        for exactly the event this probe watches for. Probing alongside it is
        not merely redundant: every SSH handshake that lands on the RNDIS link
        while the modem is booting provokes its IPA/tethering stack to reset the
        USB gadget, which lengthens the outage being waited on. Measured on this
        bench, one reboot: 4 gadget resets and ~104s to a stable link with no
        contact, 11 resets and ~227s with this probe running at 2.5s, and 40
        resets and ~559s with both this and the script's own loop going.

        So while a run owns the dongle, report the last known state (tagged
        'rebooting') and let the script's output drive the UI instead. Overriding
        refresh() rather than the watcher covers every path that could reach the
        dongle — the watcher, a forced HTTP refresh, and the background
        refresh a stale cache read would otherwise kick off."""
        if dongle_session.is_running():
            dongle = dongle_by_id(self.dongle_id) or {}
            # Report the UE as down, not as whatever the cache last saw. The
            # run's first act is a reboot, so "attached" is false by
            # construction — holding the pre-reboot value would leave the badge
            # reading RUNNING for the entire minutes-long reboot.
            state = {"attached": False, "ue_ip": None, "configured": True,
                     "dongle": self.dongle_id,
                     "dongle_label": dongle.get("label", self.dongle_id),
                     "rebooting": True}
            with self.lock:
                # Written through rather than just returned: this is known, not
                # probed, so it also settles the cache. Otherwise a stale read
                # after the run would briefly resurface the old "attached".
                # The streak is reset for the same reason invalidate() does it —
                # confirmations counted against the pre-reboot state are void.
                self.value = dict(state)
                self.checked_at = time.time()
                self._streak = 0
            return state
        # No gNB, no UE. The dongle keeps its RNDIS address (and so answers
        # dongle_status.sh as "attached") for a while after the radio is gone,
        # so a stopped gNB is taken as the answer instead of probed for: down
        # at once, no confirmation streak, no SSH to the dongle. Only a gNB that
        # is known to be stopped counts — an unreachable gNB host says nothing
        # about the radio, so that case falls through to the normal probe.
        gnb = gnb_state_probe.get()
        if not gnb.get("running") and gnb.get("state") not in ("unreachable", None):
            dongle = dongle_by_id(self.dongle_id) or {}
            state = {"attached": False, "ue_ip": None,
                     "configured": not dongle_missing_settings(),
                     "dongle": self.dongle_id,
                     "dongle_label": dongle.get("label", self.dongle_id),
                     "gnb_down": True}
            with self.lock:
                # Written through for the same reason as the rebooting case.
                self.value = dict(state)
                self.checked_at = time.time()
                self._streak = 0
            return state
        return super().refresh(force=force)

    def _commit(self, probed):
        self.checked_at = time.time()
        if self.value is None:                  # first observation, nothing to compare
            self.value = probed
            self._streak = 0
            return dict(self.value)

        now_attached = bool(probed.get("attached"))
        shown_attached = bool(self.value.get("attached"))
        if now_attached == shown_attached:
            self._streak = 0
            self.value = probed                 # keep ue_ip / iface fresh
        else:
            self._streak += 1
            needed = self.up_confirmations if now_attached else self.down_confirmations
            if self._streak >= needed:
                self._streak = 0
                self.value = probed
            else:
                held = dict(self.value)         # hold until the change is confirmed
                held["confirming"] = "up" if now_attached else "down"
                held.pop("gnb_down", None)      # this probe reached the dongle, so the gNB is not known down
                return held
        return dict(self.value)

    def _probe(self):
        dongle = dongle_by_id(self.dongle_id)
        # Every payload names its dongle, so nothing downstream — badge, ping
        # chip, stored result — has to infer which one it is describing.
        base = {"attached": False, "ue_ip": None, "dongle": self.dongle_id,
                "dongle_label": (dongle or {}).get("label", self.dongle_id)}
        if dongle is None:
            return {**base, "configured": False, "error": f"Unknown dongle '{self.dongle_id}'"}
        if dongle_missing_settings():
            return {**base, "configured": False}
        d = CONFIG["dongle"]
        script = str(d.get("status_script_path") or "").strip()
        workdir = str(d.get("workdir") or "").strip() or os.path.dirname(script)
        cmd = f"cd {shlex.quote(workdir)} && {dongle_env_prefix(dongle)}bash {shlex.quote(script)}"
        try:
            proc = subprocess.run(build_dongle_argv(cmd), capture_output=True, text=True,
                                  timeout=30, stdin=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            return {**base, "configured": True, "error": "probe timed out"}
        except Exception as e:
            return {**base, "configured": True, "error": str(e)}
        for line in (proc.stdout or "").splitlines():
            clean = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', line).rstrip()
            if clean.startswith(DONGLE_RESULT_PREFIX):
                try:
                    parsed = json.loads(clean[len(DONGLE_RESULT_PREFIX):])
                except json.JSONDecodeError:
                    continue
                return {**base,
                        "attached": bool(parsed.get("attached")),
                        "ue_ip": parsed.get("ue_ip"),
                        "configured": True,
                        "error": parsed.get("error")}
        return {**base, "configured": True,
                "error": "dongle_status.sh returned no result"}


# One probe per configured dongle; only the selected one is refreshed.
# The probe itself measures ~2s against a reachable dongle host, so the TTL has
# to sit well above that — at 2s the entry expired as fast as it was written and
# every caller ended up doing its own SSH.
dongle_ue_probes = {d["id"]: DongleUeProbe(d["id"], ttl_seconds=6) for d in CONFIG["dongles"]}


def dongle_ue_probe():
    """The probe for the dongle currently selected."""
    return dongle_ue_probes[active_dongle()["id"]]

# Number of connected browsers — the watcher below only probes while someone
# is actually looking, so an idle WebUI does not SSH to the dongle forever.
_dongle_watchers = 0
_dongle_watchers_lock = threading.Lock()


def _testbed_state_watcher():
    """Re-probe the dongle UE and the gNB, pushing changes over the websocket.

    Polling from the browser meant a state change could sit unnoticed for a
    whole dashboard cycle. Probing here instead makes detection independent of
    how often (or how many) browsers ask, and the UI updates on the event."""
    last = None
    last_gnb = None
    while True:
        try:
            with _dongle_watchers_lock:
                watching = _dongle_watchers > 0
            if not watching:
                last = last_gnb = None   # re-announce state to the next viewer
                time.sleep(5)
                continue

            # This thread is the one caller that is *meant* to wait on SSH —
            # refresh() rather than get(), so the cache the request handlers
            # read is always one it filled.
            gnb = gnb_state_probe.refresh(force=True)
            gnb_key = (gnb.get("running"), gnb.get("state"))
            if gnb_key != last_gnb:
                last_gnb = gnb_key
                socketio.emit('gnb_state', {"success": True, **gnb})

            if dongle_missing_settings():
                last = None
                time.sleep(5)
                continue
            # Only the selected dongle is probed — the other one is not touched
            # at all. Its id is part of the change key, so switching re-announces
            # immediately instead of waiting for the new dongle's state to
            # happen to differ from the old one's.
            #
            # refresh() returns the held state without touching the dongle while
            # a control-plane run owns it (see DongleUeProbe.refresh), so this
            # loop idles quietly through a reboot instead of fighting the script
            # that is already polling for the same event.
            state = dongle_ue_probe().refresh(force=True)
            if state.get("rebooting"):
                last = None          # re-announce once the run releases the dongle
                time.sleep(DONGLE_WATCH_INTERVAL)
                continue
            key = (state.get("dongle"), state.get("attached"), state.get("ue_ip"))
            if key != last:
                last = key
                socketio.emit('dongle_ue', {"success": True, **state})
            # Back OFF when the dongle is not answering rather than speeding
            # up. dongle_status.sh gates on ICMP, so a probe against an absent
            # dongle costs one ping rather than an SSH handshake, and at this
            # cadence that is ~6 pings a minute instead of ~24 handshakes. The
            # cost is up to DONGLE_DOWN_WATCH_INTERVAL of extra latency in
            # noticing it return, which is nothing against a reboot measured in
            # minutes — and the reboot itself finishes sooner for it.
            time.sleep(DONGLE_WATCH_INTERVAL if state.get("attached")
                       else DONGLE_DOWN_WATCH_INTERVAL)
        except Exception as e:
            print(f"[DONGLE] UE watcher error: {e}", flush=True)
            time.sleep(5)


if DONGLE_ENABLED:
    threading.Thread(target=_testbed_state_watcher, daemon=True, name="testbed-state-watcher").start()


# ============================================================================
# gNB — the radio the dongle attaches to, controlled over SSH on its own host
# ============================================================================

def build_gnb_ssh_argv(remote_cmd, tty=False):
    g = CONFIG["gnb"]
    argv = ["ssh"]
    if tty:
        argv.append("-tt")
    argv += ["-o", f"ConnectTimeout={int(g.get('connect_timeout') or 8)}",
             "-o", "StrictHostKeyChecking=no",
             "-o", "BatchMode=yes",
             "-o", "LogLevel=ERROR",
             # Same reasoning as the dongle: the state is polled every couple
             # of seconds, so reuse one handshake.
             "-o", "ControlMaster=auto",
             "-o", f"ControlPath={GNB_SSH_CONTROL_PATH}",
             "-o", "ControlPersist=120"]
    key = str(g.get("key_path") or "").strip()
    if key:
        argv += ["-i", os.path.expanduser(key)]
    argv += ["-p", str(g.get("port") or 22),
             f"{g['user']}@{g['host']}", remote_cmd]
    return argv


def gnb_compose_cmd(action):
    """gnbup / gnbdown / gnblogs, spelled out (they are interactive aliases)."""
    compose = CONFIG["gnb"]["compose_file"]
    return f"docker compose -f {shlex.quote(compose)} {action}"


def run_gnb_command(remote_cmd, timeout=120):
    try:
        proc = subprocess.run(build_gnb_ssh_argv(remote_cmd), capture_output=True,
                              text=True, timeout=timeout, stdin=subprocess.DEVNULL)
        return {"success": proc.returncode == 0, "stdout": proc.stdout,
                "stderr": proc.stderr, "returncode": proc.returncode}
    except subprocess.TimeoutExpired:
        return {"success": False, "stdout": "", "stderr": "Command timed out", "returncode": -1}
    except Exception as e:
        return {"success": False, "stdout": "", "stderr": str(e), "returncode": -1}


class GnbStateProbe(SingleFlightProbe):
    """Cached 'is the gNB container up' state, polled like the dongle's.

    Same SSH-shaped cost, so it gets the same single-flight, non-blocking
    treatment — it rides in the browser's dashboard batch too."""

    def __init__(self, ttl_seconds=6):
        super().__init__(ttl_seconds, name="GNB")

    def _probe(self):
        container = CONFIG["gnb"]["container"]
        # No sudo: docker is usable directly by this user on that host.
        cmd = f"docker ps -a --filter name={shlex.quote(container)} --format '{{{{.State}}}}|{{{{.Status}}}}'"
        result = run_gnb_command(cmd, timeout=20)
        if not result["success"]:
            return {"running": False, "state": "unreachable", "status_text": "",
                    "container": container,
                    "error": (result.get("stderr") or "").strip() or "gNB host unreachable"}
        line = (result["stdout"] or "").strip().split("\n")[0]
        if not line:
            return {"running": False, "state": "not_found", "status_text": "",
                    "container": container, "error": None}
        state, _, status_text = line.partition("|")
        return {"running": state.strip() == "running", "state": state.strip(),
                "status_text": status_text.strip(), "container": container, "error": None}


gnb_state_probe = GnbStateProbe()


@app.route('/api/gnb/status', methods=['GET'])
def get_gnb_status():
    state = gnb_state_probe.get(force=request.args.get('force') == '1')
    return jsonify({"success": True, **state})


@app.route('/api/gnb/start', methods=['POST'])
def start_gnb():
    """gnbup"""
    result = run_gnb_command(gnb_compose_cmd("up -d"), timeout=180)
    gnb_state_probe.invalidate()
    output = ((result.get("stdout") or "") + (result.get("stderr") or "")).strip()
    if not result["success"]:
        return jsonify({"success": False, "error": output or "gnbup failed", "output": output}), 500
    return jsonify({"success": True, "output": output, **gnb_state_probe.get(force=True)})


@app.route('/api/gnb/stop', methods=['POST'])
def stop_gnb():
    """gnbdown"""
    result = run_gnb_command(gnb_compose_cmd("down"), timeout=180)
    gnb_state_probe.invalidate()
    output = ((result.get("stdout") or "") + (result.get("stderr") or "")).strip()
    if not result["success"]:
        return jsonify({"success": False, "error": output or "gnbdown failed", "output": output}), 500
    gnb = gnb_state_probe.get(force=True)
    # The dongle goes down with the gNB: announce it now rather than on the
    # watcher's next (slow, dongle-down) pass. No SSH — see DongleUeProbe.refresh.
    socketio.emit('dongle_ue', {"success": True, **dongle_ue_probe().refresh(force=True)})
    return jsonify({"success": True, "output": output, **gnb})


@app.route('/api/gnb/logs/stream')
def stream_gnb_logs():
    """gnblogs — `docker compose logs -f`, streamed as SSE and killed when the
    browser closes the viewer."""
    tail = str(request.args.get('tail', '100'))
    if not re.match(r'^\d+$', tail):
        tail = '100'
    remote_cmd = gnb_compose_cmd(f"logs -f --no-color --tail {tail}")
    argv = build_gnb_ssh_argv(remote_cmd)

    def generate():
        proc = None
        try:
            proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    stdin=subprocess.DEVNULL, text=True, bufsize=1,
                                    preexec_fn=os.setsid)
            yield f"data: {json.dumps({'type': 'start', 'command': remote_cmd})}\n\n"
            last_beat = time.time()
            while True:
                ready, _, _ = select.select([proc.stdout], [], [], 1.0)
                if ready:
                    line = proc.stdout.readline()
                    if not line:
                        break
                    clean = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', line.rstrip())
                    yield f"data: {json.dumps({'type': 'line', 'line': clean})}\n\n"
                else:
                    if proc.poll() is not None:
                        break
                    if time.time() - last_beat > 10:
                        last_beat = time.time()
                        yield f"data: {json.dumps({'type': 'heartbeat'})}\n\n"
            yield f"data: {json.dumps({'type': 'end', 'exit_code': proc.poll()})}\n\n"
        except GeneratorExit:
            raise
        except Exception as e:
            yield f"data: {json.dumps({'type': 'error', 'message': str(e)})}\n\n"
        finally:
            if proc and proc.poll() is None:
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                except Exception:
                    pass
    return Response(generate(), mimetype='text/event-stream',
                    headers={'Cache-Control': 'no-cache', 'Connection': 'keep-alive', 'X-Accel-Buffering': 'no'})


@app.route('/api/dongle/ue', methods=['GET'])
def get_dongle_ue():
    """Live UE state for the dashboard badge — cached, safe to poll."""
    state = dongle_ue_probe().get(force=request.args.get('force') == '1')
    return jsonify({"success": True, **state})


@app.route('/api/dongle/reachable', methods=['GET'])
def dongle_reachable():
    """Is the dongle up right now? Used by the ping panel to decide whether it
    may fall back to the dongle when PacketRusher is down."""
    state = dongle_ue_probe().get()
    return jsonify({"success": True, "reachable": state["attached"],
                    "configured": state.get("configured", True),
                    "ue_ip": state.get("ue_ip")})


@app.route('/api/dongle/ping/stream')
def stream_dongle_ping():
    """Run dongle_ping.sh against the dongle and stream the replies as SSE.

    Emits exactly the same event shapes as /api/ping/stream (the PacketRusher
    path), so the ping panel only has to swap the URL depending on which UE is
    currently up."""
    target = (request.args.get('target') or '').strip()
    if not re.match(r'^[\w.:-]+$', target):
        def bad():
            yield f"data: {json.dumps({'error': 'Invalid target'})}\n\n"
        return Response(bad(), mimetype='text/event-stream')
    count = max(1, min(int(request.args.get('count', 10)), 50))
    interval = request.args.get('interval', '1')
    if not re.match(r'^\d+(\.\d+)?$', str(interval)):
        interval = '1'

    missing = dongle_missing_settings()
    if missing:
        def unconfigured():
            yield f"data: {json.dumps({'error': 'Dongle SSH is not configured'})}\n\n"
        return Response(unconfigured(), mimetype='text/event-stream')

    d = CONFIG["dongle"]
    dongle = active_dongle()
    script = str(d.get("ping_script_path") or "").strip()
    workdir = str(d.get("workdir") or "").strip() or os.path.dirname(script)
    remote_cmd = (f"cd {shlex.quote(workdir)} && {dongle_env_prefix(dongle)}bash {shlex.quote(script)} "
                  f"-t {shlex.quote(target)} -c {count} -i {interval}")
    argv = build_dongle_argv(remote_cmd)

    def generate():
        proc = None
        successful, failed, times = 0, 0, []
        try:
            # Name the dongle in the stream: with two on the bench, a result
            # that does not say which one produced it is not attributable.
            yield "data: " + json.dumps({
                'type': 'start', 'dongle': dongle["id"], 'dongle_label': dongle["label"],
                'message': f'Pinging {target} from {dongle["label"]} ({dongle["ssh_host"]})...',
            }) + "\n\n"
            proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    stdin=subprocess.DEVNULL, text=True, bufsize=1,
                                    preexec_fn=os.setsid)
            for raw in proc.stdout:
                line = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', raw).rstrip()
                if line.startswith(DONGLE_PING_PREFIX):
                    try:
                        p = json.loads(line[len(DONGLE_PING_PREFIX):])
                    except json.JSONDecodeError:
                        continue
                    successful += 1
                    times.append(p.get("time_ms", 0))
                    yield "data: " + json.dumps({
                        'type': 'ping', 'seq': successful, 'total': count,
                        'status': 'success', 'time_ms': p.get("time_ms", 0),
                        'ttl': p.get("ttl", 0),
                        'stats': {'successful': successful, 'failed': failed,
                                  'avg_ms': round(sum(times) / len(times), 2) if times else 0},
                    }) + "\n\n"
                elif line.startswith(DONGLE_RESULT_PREFIX):
                    try:
                        res = json.loads(line[len(DONGLE_RESULT_PREFIX):])
                    except json.JSONDecodeError:
                        continue
                    if not res.get("ok"):
                        yield f"data: {json.dumps({'error': res.get('error', 'Dongle ping failed')})}\n\n"
                        return
                    st = res.get("statistics", {})
                    yield "data: " + json.dumps({'type': 'complete', 'statistics': {
                        'total': st.get('total', count),
                        'successful': st.get('successful', successful),
                        'failed': st.get('failed', 0),
                        'packet_loss': st.get('packet_loss', 0),
                        'min_ms': st.get('min_ms', 0),
                        'max_ms': st.get('max_ms', 0),
                        'avg_ms': st.get('avg_ms', 0),
                    }}) + "\n\n"
                    return
                elif line:
                    yield f"data: {json.dumps({'type': 'info', 'message': line})}\n\n"
            # Fell off the end without a RESULT_JSON line — the script died.
            yield f"data: {json.dumps({'error': 'Dongle ping ended without a result'})}\n\n"
        except GeneratorExit:
            raise
        except Exception as e:
            yield f"data: {json.dumps({'error': str(e)})}\n\n"
        finally:
            if proc and proc.poll() is None:
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                except Exception:
                    pass
    return Response(generate(), mimetype='text/event-stream',
                    headers={'Cache-Control': 'no-cache', 'Connection': 'keep-alive', 'X-Accel-Buffering': 'no'})


def _dongle_script_stream(script_key, args, start_message, on_line, missing_msg=None):
    """Run one of the dongle measurement scripts and stream it back as SSE.

    The three dongle measurements (ping, iperf, download) differ only in which
    script runs and which prefixed line carries the answer, so the SSH plumbing
    — selected dongle, pty-stripping, killing the remote script when the
    browser goes away — lives here once.

    `on_line` is called with each cleaned stdout line and yields SSE chunks.
    """
    missing = dongle_missing_settings()
    if missing:
        def unconfigured():
            yield f"data: {json.dumps({'error': 'Dongle SSH is not configured'})}\n\n"
        return Response(unconfigured(), mimetype='text/event-stream')

    d = CONFIG["dongle"]
    dongle = active_dongle()
    script = str(d.get(script_key) or "").strip()
    if not script:
        err = missing_msg or f"CONFIG['dongle']['{script_key}'] is not set"
        def unset():
            yield f"data: {json.dumps({'error': err})}\n\n"
        return Response(unset(), mimetype='text/event-stream')
    workdir = str(d.get("workdir") or "").strip() or os.path.dirname(script)
    remote_cmd = f"cd {shlex.quote(workdir)} && {dongle_env_prefix(dongle)}bash {shlex.quote(script)} {args}".strip()
    argv = build_dongle_argv(remote_cmd)

    def generate():
        proc = None
        try:
            yield "data: " + json.dumps({
                'type': 'start', 'dongle': dongle["id"], 'dongle_label': dongle["label"],
                'message': f'{start_message} from {dongle["label"]} ({dongle["ssh_host"]})...',
            }) + "\n\n"
            proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    stdin=subprocess.DEVNULL, text=True, bufsize=1,
                                    preexec_fn=os.setsid)
            # select rather than a plain `for line in proc.stdout`: these
            # measurements go silent for their whole duration (iperf3 prints
            # nothing until the run ends, browsertime nothing while a page
            # loads), and a stream with no traffic for a minute gets dropped by
            # intermediaries. The heartbeat keeps it open and tells the UI the
            # run is still alive.
            last_beat = time.time()
            while True:
                ready, _, _ = select.select([proc.stdout], [], [], 1.0)
                if ready:
                    raw = proc.stdout.readline()
                    if not raw:
                        break
                    line = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', raw).rstrip()
                    for chunk in on_line(line):
                        yield chunk
                else:
                    if proc.poll() is not None:
                        break
                    if time.time() - last_beat > 5:
                        last_beat = time.time()
                        yield f"data: {json.dumps({'type': 'heartbeat'})}\n\n"
            proc.wait()
        except GeneratorExit:
            raise
        except Exception as e:
            yield f"data: {json.dumps({'type': 'error', 'message': str(e)})}\n\n"
        finally:
            # The browser closing the EventSource lands here; hang the pty up so
            # the measurement stops on the dongle too instead of running on.
            if proc and proc.poll() is None:
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                except Exception:
                    pass
    return Response(generate(), mimetype='text/event-stream',
                    headers={'Cache-Control': 'no-cache', 'Connection': 'keep-alive', 'X-Accel-Buffering': 'no'})


@app.route('/api/dongle/iperf/stream')
def stream_dongle_iperf():
    """iperf3 from the dongle, emitting the same events as /api/iperf/stream.

    dongle_iperf.sh prints the whole `iperf3 -J` document on one IPERF_JSON
    line, which goes through the same formatter the PacketRusher path uses —
    so the panel only has to swap the URL depending on which UE is up."""
    server_ip = (request.args.get('server_ip') or PERF_SERVER_IP).strip()
    server_port = str(request.args.get('server_port', '5201'))
    duration = max(1, min(int(request.args.get('duration', 10)), 120))
    parallel = str(request.args.get('parallel', '1'))
    reverse = request.args.get('reverse', 'false') == 'true'
    udp = request.args.get('udp', 'false') == 'true'
    bandwidth = iperf_bandwidth_arg()
    if not re.match(r'^[\w.:-]+$', server_ip) or not re.match(r'^\d+$', server_port) \
            or not re.match(r'^\d+$', parallel):
        def bad():
            yield f"data: {json.dumps({'error': 'Invalid iperf parameters'})}\n\n"
        return Response(bad(), mimetype='text/event-stream')

    args = (f"-s {shlex.quote(server_ip)} -p {server_port} -t {duration} -P {parallel}"
            + (" -R" if reverse else "") + (" -u" if udp else "")
            + (f" -b {bandwidth}" if bandwidth else ""))
    mode = ("UDP" if udp else "TCP") + (" (reverse/download)" if reverse else "")

    def on_line(line):
        if line.startswith(DONGLE_IPERF_PREFIX):
            try:
                doc = json.loads(line[len(DONGLE_IPERF_PREFIX):])
            except json.JSONDecodeError:
                yield f"data: {json.dumps({'type': 'error', 'message': 'Invalid JSON output from iperf3'})}\n\n"
                return
            for chunk in iperf_sse_events(doc, udp=udp, reverse=reverse):
                yield chunk
        elif line.startswith(DONGLE_RESULT_PREFIX):
            try:
                res = json.loads(line[len(DONGLE_RESULT_PREFIX):])
            except json.JSONDecodeError:
                return
            if not res.get("ok"):
                yield f"data: {json.dumps({'type': 'error', 'message': res.get('error') or 'iperf3 failed on the dongle'})}\n\n"
        elif line:
            yield f"data: {json.dumps({'type': 'info', 'message': line})}\n\n"

    return _dongle_script_stream(
        "iperf_script_path", args,
        f'Starting iperf3 {mode} to {server_ip}:{server_port} for {duration}s',
        on_line, missing_msg="dongle_iperf.sh is not configured")


@app.route('/api/dongle/download/stream')
def stream_dongle_download():
    """HTTP(S) download from the dongle, same events as /api/download/stream.

    The dongle's curl reports the identical --write-out field set, so the
    timing breakdown (DNS / connect / TLS / TTFB) is real here too rather
    than approximated."""
    url = (request.args.get('url') or '').strip()
    if not re.match(r'^https?://[\w\-.~:/?#\[\]@!$&\'()*+,;=%]+$', url):
        def bad():
            yield f"data: {json.dumps({'error': 'Invalid or missing URL'})}\n\n"
        return Response(bad(), mimetype='text/event-stream')

    def on_line(line):
        if line.startswith(DONGLE_DOWNLOAD_PREFIX):
            try:
                res = json.loads(line[len(DONGLE_DOWNLOAD_PREFIX):])
            except json.JSONDecodeError:
                yield f"data: {json.dumps({'type': 'error', 'message': 'Invalid curl output'})}\n\n"
                return
            yield f"data: {json.dumps(download_sse_complete(res))}\n\n"
        elif line.startswith(DONGLE_RESULT_PREFIX):
            try:
                r = json.loads(line[len(DONGLE_RESULT_PREFIX):])
            except json.JSONDecodeError:
                return
            if not r.get("ok"):
                yield f"data: {json.dumps({'type': 'error', 'message': r.get('error') or 'Download failed on the dongle'})}\n\n"
        elif line:
            yield f"data: {json.dumps({'type': 'info', 'message': line})}\n\n"

    return _dongle_script_stream(
        "download_script_path", f"-u {shlex.quote(url)}",
        f'Downloading {url}', on_line,
        missing_msg="dongle_download.sh is not configured")


@app.route('/api/dongle/webpage/stream')
def stream_dongle_webpage():
    """Browsertime through the dongle, same events as /api/webpage/stream.

    The browser runs on the control host, not on the dongle — a modem with
    227MB of RAM and a read-only rootfs cannot host one — with its traffic
    pinned through the dongle by a macvlan network whose only gateway is the
    radio. dongle_webpage.sh explains the reasoning; the metrics are extracted
    with the same field paths the PacketRusher path uses, so the two are
    directly comparable."""
    url = (request.args.get('url') or '').strip()
    browser = (request.args.get('browser') or 'firefox').strip().lower()
    if not re.match(r'^https?://[\w\-.~:/?#\[\]@!$&\'()*+,;=%]+$', url):
        def bad():
            yield f"data: {json.dumps({'error': 'Invalid or missing URL'})}\n\n"
        return Response(bad(), mimetype='text/event-stream')
    # The dongle path runs the browser directly rather than in PacketRusher's
    # netns, so Edge is not offered here — the image ships it, but there is no
    # reason to expose a third engine on one path and not the other.
    if browser not in ('firefox', 'chrome'):
        err = f'Invalid browser: {browser}'
        def badbrowser():
            yield f"data: {json.dumps({'error': err})}\n\n"
        return Response(badbrowser(), mimetype='text/event-stream')

    def on_line(line):
        if line.startswith(DONGLE_WEBPAGE_PREFIX):
            try:
                m = json.loads(line[len(DONGLE_WEBPAGE_PREFIX):])
            except json.JSONDecodeError:
                yield f"data: {json.dumps({'type': 'error', 'message': 'Invalid timings from browsertime'})}\n\n"
                return
            yield f"data: {json.dumps({'type': 'complete', 'url': url, **m})}\n\n"
        elif line.startswith(DONGLE_RESULT_PREFIX):
            try:
                r = json.loads(line[len(DONGLE_RESULT_PREFIX):])
            except json.JSONDecodeError:
                return
            if not r.get("ok"):
                yield f"data: {json.dumps({'type': 'error', 'message': r.get('error') or 'Browsertime failed'})}\n\n"
        elif line:
            # browsertime's own progress, shown in the panel's log view
            yield f"data: {json.dumps({'type': 'log', 'message': line[:400]})}\n\n"

    return _dongle_script_stream(
        "webpage_script_path",
        f"-u {shlex.quote(url)} -b {shlex.quote(browser)}",
        f'Loading {url} in {browser}', on_line,
        missing_msg="dongle_webpage.sh is not configured")


@app.route('/api/dongle/logs', methods=['GET'])
def get_dongle_logs():
    snap = dongle_session.snapshot(int(request.args.get('lines', 500)))
    return jsonify({"success": True, "logs": "\n".join(snap["lines"]), "status": snap["status"]})


# ============================================================================
# RESULTS
# ============================================================================

def _results_source():
    """(results_dir, plots_dir) for ?source=packetrusher (default) or ?source=dsk
    (dongle runs, results_dsk/). None if dsk is asked for but disabled."""
    if request.args.get('source', '').lower() == 'dsk':
        if not DONGLE_ENABLED:
            return None
        return CONFIG["results_dsk_dir"], CONFIG["plots_dsk_dir"]
    return CONFIG["results_dir"], CONFIG["plots_dir"]


def _dsk_disabled_response():
    return jsonify({"success": False, "error": DSK_DISABLED_MSG}), 404


@app.route('/api/results', methods=['GET'])
def list_results():
    src = _results_source()
    if src is None:
        return _dsk_disabled_response()
    results_dir = src[0]
    files = []
    if os.path.exists(results_dir):
        for f in sorted(os.listdir(results_dir), reverse=True):
            if f.endswith('.json'):
                path = os.path.join(results_dir, f)
                stat = os.stat(path)
                summary = ""
                try:
                    with open(path) as fh:
                        data = json.load(fh)
                        info = data.get("test_info", {})
                        summ = data.get("summary", {})
                        summary = f"{info.get('roaming_mode', '?')} | {summ.get('successful_iterations', '?')}/{summ.get('total_iterations', '?')} OK"
                except Exception:
                    pass
                files.append({"filename": f, "size": stat.st_size, "modified": datetime.fromtimestamp(stat.st_mtime).isoformat(), "summary": summary})
    return jsonify({"success": True, "files": files})


@app.route('/api/results/<filename>', methods=['GET'])
def get_result(filename):
    src = _results_source()
    if src is None:
        return _dsk_disabled_response()
    path = os.path.join(src[0], filename)
    if not os.path.exists(path):
        return jsonify({"error": "Not found"}), 404
    with open(path) as f:
        return jsonify({"success": True, "data": json.load(f)})


@app.route('/api/results/<filename>', methods=['DELETE'])
def delete_result(filename):
    src = _results_source()
    if src is None:
        return _dsk_disabled_response()
    path = os.path.join(src[0], filename)
    if not os.path.exists(path):
        return jsonify({"error": "Not found"}), 404
    os.remove(path)
    return jsonify({"success": True, "message": f"Result '{filename}' deleted"})


# ============================================================================
# PLOTS — bar-chart comparison of all results (Plots tab)
# ============================================================================

@app.route('/api/plots/metrics', methods=['GET'])
def list_plot_metrics():
    if not PLOTTING_AVAILABLE:
        return jsonify({"success": False, "error": f"Plotting unavailable: {_PLOT_IMPORT_ERROR}"}), 503
    return jsonify({"success": True, "metrics": plotting.AVAILABLE_METRICS})


@app.route('/api/plots/generate', methods=['GET'])
def generate_plot_route():
    if not PLOTTING_AVAILABLE:
        return jsonify({"success": False, "error": f"Plotting unavailable: {_PLOT_IMPORT_ERROR}"}), 503
    src = _results_source()
    if src is None:
        return _dsk_disabled_response()
    metric = request.args.get('metric', '').strip()
    try:
        png, _medians = plotting.generate_plot(metric, src[0])
    except ValueError as e:
        return jsonify({"success": False, "error": str(e)}), 400
    except Exception as e:
        return jsonify({"success": False, "error": f"Plot generation failed: {e}"}), 500
    resp = Response(png, mimetype='image/png')
    resp.headers['Cache-Control'] = 'no-store'
    return resp


def _plots_payload(result):
    """Build the JSON payload (base64 data-URLs + metadata) from a plots dict as
    returned by plotting.generate_all_plots_to_dir / load_cached_plots."""
    plots = {
        mid: "data:image/png;base64," + base64.b64encode(png).decode('ascii')
        for mid, png in result["plots"].items()
    }
    return jsonify({
        "success": True,
        "plots": plots,
        "errors": result.get("errors", {}),
        "files": result.get("files", []),
        "file_count": result.get("file_count", len(result.get("files", []))),
        "generated_at": result.get("generated_at"),
    })


@app.route('/api/plots/cached', methods=['GET'])
def cached_plots_route():
    """Return the previously generated plots from the plots cache dir WITHOUT
    re-rendering. Fast path used on page load. Empty payload (generated_at null)
    if plots have never been generated."""
    if not PLOTTING_AVAILABLE:
        return jsonify({"success": False, "error": f"Plotting unavailable: {_PLOT_IMPORT_ERROR}"}), 503
    src = _results_source()
    if src is None:
        return _dsk_disabled_response()
    cached = plotting.load_cached_plots(src[1])
    if cached is None:
        return jsonify({"success": True, "plots": {}, "errors": {}, "files": [],
                        "file_count": 0, "generated_at": None})
    return _plots_payload(cached)


@app.route('/api/plots/generate-all', methods=['POST', 'GET'])
def generate_all_plots_route():
    """Render every metric in a single pass over the batch_runner results,
    persist the PNGs to the plots cache dir (overwriting the previous set), and
    return them as base64 data-URLs. This is the explicit 'Regenerate plots'
    action; on page load the frontend uses /plots/cached instead."""
    if not PLOTTING_AVAILABLE:
        return jsonify({"success": False, "error": f"Plotting unavailable: {_PLOT_IMPORT_ERROR}"}), 503
    src = _results_source()
    if src is None:
        return _dsk_disabled_response()
    try:
        result = plotting.generate_all_plots_to_dir(src[0], src[1])
    except ValueError as e:
        return jsonify({"success": False, "error": str(e)}), 400
    except Exception as e:
        return jsonify({"success": False, "error": f"Plot generation failed: {e}"}), 500
    return _plots_payload(result)


# ============================================================================
# PACKETRUSHER + PING/IPERF/DOWNLOAD STREAMING
# ============================================================================

def _parse_docker_ts(ts):
    try:
        ts = ts.strip().rstrip('Z')
        if '.' in ts:
            dt_part, frac = ts.split('.', 1)
            frac = (frac + '000000000')[:9]
            ms = int(frac[:3])
        else:
            dt_part = ts
            ms = 0
        import calendar
        dt = datetime.strptime(dt_part, "%Y-%m-%dT%H:%M:%S")
        return calendar.timegm(dt.timetuple()) * 1000 + ms
    except Exception as e:
        print(f"[TIMING] ts parse error: {e} for '{ts}'", flush=True)
        return 0


def start_packetrusher_internal(config_file):
    pr = CONFIG["packetrusher"]
    config_path = os.path.expanduser(pr["config_path"])
    # If a PacketRusher is already running, its PDU session must be torn down on
    # the core BEFORE a new one attaches. Killing the container drops the gNB
    # (SCTP), which makes the AMF release the UE + PDU session — but that release
    # is asynchronous, and in HR roaming it also has to propagate to the home
    # side over N32. Re-attaching too soon overlaps the old and new sessions: the
    # stale session's downlink reaches the new gNB with an unknown TEID, the gNB
    # sends an "Error Indication", the SMF releases the fresh session, and
    # PacketRusher dies on the release ("NAS message is nil"). So when we are
    # replacing a running instance, wait for the core to settle first.
    was_running = bool(run_local_command(
        f"sudo docker ps -q -f name=^{pr['container']}$").get("stdout", "").strip())
    run_local_command(f"sudo docker rm -f {pr['container']} 2>/dev/null || true")
    cleanup_packetrusher_interfaces()
    if was_running:
        time.sleep(4)  # let the AMF/SMF/UPF (and the HR home side over N32) release the prior session
    t0 = time.time()
    result = run_local_command(f"sudo docker run --privileged --cap-add=ALL --net {pr['network']} --ip {pr['ip']} --name {pr['container']} -v {config_path}/{config_file}:/PacketRusher/config/config.yml -d {pr['image']} --config /PacketRusher/config/config.yml ue")
    if not result["success"]:
        return None, None, None, result.get("stderr", "Failed to start")
    max_wait, poll_interval, waited = 60, 0.3, 0
    while waited < max_wait:
        logs = run_local_command(f"sudo docker logs {pr['container']} 2>&1").get("stdout", "")

        if "PDU address received" in logs and "using VRF vrf" in logs:
            ue_ip_match = re.search(r'PDU address received: (\d+\.\d+\.\d+\.\d+)', logs)
            vrf_match = re.search(r'using VRF (vrf\d{10})', logs)
            ue_ip = ue_ip_match.group(1) if ue_ip_match else None
            vrf = vrf_match.group(1) if vrf_match else None
            if not ue_ip or not vrf:
                return None, None, None, "Could not parse UE IP/VRF"
            total_wall_ms = int((time.time() - t0) * 1000)
            ts_out = run_local_command(f"sudo docker logs -t {pr['container']} 2>&1").get("stdout", "")
            ts_out = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', ts_out)
            t_reg = t_pdu = t_done = 0
            for line in ts_out.splitlines():
                sp = line.find(' ')
                if sp < 15:
                    continue
                ts_str = line[:sp]
                rest = line[sp:]
                if not t_reg and "[UE] Initiating Registration" in rest:
                    t_reg = _parse_docker_ts(ts_str)
                elif not t_pdu and "[UE] Initiating New PDU Session" in rest:
                    t_pdu = _parse_docker_ts(ts_str)
                elif not t_done and "PDU address received" in rest:
                    t_done = _parse_docker_ts(ts_str)
            print(f"[TIMING] t_reg={t_reg} t_pdu={t_pdu} t_done={t_done}", flush=True)
            reg_ms = max(0, t_pdu - t_reg) if (t_reg and t_pdu) else 0
            pdu_ms = max(0, t_done - t_pdu) if (t_pdu and t_done) else 0
            total_precise = max(0, t_done - t_reg) if (t_reg and t_done) else total_wall_ms
            timing = {"total": total_precise, "registration_ms": reg_ms, "pdu_setup_ms": pdu_ms}
            print(f"[TIMING] result={timing}", flush=True)
            return ue_ip, vrf, timing, None

        # Detect fatal/error log lines immediately — no need to wait for timeout
        fatal_match = re.search(r'level=fatal\s+msg="([^"]+)"', logs)
        if fatal_match:
            return None, None, None, f"Fatal: {fatal_match.group(1)}"
        if re.search(r'(Registration reject|failed|error.*registration)', logs, re.IGNORECASE):
            return None, None, None, "Registration failed"

        # Detect container exit — if the container has already stopped, stop polling
        state = run_local_command(f"sudo docker inspect --format '{{{{.State.Status}}}}' {pr['container']} 2>/dev/null").get("stdout", "").strip()
        if state == "exited":
            fatal_match = re.search(r'level=fatal\s+msg="([^"]+)"', logs)
            err = fatal_match.group(1) if fatal_match else "Container exited unexpectedly"
            return None, None, None, err

        time.sleep(poll_interval)
        waited += poll_interval
    return None, None, None, "Registration timeout"


def cleanup_packetrusher_interfaces():
    # Remove any visible stale val*/vrf* interfaces (host-visible case)
    result = run_local_command("ip -o link show")
    if result["success"]:
        for line in result["stdout"].splitlines():
            m = re.match(r'^\d+:\s+(\S+?)[@:]', line)
            if not m:
                continue
            iface = m.group(1)
            if re.match(r'^(vrf|val)\d{7,}$', iface):
                run_local_command(f"sudo ip link delete {iface} 2>/dev/null || true")
    # Wait for Docker to fully release the container network namespace before
    # unloading gtp5g — otherwise rmmod fails with "Module is in use".
    time.sleep(1)
    # Reload gtp5g to clear internal TEID/FAR/PDR state that survives container removal.
    # Try normal rmmod first; fall back to force (-f) if the namespace isn't fully released.
    r = run_local_command("sudo rmmod gtp5g 2>/dev/null")
    if not r["success"]:
        run_local_command("sudo rmmod -f gtp5g 2>/dev/null || true")
    run_local_command("sudo modprobe gtp5g")


def stop_packetrusher_internal():
    run_local_command(f"sudo docker rm -f {CONFIG['packetrusher']['container']} 2>/dev/null || true")
    cleanup_packetrusher_interfaces()


def run_ping_test_internal(ue_ip, vrf, target, count):
    container = CONFIG["packetrusher"]["container"]
    results = []
    for i in range(1, count + 1):
        result = run_local_command(f"sudo docker exec {container} ip vrf exec {vrf} ping -c 1 -W 2 -I {ue_ip} {target}", timeout=5)
        if result["success"]:
            m = re.search(r'time=([\d.]+)', result["stdout"])
            results.append({"seq": i, "status": "success", "time_ms": float(m.group(1))} if m else {"seq": i, "status": "failed", "error": "no response"})
        else:
            results.append({"seq": i, "status": "failed", "error": "timeout"})
        time.sleep(0.5)
    successful = [r for r in results if r["status"] == "success"]
    times = [r["time_ms"] for r in successful]
    return results, {"total": len(results), "successful": len(successful), "failed": len(results) - len(successful), "packet_loss": round((len(results) - len(successful)) / len(results) * 100, 2) if results else 0, "min_ms": round(min(times), 2) if times else 0, "max_ms": round(max(times), 2) if times else 0, "avg_ms": round(sum(times) / len(times), 2) if times else 0}


@app.route('/api/packetrusher/start', methods=['POST'])
def start_packetrusher():
    config = (request.get_json() or {}).get('config', 'config_hr_roaming.yml')
    ue_ip, vrf, timing, err = start_packetrusher_internal(config)
    if err:
        return jsonify({"success": False, "error": err}), 500
    resp = {"success": True, "ue_ip": ue_ip, "vrf": vrf, "timing": timing}
    print(f"[PR START] Response: {json.dumps(resp)}", flush=True)
    return jsonify(resp)


@app.route('/api/ping/test', methods=['POST'])
def manual_ping_test():
    data = request.get_json() or {}
    target = data.get('target') or PERF_SERVER_IP
    count = min(int(data.get('count', 5)), 50)
    ue_ip = data.get('ue_ip')
    vrf = data.get('vrf')
    source = data.get('source', 'packetrusher')
    if not re.match(r'^[\d.]+$|^[\w.-]+$', target):
        return jsonify({"success": False, "error": "Invalid target"}), 400
    if ue_ip and vrf:
        results, stats = run_ping_test_internal(ue_ip, vrf, target, count)
        return jsonify({"success": True, "results": results, "statistics": stats,
                        "packets_sent": stats["total"], "packets_received": stats["successful"],
                        "packet_loss": stats["packet_loss"],
                        "rtt_min": stats["min_ms"] if stats["min_ms"] else None,
                        "rtt_avg": stats["avg_ms"] if stats["avg_ms"] else None,
                        "rtt_max": stats["max_ms"] if stats["max_ms"] else None,
                        "pings": [{"seq": r["seq"], "time_ms": r.get("time_ms", 0), "ttl": 0} for r in results if r["status"] == "success"]})
    if source == 'packetrusher':
        cmd = f"sudo docker exec {CONFIG['packetrusher']['container']} ping -c {count} -W 2 {target} 2>&1"
    else:
        cmd = f"ping -c {count} -W 2 {target} 2>&1"
    result = run_local_command(cmd, timeout=count * 3 + 10)
    output = result.get("stdout", "")
    ping_data = {"target": target, "count": count, "source": source, "raw_output": output, "success": result["success"],
                 "packets_sent": 0, "packets_received": 0, "packet_loss": 100.0,
                 "rtt_min": None, "rtt_avg": None, "rtt_max": None, "rtt_mdev": None}
    loss_match = re.search(r'(\d+) packets transmitted, (\d+) received.*?(\d+(?:\.\d+)?)% packet loss', output)
    if loss_match:
        ping_data["packets_sent"] = int(loss_match.group(1))
        ping_data["packets_received"] = int(loss_match.group(2))
        ping_data["packet_loss"] = float(loss_match.group(3))
    rtt_match = re.search(r'rtt min/avg/max/mdev = ([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+)', output)
    if rtt_match:
        ping_data["rtt_min"] = float(rtt_match.group(1))
        ping_data["rtt_avg"] = float(rtt_match.group(2))
        ping_data["rtt_max"] = float(rtt_match.group(3))
        ping_data["rtt_mdev"] = float(rtt_match.group(4))
    ping_lines = []
    for line in output.split('\n'):
        ttl_match = re.search(r'from .+: icmp_seq=(\d+) ttl=(\d+) time=([\d.]+)', line)
        if ttl_match:
            ping_lines.append({"seq": int(ttl_match.group(1)), "ttl": int(ttl_match.group(2)), "time_ms": float(ttl_match.group(3))})
    ping_data["pings"] = ping_lines
    return jsonify(ping_data)


@app.route('/api/ping/stream')
def stream_ping():
    ue_ip = request.args.get('ue_ip')
    vrf = request.args.get('vrf')
    target = request.args.get('target') or PERF_SERVER_IP
    count = int(request.args.get('count', 10))
    if not ue_ip or not vrf:
        def error_stream():
            yield f"data: {json.dumps({'error': 'UE IP and VRF are required'})}\n\n"
        return Response(error_stream(), mimetype='text/event-stream')
    container = CONFIG["packetrusher"]["container"]
    def generate():
        successful, failed, times = 0, 0, []
        yield f"data: {json.dumps({'type': 'start', 'message': f'Starting ping to {target}...'})}\n\n"
        for i in range(1, count + 1):
            cmd = f"sudo docker exec {container} ip vrf exec {vrf} ping -c 1 -W 2 -I {ue_ip} {target}"
            result = run_local_command(cmd, timeout=5)
            ping_result = {"type": "ping", "seq": i, "total": count}
            if result["success"]:
                m = re.search(r'time=([\d.]+)', result["stdout"])
                if m:
                    time_ms = float(m.group(1))
                    times.append(time_ms)
                    successful += 1
                    ping_result.update({"status": "success", "time_ms": time_ms})
                else:
                    failed += 1
                    ping_result.update({"status": "failed", "error": "No response time"})
            else:
                failed += 1
                ping_result.update({"status": "failed", "error": "Timeout"})
            ping_result["stats"] = {"successful": successful, "failed": failed, "avg_ms": round(sum(times) / len(times), 2) if times else 0}
            yield f"data: {json.dumps(ping_result)}\n\n"
            time.sleep(0.5)
        yield f"data: {json.dumps({'type': 'complete', 'statistics': {'total': count, 'successful': successful, 'failed': failed, 'packet_loss': round(failed / count * 100, 2) if count else 0, 'min_ms': round(min(times), 2) if times else 0, 'max_ms': round(max(times), 2) if times else 0, 'avg_ms': round(sum(times) / len(times), 2) if times else 0}})}\n\n"
    return Response(generate(), mimetype='text/event-stream', headers={'Cache-Control': 'no-cache', 'Connection': 'keep-alive', 'X-Accel-Buffering': 'no'})


def iperf_sse_events(iperf_data, udp=False, reverse=False):
    """Turn one `iperf3 -J` document into the dashboard's SSE events.

    Shared by the PacketRusher and dongle endpoints so both render identically
    — the two differ only in how iperf3 is invoked, never in what comes back.
    iperf3 buffers its JSON to the end of the run either way, so the intervals
    are replayed with a small pause to animate the chart."""
    intervals = iperf_data.get('intervals', [])
    for idx, interval in enumerate(intervals):
        streams = interval.get('streams', [{}])
        summary = interval.get('sum', streams[0] if streams else {})
        bits_per_second = summary.get('bits_per_second', 0)
        interval_data = {'type': 'interval', 'index': idx, 'total_intervals': len(intervals),
                         'start': summary.get('start', idx), 'end': summary.get('end', idx + 1),
                         'bits_per_second': bits_per_second, 'mbps': round(bits_per_second / 1e6, 2),
                         'bytes': summary.get('bytes', 0), 'retransmits': summary.get('retransmits', 0)}
        if udp:
            interval_data['jitter_ms'] = summary.get('jitter_ms', 0)
            interval_data['lost_packets'] = summary.get('lost_packets', 0)
            interval_data['packets'] = summary.get('packets', 0)
        yield f"data: {json.dumps(interval_data)}\n\n"
        time.sleep(0.1)
    end_data = iperf_data.get('end', {})
    if udp:
        sum_data = end_data.get('sum', {})
        final = {'type': 'complete', 'bits_per_second': sum_data.get('bits_per_second', 0),
                 'mbps': round(sum_data.get('bits_per_second', 0) / 1e6, 2),
                 'bytes': sum_data.get('bytes', 0), 'jitter_ms': sum_data.get('jitter_ms', 0),
                 'lost_packets': sum_data.get('lost_packets', 0),
                 'lost_percent': sum_data.get('lost_percent', 0), 'packets': sum_data.get('packets', 0)}
        # iperf3 3.0/3.1 (the dongle ships 3.1.3) also count every out-of-order
        # datagram as lost; as the receiver (reverse) that turns netem's jitter
        # reordering into fake loss. Same correction as lib/automation/tests.sh.
        out_of_order = sum((s.get('udp') or {}).get('out_of_order', 0) or 0 for s in end_data.get('streams', []))
        version = (iperf_data.get('start') or {}).get('version', '')
        if reverse and re.match(r'iperf 3\.[01]\.', version) and out_of_order > 0:
            raw = final['lost_packets']
            final['lost_packets_raw'] = raw
            final['out_of_order'] = out_of_order
            final['lost_packets'] = max(raw - out_of_order, 0)
            if final['packets']:
                final['lost_percent'] = final['lost_packets'] * 100 / final['packets']
    else:
        # Throughput is what arrived (sum_received) in both directions;
        # retransmits are the sender's (sum_sent), which the client's JSON
        # carries in reverse mode too. Same as lib/automation/tests.sh.
        sum_data = end_data.get('sum_received') or end_data.get('sum_sent') or {}
        final = {'type': 'complete', 'bits_per_second': sum_data.get('bits_per_second', 0),
                 'mbps': round(sum_data.get('bits_per_second', 0) / 1e6, 2),
                 'bytes': sum_data.get('bytes', 0),
                 'retransmits': (end_data.get('sum_sent') or {}).get('retransmits', 0)}
    yield f"data: {json.dumps(final)}\n\n"


def download_sse_complete(result):
    """Turn curl's --write-out object into the dashboard's 'complete' event.

    Shared by the PacketRusher and dongle endpoints; both run the same curl
    field set, so both produce the same result object."""
    size_bytes = float(result.get('size_download', 0))
    speed_bps = float(result.get('speed_download', 0))
    return {'type': 'complete', 'size_bytes': size_bytes, 'size_mb': round(size_bytes / 1048576, 2),
            'speed_bytes_sec': speed_bps, 'speed_mbps': round(speed_bps * 8 / 1e6, 2),
            'speed_mb_sec': round(speed_bps / 1048576, 2),
            'time_dns': float(result.get('time_namelookup', 0)),
            'time_connect': float(result.get('time_connect', 0)),
            'time_tls': float(result.get('time_appconnect', 0)),
            'time_ttfb': float(result.get('time_starttransfer', 0)),
            'time_total': float(result.get('time_total', 0)),
            'http_code': int(result.get('http_code', 0)), 'remote_ip': result.get('remote_ip', '')}


def iperf_bandwidth_arg():
    """The iperf3 -b rate from the request ('100M', '1.5G', ...), or '' for none.

    Used for both protocols, with a different meaning: for UDP it is the rate
    the test sends (iperf3's UDP default is only 1 Mbit/s); for TCP it is an
    optional cap, and without it TCP sends as fast as the path allows.
    Validated: it ends up in a shell command."""
    bw = (request.args.get('bandwidth') or '').strip()
    return bw if re.fullmatch(r'\d+(\.\d+)?[KMG]?', bw) else ''


@app.route('/api/iperf/stream')
def stream_iperf():
    ue_ip = request.args.get('ue_ip')
    vrf = request.args.get('vrf')
    server_ip = request.args.get('server_ip', PERF_SERVER_IP)
    server_port = request.args.get('server_port', '5201')
    duration = min(int(request.args.get('duration', 10)), 120)
    reverse = request.args.get('reverse', 'false') == 'true'
    udp = request.args.get('udp', 'false') == 'true'
    bandwidth = iperf_bandwidth_arg()
    parallel = request.args.get('parallel', '1')
    if not ue_ip or not vrf:
        def error_stream():
            yield f"data: {json.dumps({'error': 'UE IP and VRF are required'})}\n\n"
        return Response(error_stream(), mimetype='text/event-stream')
    container = CONFIG["packetrusher"]["container"]
    def generate():
        mode_desc = "UDP" if udp else "TCP"
        if reverse:
            mode_desc += " (reverse/download)"
        yield f"data: {json.dumps({'type': 'start', 'message': f'Starting iperf3 {mode_desc} to {server_ip}:{server_port} for {duration}s...'})}\n\n"
        iperf_cmd = f"iperf3 -B {ue_ip} -c {server_ip} -p {server_port} -t {duration} -J -i 1"
        if int(parallel) > 1:
            iperf_cmd += f" -P {parallel}"
        if reverse:
            iperf_cmd += " -R"
        if udp:
            iperf_cmd += " -u"
        if bandwidth:
            iperf_cmd += f" -b {bandwidth}"
        cmd = f"sudo docker exec {container} ip vrf exec {vrf} {iperf_cmd}"
        yield f"data: {json.dumps({'type': 'info', 'message': f'Command: ip vrf exec {vrf} {iperf_cmd}'})}\n\n"
        try:
            proc = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            full_output = ""
            for line in proc.stdout:
                full_output += line
            proc.wait()
            if proc.returncode != 0:
                stderr = proc.stderr.read()
                yield f"data: {json.dumps({'type': 'error', 'message': f'iperf3 failed (exit {proc.returncode}): {stderr[:200]}'})}\n\n"
                return
            try:
                iperf_data = json.loads(full_output)
            except json.JSONDecodeError:
                yield f"data: {json.dumps({'type': 'error', 'message': 'Invalid JSON output from iperf3'})}\n\n"
                return
            for chunk in iperf_sse_events(iperf_data, udp=udp, reverse=reverse):
                yield chunk
        except Exception as e:
            yield f"data: {json.dumps({'type': 'error', 'message': str(e)})}\n\n"
    return Response(generate(), mimetype='text/event-stream', headers={'Cache-Control': 'no-cache', 'Connection': 'keep-alive', 'X-Accel-Buffering': 'no'})


@app.route('/api/download/stream')
def stream_download():
    ue_ip = request.args.get('ue_ip')
    vrf = request.args.get('vrf')
    url = request.args.get('url')
    if not ue_ip or not vrf:
        def error_stream():
            yield f"data: {json.dumps({'error': 'UE IP and VRF are required'})}\n\n"
        return Response(error_stream(), mimetype='text/event-stream')
    if not url:
        def error_stream():
            yield f"data: {json.dumps({'error': 'Download URL is required'})}\n\n"
        return Response(error_stream(), mimetype='text/event-stream')
    container = CONFIG["packetrusher"]["container"]
    def generate():
        yield f"data: {json.dumps({'type': 'start', 'message': f'Starting download from {url}...'})}\n\n"
        curl_format = '{"size_download":%{size_download},"speed_download":%{speed_download},"time_namelookup":%{time_namelookup},"time_connect":%{time_connect},"time_appconnect":%{time_appconnect},"time_starttransfer":%{time_starttransfer},"time_total":%{time_total},"http_code":%{http_code},"remote_ip":"%{remote_ip}"}'
        curl_cmd = (f"curl --interface {ue_ip} --output /dev/null --write-out '{curl_format}' --max-time 300 --connect-timeout 30 --progress-bar '{url}'")
        cmd = f"sudo docker exec {container} ip vrf exec {vrf} {curl_cmd}"
        yield f"data: {json.dumps({'type': 'info', 'message': f'Downloading via UE IP {ue_ip}'})}\n\n"
        try:
            proc = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            progress_sent = 0
            last_progress_time = time.time()
            stderr_data = ""
            while proc.poll() is None:
                ready, _, _ = select.select([proc.stderr], [], [], 0.5)
                if ready:
                    chunk = proc.stderr.read(256)
                    if chunk:
                        stderr_data += chunk
                        pct_matches = re.findall(r'(\d+\.?\d*)%', stderr_data)
                        if pct_matches:
                            pct = float(pct_matches[-1])
                            if pct > progress_sent:
                                progress_sent = pct
                                yield f"data: {json.dumps({'type': 'progress', 'percent': pct})}\n\n"
                else:
                    now = time.time()
                    if now - last_progress_time > 2:
                        last_progress_time = now
                        yield f"data: {json.dumps({'type': 'heartbeat'})}\n\n"
            remaining_stderr = proc.stderr.read()
            stderr_data += remaining_stderr
            stdout_data = proc.stdout.read().strip()
            if proc.returncode != 0 and not stdout_data:
                yield f"data: {json.dumps({'type': 'error', 'message': f'curl failed (exit {proc.returncode})'})}\n\n"
                return
            try:
                result = json.loads(stdout_data)
            except json.JSONDecodeError:
                yield f"data: {json.dumps({'type': 'error', 'message': 'Invalid curl output'})}\n\n"
                return
            http_code = int(result.get('http_code', 0))
            if http_code != 200:
                yield f"data: {json.dumps({'type': 'error', 'message': f'HTTP {http_code}'})}\n\n"
                return
            yield f"data: {json.dumps(download_sse_complete(result))}\n\n"
        except Exception as e:
            yield f"data: {json.dumps({'type': 'error', 'message': str(e)})}\n\n"
    return Response(generate(), mimetype='text/event-stream', headers={'Cache-Control': 'no-cache', 'Connection': 'keep-alive', 'X-Accel-Buffering': 'no'})


# ============================================================================
# WEBPAGE LOAD TEST (Browsertime)
# ============================================================================

WEBPAGE_PRESET_URLS = [
    {"label": "YouTube",   "url": "https://www.youtube.com/@Cristiano"},
    {"label": "Instagram", "url": "https://www.instagram.com/leomessi/"},
    {"label": "Facebook",  "url": "https://www.facebook.com/LeonardoDiCaprio/"},
    {"label": "Google",    "url": "https://www.google.com/search?q=lionel+messi"},
    {"label": "Wikipedia", "url": "https://en.wikipedia.org/wiki/Cristiano_Ronaldo"},
    {"label": "GitHub",    "url": "https://github.com/open5gs/open5gs"},
    {"label": "Cloudflare","url": "http://1.1.1.1"},
]

BT_IMAGE = "sitespeedio/browsertime"

# Fixed container name, deliberately the same one lib/features/browsertime_5g.sh uses. Every
# run joins PacketRusher's network namespace, where the ip rules are global
# rather than per-container, so two concurrent runs delete each other's routing.
# Sharing one name makes Docker refuse the second run instead.
BT_CONTAINER = "roamingtb-browsertime"

# Resolvers applied inside the browsertime container. The image otherwise
# inherits the host's resolvers, which are typically site-local addresses that
# are unreachable once traffic is routed into the tunnel. Public resolvers are
# reachable through the tunnel, keep DNS latency inside the measured 5G path,
# and carry no site-specific assumptions — important for other deployments.
BT_DNS_SERVERS = os.environ.get("BT_DNS_SERVERS", "8.8.8.8 1.1.1.1")


@app.route('/api/webpage/urls', methods=['GET'])
def get_webpage_urls():
    return jsonify({"success": True, "urls": WEBPAGE_PRESET_URLS})


@app.route('/api/webpage/stream')
def stream_webpage():
    url = request.args.get('url', '').strip()
    vrf = request.args.get('vrf', '').strip()
    ue_ip = request.args.get('ue_ip', '').strip()
    browser = request.args.get('browser', 'firefox').strip().lower()

    def err(msg):
        def g():
            yield f"data: {json.dumps({'type':'error','message':msg})}\n\n"
        return Response(g(), mimetype='text/event-stream')

    if not url or not vrf or not ue_ip:
        return err("url, vrf and ue_ip are required")
    if not re.match(r'^https?://', url):
        return err("URL must start with http:// or https://")
    # Basic safety check — no shell metacharacters in VRF name (should be vrf\d+)
    if not re.match(r'^vrf\d+$', vrf):
        return err(f"Invalid VRF name: {vrf}")
    if browser not in ('firefox', 'chrome', 'edge'):
        return err(f"Invalid browser: {browser}")

    pr_container = CONFIG["packetrusher"]["container"]

    def generate():
        orig_tcp_l3mdev = "0"
        orig_udp_l3mdev = "0"
        pr_pid = None
        proc = None
        # Docker here is snap-confined and cannot mount from /tmp — the volume
        # source must live under $HOME. Create the results dir there.
        bt_base = os.path.expanduser("~/.cache/roamingtb_browsertime")
        os.makedirs(bt_base, exist_ok=True)
        output_dir = tempfile.mkdtemp(prefix='webui_', dir=bt_base)
        os.chmod(output_dir, 0o777)
        try:
            yield f"data: {json.dumps({'type':'start','message':f'Launching Browsertime for {url}'})}\n\n"

            # Refuse to run concurrently: runs share PacketRusher's netns and
            # would corrupt each other's routing. A container left from an
            # earlier run that was not cleaned up is removed rather than
            # blocking the feature forever.
            bt_state = run_local_command(
                f"sudo docker inspect -f '{{{{.State.Status}}}}' {BT_CONTAINER} 2>/dev/null"
            ).get("stdout", "").strip()
            if bt_state == "running":
                yield f"data: {json.dumps({'type':'error','message':'A browsertime run is already in progress. Wait for it to finish, or stop it, then retry.'})}\n\n"
                return
            if bt_state:
                run_local_command(f"sudo docker rm -f {BT_CONTAINER} 2>/dev/null || true")

            # Enable VRF l3mdev socket acceptance in PacketRusher's network namespace.
            # Without this Firefox's unbound sockets get RST on every SYN-ACK because
            # replies arrive on the VRF slave (val*) interface.
            r = run_local_command(f"sudo docker inspect -f '{{{{.State.Pid}}}}' {pr_container}")
            pr_pid = r.get("stdout", "").strip() if r["success"] else None
            if pr_pid:
                orig_tcp_l3mdev = run_local_command(
                    f"sudo nsenter --net=/proc/{pr_pid}/ns/net -- sysctl -n net.ipv4.tcp_l3mdev_accept 2>/dev/null"
                ).get("stdout", "0").strip()
                orig_udp_l3mdev = run_local_command(
                    f"sudo nsenter --net=/proc/{pr_pid}/ns/net -- sysctl -n net.ipv4.udp_l3mdev_accept 2>/dev/null"
                ).get("stdout", "0").strip()
                run_local_command(f"sudo nsenter --net=/proc/{pr_pid}/ns/net -- sysctl -w net.ipv4.tcp_l3mdev_accept=1")
                run_local_command(f"sudo nsenter --net=/proc/{pr_pid}/ns/net -- sysctl -w net.ipv4.udp_l3mdev_accept=1")
                yield f"data: {json.dumps({'type':'info','message':'VRF l3mdev socket accept enabled'})}\n\n"

            # Browser-specific flags. Firefox disables IPv6 DNS; Chrome/Edge
            # (Chromium) need --no-sandbox to run in the container and disable IPv6.
            browser_args = {
                'firefox': "--firefox.preference network.dns.disableIPv6:true",
                'chrome':  "--chrome.args no-sandbox --chrome.args disable-ipv6",
                'edge':    "--edge.args no-sandbox --edge.args disable-ipv6",
            }[browser]

            # /start.sh cd's into /browsertime when it's a mounted volume, so
            # browsertime.json is written under the mounted output_dir on the host.
            inner_script = "\n".join([
                f"VRF_TABLE=$(ip -d link show {vrf} 2>/dev/null | grep -oP 'table \\K[0-9]+')",
                "if [ -z \"$VRF_TABLE\" ]; then echo 'ERROR: VRF table not found' >&2; exit 1; fi",
                # Point the browser at a resolver reachable through the tunnel.
                # The container otherwise keeps the host's site-local resolvers,
                # whose traffic the priority-50 rule sends into the tunnel where
                # they do not exist, so every lookup hangs until browsertime's
                # 120s page timeout and no page ever loads.
                ": > /etc/resolv.conf",
                f"for ns in {BT_DNS_SERVERS}; do echo \"nameserver $ns\" >> /etc/resolv.conf; done",
                # Drop anything left at our priorities by an interrupted run.
                # Deleting by priority also clears the hardcoded-subnet rules
                # written by older versions. Priorities 5, 6 and 50 are used
                # only here; the kernel defaults are 0, 32766 and 32767. This
                # runs before the address lookup below so that lookup sees the
                # unmodified main-table routing.
                "for p in 5 6 50; do while ip rule del priority $p 2>/dev/null; do :; done; done",
                "_cleanup() {",
                "    for p in 5 6 50; do while ip rule del priority $p 2>/dev/null; do :; done; done",
                "}",
                "trap _cleanup EXIT",
                # PacketRusher's GTP-U source address — never hardcoded, since
                # every deployment addresses its gNB differently.
                #
                # Read from the live GTP-U socket bind (we share PacketRusher's
                # network namespace, so its sockets are visible here). That is
                # the exact source the encapsulated packets will carry, so it
                # stays correct even if the gNB is multi-homed or configured
                # with an N3 address that is not on the default-route interface.
                "PR_SRC=$(ss -unaH 2>/dev/null | awk '$4 ~ /:2152$/ {sub(/:2152$/,\"\",$4); print $4; exit}')",
                # Reject a wildcard bind (0.0.0.0), an IPv6 bind, or no ss.
                "case \"$PR_SRC\" in \"\"|0.0.0.0|*[!0-9.]*) PR_SRC=\"\" ;; esac",
                # Fallback: the address on the interface holding the default route.
                "if [ -z \"$PR_SRC\" ]; then",
                "    PR_IFACE=$(ip -o route show table main default | grep -oP 'dev \\K\\S+' | head -1)",
                "    PR_SRC=$(ip -4 -o addr show dev \"$PR_IFACE\" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)",
                "fi",
                "if [ -z \"$PR_SRC\" ]; then echo 'ERROR: could not determine the gNB GTP-U source address; refusing to continue' >&2; exit 1; fi",
                # Split routing, deriving every value at runtime:
                #
                #   priority 5   PacketRusher's own traffic — the GTP-U it sends
                #                to the UPF and its NGAP to the AMF — is sourced
                #                from $PR_SRC and must keep using the host
                #                network. The UPF's N3 endpoint is typically
                #                reachable only via this namespace's default
                #                route, so without this the next rule would
                #                route the tunnel's own encapsulation back into
                #                the tunnel: a loop that shows up as TX errors
                #                on the val interface and passes no traffic.
                #   priority 6   anything with a specific route (link subnets,
                #                docker bridges) stays local; main's default
                #                route is suppressed so it cannot swallow
                #                internet traffic.
                #   priority 50  everything else — the internet — goes to the
                #                VRF table and out through the tunnel. The
                #                browser's sockets are unbound, so they have no
                #                source address at lookup time, miss the
                #                priority 5 rule, and land here as intended.
                "ip rule add from $PR_SRC lookup main priority 5",
                "ip rule add from all lookup main suppress_prefixlength 0 priority 6",
                "ip rule add from all lookup $VRF_TABLE priority 50",
                f"/start.sh --browser {browser}"
                f" {browser_args}"
                f" --iterations 1 --video false --visualMetrics false"
                f" '{url}'",
            ])

            cmd_list = [
                # sudo: the backend may not be in the 'docker' group (the user is
                # added to it during setup, but a backend started before that
                # takes effect has no socket access). Every other docker call in
                # this file uses sudo via passwordless sudoers for the same
                # reason; without it this run fails with a socket permission
                # error and surfaces as "Browsertime exited with code 1".
                'sudo', 'docker', 'run', '--rm',
                # Fixed name so the container is addressable: without it Docker
                # assigns a random name and a stopped run cannot be cleaned up.
                # It doubles as a mutex — runs share PacketRusher's netns, where
                # the ip rules are global, so a second concurrent run would
                # delete this one's routing. Docker refuses the duplicate name.
                '--name', BT_CONTAINER,
                '--net', f'container:{pr_container}',
                '--cap-add', 'NET_ADMIN',
                '--shm-size', '1gb',
                '-v', f'{output_dir}:/browsertime',
                '--entrypoint', '/bin/sh',
                BT_IMAGE,
                '-c', inner_script,
            ]

            yield f"data: {json.dumps({'type':'info','message':f'{browser.capitalize()} launching — this may take 30–90 seconds...'})}\n\n"

            proc = subprocess.Popen(cmd_list, shell=False, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True)
            all_lines = []
            last_hb = time.time()
            while proc.poll() is None:
                ready, _, _ = select.select([proc.stdout], [], [], 1.0)
                if ready:
                    line = proc.stdout.readline()
                    if line:
                        all_lines.append(line.rstrip('\n'))
                        stripped = line.strip()
                        if stripped and not stripped.startswith('=') and len(stripped) < 300:
                            yield f"data: {json.dumps({'type':'log','message':stripped})}\n\n"
                if time.time() - last_hb > 5:
                    last_hb = time.time()
                    yield f"data: {json.dumps({'type':'heartbeat'})}\n\n"
            for line in proc.stdout.read().splitlines():
                all_lines.append(line)

            if proc.returncode != 0:
                for line in all_lines:
                    s = line.strip()
                    if s and not s.startswith('=') and len(s) < 400:
                        yield f"data: {json.dumps({'type':'log','message':s})}\n\n"
                yield f"data: {json.dumps({'type':'error','message':f'Browsertime exited with code {proc.returncode}'})}\n\n"
                return

            # Locate the browsertime.json written into the mounted output dir
            bt_json_path = None
            for root, _, files in os.walk(output_dir):
                if 'browsertime.json' in files:
                    bt_json_path = os.path.join(root, 'browsertime.json')
                    break

            if not bt_json_path:
                yield f"data: {json.dumps({'type':'error','message':'No results file — browser may have failed to load the page'})}\n\n"
                return

            with open(bt_json_path) as f:
                bt = json.load(f)

            entry = bt[0] if bt else {}

            # If browsertime gave up on the page it sets markedAsFailure and
            # discards all timings — report that instead of silent zeros.
            if entry.get('markedAsFailure'):
                fmsgs = entry.get('failureMessages') or ['Page failed to load']
                yield f"data: {json.dumps({'type':'error','message':fmsgs[0]})}\n\n"
                return

            # Same median field paths the automation script (jq) uses
            s = entry.get('statistics', {}).get('timings', {}) or {}
            pt        = s.get('pageTimings', {}) or {}
            ttfb      = s.get('ttfb', {}).get('median') or 0
            fcp       = (s.get('paintTiming', {}).get('first-contentful-paint', {}).get('median') or
                         s.get('timeToContentfulPaint', {}).get('median') or 0)
            lcp_s     = s.get('largestContentfulPaint', {})
            lcp       = lcp_s.get('renderTime', {}).get('median') or lcp_s.get('loadTime', {}).get('median') or 0
            dcl       = pt.get('domContentLoadedTime', {}).get('median') or 0
            # Page Load = standard loadEventEnd (matches browsertime's "Load:" log
            # line). Each field carries only its own metric: substituting another
            # one when it is missing would report a page whose load event never
            # fired as if it had loaded.
            page_load = pt.get('pageLoadTime', {}).get('median') or 0
            # Net idle = fullyLoaded (navigation start → network fully idle),
            # including background traffic after the page has loaded.
            total_time = s.get('fullyLoaded', {}).get('median') or 0

            if not page_load:
                yield f"data: {json.dumps({'type':'error','message':'Page did not finish loading — no load event within the timeout'})}\n\n"
                return

            yield f"data: {json.dumps({'type':'complete','url':url,'ttfb_ms':round(ttfb),'fcp_ms':round(fcp),'lcp_ms':round(lcp),'dcl_ms':round(dcl),'page_load_ms':round(page_load),'total_time_ms':round(total_time)})}\n\n"

        except Exception as e:
            yield f"data: {json.dumps({'type':'error','message':str(e)})}\n\n"
        finally:
            # This also runs when the client disconnects — i.e. when the user
            # hits Stop, which closes the SSE stream and raises GeneratorExit at
            # the next yield. The container must die first: killing the local
            # `docker run` process is not enough (the daemon keeps the container
            # alive), and the two steps below actively sabotage a container that
            # is still running — restoring l3mdev breaks its networking, and
            # removing output_dir deletes the directory it is writing into.
            run_local_command(f"sudo docker rm -f {BT_CONTAINER} 2>/dev/null || true")
            if proc is not None and proc.poll() is None:
                proc.kill()
            if pr_pid:
                # docker rm -f is a SIGKILL, so the container's own EXIT trap
                # never runs and its ip rules would stay behind in
                # PacketRusher's namespace, sending unrelated traffic into the
                # tunnel. Remove them from out here too.
                for p in (5, 6, 50):
                    run_local_command(
                        f"sudo nsenter --net=/proc/{pr_pid}/ns/net -- sh -c "
                        f"'while ip rule del priority {p} 2>/dev/null; do :; done'"
                    )
                run_local_command(f"sudo nsenter --net=/proc/{pr_pid}/ns/net -- sysctl -w net.ipv4.tcp_l3mdev_accept={orig_tcp_l3mdev} 2>/dev/null")
                run_local_command(f"sudo nsenter --net=/proc/{pr_pid}/ns/net -- sysctl -w net.ipv4.udp_l3mdev_accept={orig_udp_l3mdev} 2>/dev/null")
            shutil.rmtree(output_dir, ignore_errors=True)

    return Response(generate(), mimetype='text/event-stream',
                    headers={'Cache-Control':'no-cache','Connection':'keep-alive','X-Accel-Buffering':'no'})


# ============================================================================
# HEALTH + WEBSOCKETS
# ============================================================================

@app.route('/api/health', methods=['GET'])
def health():
    ssh = run_ssh_command(CONFIG["remote"]["host"], CONFIG["remote"]["user"], "echo ok", 10)
    job = script_job_manager.get_current_job()
    local_ipsec = check_ipsec_status_detailed("local")
    remote_ipsec = check_ipsec_status_detailed("remote")
    return jsonify({
        "status": "healthy",
        "local_docker": run_local_command("docker --version")["success"],
        "remote_ssh": ssh["success"],
        "active_job": job['id'] if job and job['status'] == 'running' else None,
        "active_job_type": job['type'] if job and job['status'] == 'running' else None,
        "ipsec": {"local": local_ipsec, "remote": remote_ipsec},
        "scripts": {
            "automation": os.path.exists(CONFIG["automation_script"]),
            "batch_runner": os.path.exists(CONFIG["batch_runner_script"]),
            "esp_config": os.path.exists(CONFIG["esp_config_script"]),
        }
    })


@app.route('/api/config', methods=['GET'])
def get_config_api():
    return jsonify({**CONFIG, "ipsec_mode_names": IPSEC_MODE_NAMES})


@app.route('/api/features', methods=['GET'])
def get_features():
    """Optional dashboard features enabled on this machine."""
    return jsonify({"success": True, "dongle": DONGLE_ENABLED})


@app.before_request
def _gate_dongle_routes():
    # Commercial-RAN routes exist only when the feature is enabled, so a
    # testbed without a DSK never SSHes anywhere on the dashboard's behalf.
    if not DONGLE_ENABLED and request.path.startswith(("/api/dongle/", "/api/gnb/")):
        return _dsk_disabled_response()


@socketio.on('connect')
def on_connect():
    global _dongle_watchers
    with _dongle_watchers_lock:
        _dongle_watchers += 1
    job = script_job_manager.get_current_job()
    if job:
        emit('script_status', job)
    emit('connected', {'status': 'connected'})


@socketio.on('disconnect')
def on_disconnect():
    global _dongle_watchers
    with _dongle_watchers_lock:
        _dongle_watchers = max(0, _dongle_watchers - 1)


@socketio.on('get_script_status')
def on_get_script_status():
    job = script_job_manager.get_current_job()
    emit('script_status', job)


@socketio.on('get_script_output')
def on_get_script_output(data=None):
    n = (data or {}).get('lines', 200)
    lines = script_job_manager.get_recent_output(n)
    emit('script_output_batch', {'lines': lines})


@socketio.on('get_dongle_status')
def on_get_dongle_status(data=None):
    emit('dongle_snapshot', dongle_session.snapshot((data or {}).get('lines', 500)))


if __name__ == '__main__':
    print("=" * 60)
    print(" Open5GS Testbed API v2.2")
    print("=" * 60)
    print(f" Automation script:  {CONFIG['automation_script']}")
    print(f" Batch runner:       {CONFIG['batch_runner_script']}")
    print(f" ESP config script:  {CONFIG['esp_config_script']}")
    _dongle = CONFIG["dongle"]
    if not DONGLE_ENABLED:
        print(" Dongle UE:          disabled (enable: lib/features/set-dongle-mode.sh on)")
    elif dongle_missing_settings():
        print(f" Dongle UE:          NOT CONFIGURED — set DONGLE_* in webui/dongle.env "
              f"({', '.join(dongle_missing_settings())}) to enable the dongle button")
    else:
        print(f" Dongle UE:          {_dongle['user']}@{_dongle['host']}:{_dongle.get('port', 22)} "
              f"({dongle_auth_mode()} auth) -> {dongle_remote_command()}")
        for _d in CONFIG["dongles"]:
            _mark = "▶" if _d["id"] == active_dongle()["id"] else " "
            print(f"   {_mark} {_d['id']}: {_d['label']:<10} {_d['ssh_host']}:{_d.get('ssh_port') or 8822}")
    if not os.path.isfile(CONFIG['esp_config_script']):
        print("   ⚠️  esp_config.sh NOT FOUND — IPsec cipher selection will fail.")
        print("   Tried:")
        for p in CONFIG['esp_config_script_candidates']:
            print(f"     - {p}")
    print(f" Configs dir:        {CONFIG['configs_dir']}")
    print(f" Results dir:        {CONFIG['results_dir']}")
    print("=" * 60)
    socketio.run(app, host='0.0.0.0', port=9090, debug=False, allow_unsafe_werkzeug=True, log_output=False)
