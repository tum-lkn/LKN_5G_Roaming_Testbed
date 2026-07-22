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
PERF_SERVER_IP = "10.162.149.115"  # PERF_SERVER_IP
PERF_SERVER_USER = "roaming"       # PERF_SERVER_USER
DEFAULT_DN_INTERFACE = "ens18"

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

CONFIG = {
    "local": {"name": "Visited Network (VPLMN)", "host": "localhost", "user": VPLMN_USER, "path": VPLMN_DIR, "ip": VPLMN_IP},
    "remote": {"name": "Home Network (HPLMN)", "host": HPLMN_IP, "user": HPLMN_USER, "path": "~/LKN_5G_Roaming_Testbed/HPLMN", "ip": HPLMN_IP},
    "packetrusher": {"container": "packetrusher", "image": "ghcr.io/borjis131/packetrusher:main", "network": "my_second_network", "ip": "192.168.70.190", "config_path": os.path.join(VPLMN_DIR, "configs", "Packetrusher_Configs")},
    "results_dir": os.path.join(VPLMN_DIR, "results"),
    "configs_dir": os.path.join(VPLMN_DIR, "configs"),
    "plots_dir": os.path.join(os.path.dirname(os.path.abspath(__file__)), "plots_cache"),
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

UPF_IMAGES = {"hr": "open5gs-upf:v2.7.6-hr", "lbo": "open5gs-upf:v2.7.2", "non-roaming": "open5gs-upf:v2.7.2"}

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

    def complete_job(self, results=None, error=None, exit_code=None):
        with self.lock:
            if self.current_job:
                self.current_job['status'] = 'error' if error else 'completed'
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
        with self.lock:
            if self.current_job and self.current_job['status'] == 'running':
                job_type = self.current_job.get('type')
                pid = self.current_job.get('pid')
                if pid:
                    try:
                        os.killpg(os.getpgid(pid), signal.SIGINT)
                        time.sleep(2)
                        try:
                            os.killpg(os.getpgid(pid), signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    except ProcessLookupError:
                        pass
                    except Exception as e:
                        print(f"Error killing process: {e}")

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
    results_dir = CONFIG["results_dir"]
    if not os.path.exists(results_dir):
        return None
    files = [f for f in os.listdir(results_dir) if f.endswith('.json')]
    if not files:
        return None
    files.sort(reverse=True)
    latest = os.path.join(results_dir, files[0])
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
    prefix = "sudo "
    result_data = {"service_running": False, "tunnel_established": False, "tunnel_info": {}, "connections": [], "security_associations": [], "raw_status": "", "error": None, "esp_proposal": None}
    service_check = run_command(location, f"{prefix}ipsec status 2>&1")
    if service_check["success"] or service_check.get("stdout"):
        output = service_check.get("stdout", "") + service_check.get("stderr", "")
        result_data["raw_status"] = output[:1000]
        if "Security Associations" in output or "ESTABLISHED" in output:
            result_data["service_running"] = True
        elif "ipsec is not running" in output.lower() or "not running" in output.lower():
            result_data["service_running"] = False
        else:
            ps_check = run_command(location, f"{prefix}pgrep -x charon || {prefix}pgrep -x pluto || {prefix}systemctl is-active strongswan 2>/dev/null || {prefix}systemctl is-active ipsec 2>/dev/null")
            ps_output = ps_check.get("stdout", "").strip()
            result_data["service_running"] = ps_check["success"] and (ps_output != "" and ps_output != "inactive")
        if "ESTABLISHED" in output:
            result_data["tunnel_established"] = True
            conn_matches = re.findall(r'(\S+)\[\d+\]:\s+ESTABLISHED\s+(\d+\s+\w+)\s+ago,\s+(\S+)\[(\S+)\]\.\.\.(\S+)\[(\S+)\]', output)
            for match in conn_matches:
                result_data["connections"].append({"name": match[0], "established": match[1], "local_ip": match[2], "local_id": match[3], "remote_ip": match[4], "remote_id": match[5]})
            peer_match = re.search(r'(\d+\.\d+\.\d+\.\d+).*ESTABLISHED', output)
            if peer_match:
                result_data["tunnel_info"]["peer_ip"] = peer_match.group(1)
        # Extract ESP proposal from status output if visible (e.g. "ESP:AES_GCM_16_128/...")
        esp_match = re.search(r'ESP[:=]\s*([A-Z0-9_/-]+)', output)
        if esp_match:
            result_data["esp_proposal"] = esp_match.group(1)
        if "INSTALLED" in output:
            result_data["tunnel_info"]["sa_installed"] = True
    else:
        result_data["service_running"] = False
        result_data["error"] = service_check.get("stderr", "") or service_check.get("error", "Unknown error")
        result_data["raw_status"] = result_data["error"]

    xfrm_check = run_command(location, f"{prefix}ip xfrm state 2>/dev/null | head -30")
    if xfrm_check["success"] and "proto esp" in xfrm_check["stdout"]:
        result_data["tunnel_info"]["esp_active"] = True
        result_data["tunnel_established"] = True
        result_data["tunnel_info"]["esp_sa_count"] = xfrm_check["stdout"].count("proto esp")
        # Try to pull aead/auth/enc lines for cipher detection
        aead_m = re.search(r'aead\s+([\w-]+)\s+', xfrm_check["stdout"])
        enc_m = re.search(r'enc\s+([\w-]+)\s+', xfrm_check["stdout"])
        auth_m = re.search(r'auth(?:-trunc)?\s+([\w-]+)\s+', xfrm_check["stdout"])
        if aead_m:
            result_data["tunnel_info"]["xfrm_aead"] = aead_m.group(1)
        if enc_m:
            result_data["tunnel_info"]["xfrm_enc"] = enc_m.group(1)
        if auth_m:
            result_data["tunnel_info"]["xfrm_auth"] = auth_m.group(1)

    if result_data["tunnel_established"] or result_data["service_running"]:
        nat_check = run_command(location, f"{prefix}ss -ulnp 2>/dev/null | grep -E ':(4500|500)\\s' || {prefix}netstat -ulnp 2>/dev/null | grep -E ':(4500|500)'")
        result_data["tunnel_info"]["nat_t_active"] = "4500" in nat_check.get("stdout", "")
        result_data["tunnel_info"]["ike_port_active"] = "500" in nat_check.get("stdout", "")

    return result_data


# Read the active esp= line from /etc/ipsec.conf (so the UI can show what's
# currently configured even before the tunnel comes up).
def read_active_esp_line(location="local"):
    prefix = "sudo "
    r = run_command(location, f"{prefix}grep -E '^\\s*esp=' /etc/ipsec.conf 2>/dev/null | head -1")
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


def start_ipsec_service(location="local"):
    prefix = "sudo "
    status = check_ipsec_status_detailed(location)
    if status["service_running"] and status["tunnel_established"]:
        return {"success": True, "message": "IPsec is already running with established tunnel", "status": status}
    start_commands = [f"{prefix}ipsec start", f"{prefix}systemctl start strongswan", f"{prefix}systemctl start ipsec", f"{prefix}strongswan start"]
    result = None
    for cmd in start_commands:
        result = run_command(location, cmd, timeout=30)
        if result["success"]:
            break
    if not result or not result["success"]:
        result = run_command(location, f"{prefix}ipsec restart", timeout=30)
    time.sleep(3)
    new_status = check_ipsec_status_detailed(location)
    if new_status["service_running"]:
        if not new_status["tunnel_established"]:
            conn_name = IPSEC_CONN_NAMES.get(location, "")
            if conn_name:
                run_command(location, f"{prefix}ipsec up {conn_name} 2>/dev/null || true", timeout=15)
            time.sleep(2)
            new_status = check_ipsec_status_detailed(location)
        return {"success": True, "message": "IPsec service started successfully", "status": new_status, "tunnel_established": new_status["tunnel_established"]}
    return {"success": False, "error": "Failed to start IPsec service", "details": result.get("stderr", result.get("error", "Unknown error")), "status": new_status}


def stop_ipsec_service(location="local"):
    prefix = "sudo "
    conn_name = IPSEC_CONN_NAMES.get(location, "")
    if conn_name:
        run_command(location, f"{prefix}ipsec down {conn_name} 2>/dev/null || true", timeout=10)
    for cmd in [f"{prefix}ipsec stop", f"{prefix}systemctl stop strongswan", f"{prefix}systemctl stop ipsec"]:
        run_command(location, cmd, timeout=30)
    time.sleep(2)
    new_status = check_ipsec_status_detailed(location)
    if not new_status["service_running"]:
        return {"success": True, "message": "IPsec service stopped successfully", "status": new_status}
    run_command(location, f"{prefix}killall charon 2>/dev/null || true")
    run_command(location, f"{prefix}killall pluto 2>/dev/null || true")
    time.sleep(1)
    final_status = check_ipsec_status_detailed(location)
    return {"success": not final_status["service_running"], "message": "IPsec service stopped" if not final_status["service_running"] else "Failed to stop IPsec", "status": final_status}


def restart_ipsec_service(location="local"):
    prefix = "sudo "
    run_command(location, f"{prefix}ipsec restart", timeout=30)
    time.sleep(3)
    new_status = check_ipsec_status_detailed(location)
    return {"success": new_status["service_running"], "message": "IPsec service restarted" if new_status["service_running"] else "Failed to restart IPsec", "status": new_status}


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
    """
    prefix = "sudo "
    if not interface:
        return {"success": False, "error": "Interface not found"}
    if not re.fullmatch(r'\d+(\.\d+)?(ms|s)', delay.strip()):
        return {"success": False, "error": "Invalid delay format"}
    commands = [
        f"{prefix}tc qdisc del dev {interface} root 2>/dev/null || true",
        f"{prefix}tc qdisc add dev {interface} root handle 1: prio",
        f"{prefix}tc qdisc add dev {interface} parent 1:3 handle 30: netem delay {delay}",
        # IPsec off: plaintext GTP-U
        f"{prefix}tc filter add dev {interface} protocol ip parent 1:0 prio 1 u32 match ip dport {GTPU_PORT} 0xffff flowid 1:3",
        f"{prefix}tc filter add dev {interface} protocol ip parent 1:0 prio 1 u32 match ip sport {GTPU_PORT} 0xffff flowid 1:3",
        # IPsec on: the N9 SA is scoped to udp/2152, so ESP here is GTP-U only
        f"{prefix}tc filter add dev {interface} protocol ip parent 1:0 prio 2 u32 match ip protocol {ESP_PROTOCOL} 0xff flowid 1:3",
        # NAT-T fallback, in case the peers ever end up behind NAT
        f"{prefix}tc filter add dev {interface} protocol ip parent 1:0 prio 3 u32 match ip protocol 17 0xff match ip dport {IPSEC_NAT_T_PORT} 0xffff flowid 1:3",
        f"{prefix}tc filter add dev {interface} protocol ip parent 1:0 prio 3 u32 match ip protocol 17 0xff match ip sport {IPSEC_NAT_T_PORT} 0xffff flowid 1:3",
    ]
    for cmd in commands:
        result = run_command(location, cmd)
        if not result["success"] and "del dev" not in cmd:
            return {"success": False, "error": f"Failed: {result.get('stderr', result.get('error', 'Unknown'))}"}
    container_cache.invalidate(location)
    return {"success": True, "message": f"Delay {delay} applied to N9 user plane (GTP-U, plain and IPsec)", "interface": interface, "port": GTPU_PORT, "mode": DelayMode.GTPU_COMBINED}


def set_ipsec_tunnel_delay(interface, delay, location="local"):
    prefix = "sudo "
    if not re.fullmatch(r'\d+(\.\d+)?(ms|s)', delay.strip()):
        return {"success": False, "error": "Invalid delay format"}
    commands = [
        f"{prefix}tc qdisc del dev {interface} root 2>/dev/null || true",
        f"{prefix}tc qdisc add dev {interface} root handle 1: prio",
        f"{prefix}tc qdisc add dev {interface} parent 1:3 handle 30: netem delay {delay}",
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
    result = run_command(location, f"{prefix}tc qdisc add dev {interface} root netem delay {delay}")
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
    cmd = f"{prefix}docker exec {container_id} tc qdisc replace dev eth0 root netem delay {delay}"
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
    if include_upf and roaming_mode:
        lines.extend([f"UPF_IMAGE={UPF_IMAGES.get(roaming_mode, 'open5gs-upf:v2.7.2')}", ""])
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
    ]
    if params.get('ipsec_mode'):
        lines.append(f"IPSEC_MODE={params['ipsec_mode']}")
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
            lines.append(f"IPERF_BANDWIDTH={params['iperf_bandwidth']}")
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
             f"tc qdisc add dev eth0 parent 1:3 handle 30: netem delay {delay}"]
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
            f"sudo tc qdisc add dev {interface} parent 1:3 handle 30: netem delay {delay}"]
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


def _dn_interface():
    """Read the DN/performance-server interface from main.conf, fallback to ens18."""
    conf = os.path.join(VPLMN_DIR, "configs", "main.conf")
    try:
        with open(conf, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                if key.strip() in {"SERVER_INTERFACE", "N6_SERVER_INTERFACE"}:
                    value = value.strip().strip('"').strip("'")
                    if value:
                        return value
    except OSError:
        pass
    return DEFAULT_DN_INTERFACE


def set_upf_dn_delay(location, delay):
    """Apply DN/N6 delay on ogstun inside the primary UPF container."""
    name = _upf_container(location)
    if not name:
        return {"success": False, "error": f"UPF container not found on {location}"}
    cmd = (
        "tc qdisc del dev ogstun root 2>/dev/null || true; "
        f"tc qdisc add dev ogstun root netem delay {delay}"
    )
    r = run_command(location, f"sudo docker exec {name} sh -c {shlex.quote(cmd)}")
    container_cache.invalidate(location)
    if r["success"]:
        return {"success": True, "container": name, "interface": "ogstun"}
    return {"success": False, "error": r.get("stderr") or r.get("error") or "Failed"}


def set_dn_server_delay(delay):
    interface = _dn_interface()
    cmd = f"sudo tc qdisc del dev {shlex.quote(interface)} root 2>/dev/null || true; sudo tc qdisc add dev {shlex.quote(interface)} root netem delay {delay}"
    r = run_ssh_command(PERF_SERVER_IP, PERF_SERVER_USER, cmd)
    if r["success"]:
        return {"success": True, "host": PERF_SERVER_IP, "interface": interface}
    return {"success": False, "error": r.get("stderr") or r.get("error") or "Failed"}


def remove_upf_dn_delay(location):
    name = _upf_container(location)
    if not name:
        return {"success": False, "error": f"UPF container not found on {location}"}
    run_command(location, f"sudo docker exec {name} sh -c 'tc qdisc del dev ogstun root 2>/dev/null || true'")
    container_cache.invalidate(location)
    return {"success": True, "container": name, "interface": "ogstun"}


def remove_dn_server_delay():
    interface = _dn_interface()
    cmd = f"sudo tc qdisc del dev {shlex.quote(interface)} root 2>/dev/null || true"
    run_ssh_command(PERF_SERVER_IP, PERF_SERVER_USER, cmd)
    return {"success": True, "host": PERF_SERVER_IP, "interface": interface}


def get_upf_dn_delay(location):
    name = _upf_container(location)
    if not name:
        return None
    r = run_command(location, f"sudo docker exec {name} tc qdisc show dev ogstun 2>/dev/null", timeout=5)
    if r["success"] and "netem" in r["stdout"]:
        m = re.search(r'delay\s+([\d.]+\s*\w+)', r["stdout"])
        if m:
            return m.group(1).replace(" ", "")
    return None


def get_dn_server_delay():
    interface = _dn_interface()
    r = run_ssh_command(PERF_SERVER_IP, PERF_SERVER_USER, f"sudo tc qdisc show dev {shlex.quote(interface)} 2>/dev/null", timeout=5)
    if r["success"] and "netem" in r["stdout"]:
        m = re.search(r'delay\s+([\d.]+\s*\w+)', r["stdout"])
        if m:
            return m.group(1).replace(" ", "")
    return None


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
        f_dn_srv = ex.submit(get_dn_server_delay)
        sepp_l, sepp_r = f_sepp_l.result(), f_sepp_r.result()
        upf_l, upf_r   = f_upf_l.result()["delay"], f_upf_r.result()["delay"]
        smf_r          = f_smf_r.result()
        hupf_r         = f_hupf_r.result()["delay"] if f_hupf_r else None
        dn_l, dn_r     = f_dn_l.result(), f_dn_r.result()
        dn_srv         = f_dn_srv.result()
    return jsonify({
        "success": True,
        "sepp-sepp": {"delay": sepp_l or sepp_r, "vsepp": sepp_l, "hsepp": sepp_r},
        "upf-upf":   {"delay": upf_l or upf_r,   "vupf": upf_l,   "hupf": upf_r},
        "hsmf-hupf": {"delay": smf_r or hupf_r,  "hsmf": smf_r,   "hupf": hupf_r},
        "upfs-dn":   {"delay": dn_l or dn_r or dn_srv, "vupf": dn_l, "hupf": dn_r, "dn": dn_srv},
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
        r1 = set_upf_dn_delay("local", delay)
        r2 = set_upf_dn_delay("remote", delay)
        r3 = set_dn_server_delay(delay)
        return jsonify(_combine_delay_results("UPFs-DN (N6)", delay, [("vUPF", r1), ("hUPF", r2), ("DN", r3)]))
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
        remove_dn_server_delay()
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
                stat = os.stat(path)
                summary = ""
                try:
                    with open(path) as fh:
                        for line in fh:
                            line = line.strip()
                            if line.startswith("ROAMING_MODE="):
                                summary += f"Roaming: {line.split('=')[1]} "
                            elif line.startswith("IPSEC_ENABLED="):
                                summary += f"IPsec: {line.split('=')[1]} "
                            elif line.startswith("ITERATIONS="):
                                summary += f"Iter: {line.split('=')[1]} "
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
    mode = {"security": "tls" if "_tls.yaml" in env_result.get("stdout", "") else "plain" if ".yaml" in env_result.get("stdout", "") else "unknown", "roaming": "unknown"}
    if "UPF_IMAGE" in env_result.get("stdout", ""):
        mode["roaming"] = "hr" if "hr" in env_result["stdout"].lower() else "lbo" if "lbo" in env_result["stdout"].lower() else "non-roaming"
    all_running = all(c["state"] == "running" for c in containers) if containers else False
    ipsec = check_ipsec_status_detailed(location)
    return jsonify({"status": "running" if all_running else ("partial" if containers else "stopped"), "containers": containers, "current_mode": mode, "ipsec": ipsec})


@app.route('/api/network/<location>/start', methods=['POST'])
def start_network(location):
    if location not in ["local", "remote"]:
        return jsonify({"error": "Invalid"}), 400
    data = request.get_json() or {}
    path = CONFIG[location]["path"]
    if data.get('security_mode'):
        env = generate_env_content(data['security_mode'], data.get('roaming_mode') if location == "local" else None, location == "local", include_credentials=(location == "local"))
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
# RESULTS
# ============================================================================

@app.route('/api/results', methods=['GET'])
def list_results():
    files = []
    if os.path.exists(CONFIG["results_dir"]):
        for f in sorted(os.listdir(CONFIG["results_dir"]), reverse=True):
            if f.endswith('.json'):
                path = os.path.join(CONFIG["results_dir"], f)
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
    path = os.path.join(CONFIG["results_dir"], filename)
    if not os.path.exists(path):
        return jsonify({"error": "Not found"}), 404
    with open(path) as f:
        return jsonify({"success": True, "data": json.load(f)})


@app.route('/api/results/<filename>', methods=['DELETE'])
def delete_result(filename):
    path = os.path.join(CONFIG["results_dir"], filename)
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
    metric = request.args.get('metric', '').strip()
    try:
        png, _medians = plotting.generate_plot(metric, CONFIG["results_dir"])
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
    cached = plotting.load_cached_plots(CONFIG["plots_dir"])
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
    try:
        result = plotting.generate_all_plots_to_dir(CONFIG["results_dir"], CONFIG["plots_dir"])
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
    run_local_command(f"sudo docker rm -f {pr['container']} 2>/dev/null || true")
    cleanup_packetrusher_interfaces()
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


@app.route('/api/iperf/stream')
def stream_iperf():
    ue_ip = request.args.get('ue_ip')
    vrf = request.args.get('vrf')
    server_ip = request.args.get('server_ip', PERF_SERVER_IP)
    server_port = request.args.get('server_port', '5201')
    duration = min(int(request.args.get('duration', 10)), 120)
    reverse = request.args.get('reverse', 'false') == 'true'
    udp = request.args.get('udp', 'false') == 'true'
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
            intervals = iperf_data.get('intervals', [])
            for idx, interval in enumerate(intervals):
                streams = interval.get('streams', [{}])
                summary = interval.get('sum', streams[0] if streams else {})
                bits_per_second = summary.get('bits_per_second', 0)
                bytes_transferred = summary.get('bytes', 0)
                retransmits = summary.get('retransmits', 0)
                start = summary.get('start', idx)
                end = summary.get('end', idx + 1)
                interval_data = {'type': 'interval', 'index': idx, 'total_intervals': len(intervals), 'start': start, 'end': end,
                                 'bits_per_second': bits_per_second, 'mbps': round(bits_per_second / 1e6, 2),
                                 'bytes': bytes_transferred, 'retransmits': retransmits}
                if udp:
                    interval_data['jitter_ms'] = summary.get('jitter_ms', 0)
                    interval_data['lost_packets'] = summary.get('lost_packets', 0)
                    interval_data['packets'] = summary.get('packets', 0)
                yield f"data: {json.dumps(interval_data)}\n\n"
                time.sleep(0.1)
            end_data = iperf_data.get('end', {})
            if udp:
                sum_data = end_data.get('sum', {})
                final = {'type': 'complete', 'bits_per_second': sum_data.get('bits_per_second', 0), 'mbps': round(sum_data.get('bits_per_second', 0) / 1e6, 2),
                         'bytes': sum_data.get('bytes', 0), 'jitter_ms': sum_data.get('jitter_ms', 0),
                         'lost_packets': sum_data.get('lost_packets', 0), 'lost_percent': sum_data.get('lost_percent', 0), 'packets': sum_data.get('packets', 0)}
            else:
                if reverse:
                    sum_data = end_data.get('sum_received', end_data.get('sum_sent', {}))
                else:
                    sum_data = end_data.get('sum_sent', end_data.get('sum_received', {}))
                final = {'type': 'complete', 'bits_per_second': sum_data.get('bits_per_second', 0), 'mbps': round(sum_data.get('bits_per_second', 0) / 1e6, 2),
                         'bytes': sum_data.get('bytes', 0), 'retransmits': sum_data.get('retransmits', 0)}
            yield f"data: {json.dumps(final)}\n\n"
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
            size_bytes = float(result.get('size_download', 0))
            speed_bps = float(result.get('speed_download', 0))
            final = {'type': 'complete', 'size_bytes': size_bytes, 'size_mb': round(size_bytes / 1048576, 2),
                     'speed_bytes_sec': speed_bps, 'speed_mbps': round(speed_bps * 8 / 1e6, 2),
                     'speed_mb_sec': round(speed_bps / 1048576, 2),
                     'time_dns': float(result.get('time_namelookup', 0)),
                     'time_connect': float(result.get('time_connect', 0)),
                     'time_tls': float(result.get('time_appconnect', 0)),
                     'time_ttfb': float(result.get('time_starttransfer', 0)),
                     'time_total': float(result.get('time_total', 0)),
                     'http_code': http_code, 'remote_ip': result.get('remote_ip', '')}
            yield f"data: {json.dumps(final)}\n\n"
        except Exception as e:
            yield f"data: {json.dumps({'type': 'error', 'message': str(e)})}\n\n"
    return Response(generate(), mimetype='text/event-stream', headers={'Cache-Control': 'no-cache', 'Connection': 'keep-alive', 'X-Accel-Buffering': 'no'})


# ============================================================================
# WEBPAGE LOAD TEST (Browsertime)
# ============================================================================

WEBPAGE_PRESET_URLS = [
    {"label": "YouTube",   "url": "https://www.youtube.com/@Cristiano"},
    {"label": "Instagram", "url": "https://www.instagram.com/leomessi/"},
    {"label": "Facebook",  "url": "https://www.facebook.com/DonaldTrump/"},
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
            # line and the automation script's real-world output). fullyLoaded is a
            # network-idle metric that inflates to 10s+ on pages with background
            # traffic, so it's only a fallback when pageLoadTime is unavailable.
            page_load = (pt.get('pageLoadTime', {}).get('median') or
                         s.get('fullyLoaded', {}).get('median') or 0)
            # Total Time = fullyLoaded (navigation start → network fully idle):
            # the whole page-load span from first step to last. Falls back to
            # pageLoadTime when fullyLoaded isn't recorded.
            total_time = (s.get('fullyLoaded', {}).get('median') or
                          pt.get('pageLoadTime', {}).get('median') or 0)

            if not any([ttfb, fcp, lcp, dcl, page_load, total_time]):
                yield f"data: {json.dumps({'type':'error','message':'No timing data — page did not finish loading through the tunnel'})}\n\n"
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


@socketio.on('connect')
def on_connect():
    job = script_job_manager.get_current_job()
    if job:
        emit('script_status', job)
    emit('connected', {'status': 'connected'})


@socketio.on('get_script_status')
def on_get_script_status():
    job = script_job_manager.get_current_job()
    emit('script_status', job)


@socketio.on('get_script_output')
def on_get_script_output(data=None):
    n = (data or {}).get('lines', 200)
    lines = script_job_manager.get_recent_output(n)
    emit('script_output_batch', {'lines': lines})


if __name__ == '__main__':
    print("=" * 60)
    print(" Open5GS Testbed API v2.2")
    print("=" * 60)
    print(f" Automation script:  {CONFIG['automation_script']}")
    print(f" Batch runner:       {CONFIG['batch_runner_script']}")
    print(f" ESP config script:  {CONFIG['esp_config_script']}")
    if not os.path.isfile(CONFIG['esp_config_script']):
        print("   ⚠️  esp_config.sh NOT FOUND — IPsec cipher selection will fail.")
        print("   Tried:")
        for p in CONFIG['esp_config_script_candidates']:
            print(f"     - {p}")
    print(f" Configs dir:        {CONFIG['configs_dir']}")
    print(f" Results dir:        {CONFIG['results_dir']}")
    print("=" * 60)
    socketio.run(app, host='0.0.0.0', port=9090, debug=False, allow_unsafe_werkzeug=True, log_output=False)
