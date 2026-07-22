#!/usr/bin/env bash

# ============================================================================
# Open5GS Roaming Testbed Web UI - Startup Script
# ============================================================================

set -e

# ── Never run the WebUI backend as root ──────────────────────────────────────
# The backend shells out to the batch runner / automation, which SSH into the
# HPLMN and performance servers using the invoking user's keys, known_hosts and
# docker-group membership. If the backend runs as root (e.g. `sudo ./start.sh`),
# those SSH calls use /root/.ssh instead and the batch preflight fails with
# "Performance server SSH check failed". Re-exec as the real user when launched
# under sudo; refuse a bare root login (no user to fall back to).
if [ "$(id -u)" -eq 0 ]; then
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        echo "start.sh: launched as root — re-executing as '$SUDO_USER' (the WebUI must not run as root)."
        exec sudo -u "$SUDO_USER" -H bash "$0" "$@"
    fi
    echo "ERROR: Do not run the WebUI as root."
    echo "Run it as your normal user — the one whose SSH keys reach the HPLMN and"
    echo "performance servers, and who is in the 'docker' group:"
    echo "    ./start.sh"
    echo "It calls sudo itself only for the few privileged steps (freeing ports)."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$SCRIPT_DIR/backend"
FRONTEND_DIR="$SCRIPT_DIR/frontend"

# ── Read configuration from backend/app.py (set by setup.sh) ──
HPLMN_IP=$(grep -oP '^HPLMN_IP\s*=\s*"\K[^"]+' "$BACKEND_DIR/app.py" 2>/dev/null || echo "")
_raw_user=$(grep -oP '^HPLMN_USER\s*=\s*"\K[^"]+' "$BACKEND_DIR/app.py" 2>/dev/null)
HPLMN_USER="${_raw_user:-$(whoami)}"
unset _raw_user

PERF_SERVER_IP=$(grep -oP '^PERF_SERVER_IP\s*=\s*"\K[^"]+' "$BACKEND_DIR/app.py" 2>/dev/null || echo "")
_raw_puser=$(grep -oP '^PERF_SERVER_USER\s*=\s*"\K[^"]+' "$BACKEND_DIR/app.py" 2>/dev/null)
PERF_SERVER_USER="${_raw_puser:-$(whoami)}"
unset _raw_puser

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log() {
    echo -e "${CYAN}[$(date +'%H:%M:%S')]${NC} $*"
}

success() {
    echo -e "${GREEN}✓${NC} $*"
}

error() {
    echo -e "${RED}✗${NC} $*"
}

warn() {
    echo -e "${YELLOW}!${NC} $*"
}

# ============================================================================
# Check Dependencies
# ============================================================================

check_dependencies() {
    log "Checking dependencies..."
    
    local missing=()
    
    if ! command -v python3 &> /dev/null; then missing+=("python3"); fi
    if ! command -v pip3 &> /dev/null; then missing+=("pip3"); fi
    if ! command -v docker &> /dev/null; then missing+=("docker"); fi
    if ! command -v ssh &> /dev/null; then missing+=("ssh"); fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing dependencies: ${missing[*]}"
        echo "Please install them first:"
        echo "  sudo apt update && sudo apt install -y ${missing[*]}"
        exit 1
    fi
    
    success "All dependencies found"
}

# ============================================================================
# Setup Python Environment
# ============================================================================

setup_python() {
    log "Setting up Python environment..."
    
    cd "$BACKEND_DIR"
    
    if [ ! -f "venv/bin/activate" ]; then
        # Remove any broken/partial venv directory from a previous failed run
        if [ -d "venv" ]; then
            warn "Incomplete virtual environment detected. Removing and recreating..."
            rm -rf venv
        fi
        log "Creating virtual environment..."
        # Check if python3-venv is available before attempting to create venv
        if ! python3 -c "import ensurepip" &>/dev/null; then
            warn "python3-venv is not installed. Attempting to install it..."
            if sudo apt-get install -y python3-venv &>/dev/null; then
                success "python3-venv installed successfully"
            else
                error "Failed to install python3-venv automatically."
                echo ""
                echo "Please run the following command manually, then retry:"
                echo "  sudo apt install python3-venv"
                exit 1
            fi
        fi
        python3 -m venv venv
    fi
    
    source venv/bin/activate

    # Offline-friendly fast path: if the venv already satisfies requirements.txt,
    # skip pip entirely (pip needs internet and can hang on offline networks).
    # Only (re)install when something is actually missing.
    #
    # The check reads requirements.txt rather than testing a fixed list of
    # imports, so it cannot drift as dependencies are added. It used to import
    # only flask and flask_socketio: a venv created before matplotlib/numpy were
    # added still imported flask fine, so this reported success, skipped the
    # install, and left the Plots tab dead with "No module named 'numpy'".
    #
    # Package metadata is queried instead of importing the modules — importing
    # matplotlib can spend 10+ s building its font cache on first run, which a
    # short timeout would misread as "missing" on every cold start.
    log "Verifying dependencies..."
    missing_deps=$(timeout 15 python3 - <<'PY' 2>/dev/null
import importlib.metadata as md, re
missing = []
try:
    lines = open("requirements.txt")
except OSError:
    raise SystemExit(0)          # no requirements file → nothing to verify
for line in lines:
    line = line.split("#")[0].strip()
    if not line:
        continue
    name = re.split(r"[<>=!~\[;]", line)[0].strip()
    if not name:
        continue
    try:
        md.version(name)
    except md.PackageNotFoundError:
        missing.append(name)
print(" ".join(missing))
PY
)
    probe_rc=$?

    if [ "$probe_rc" -eq 0 ] && [ -z "$missing_deps" ]; then
        success "Dependencies verified"
    else
        if [ -n "$missing_deps" ]; then
            log "Missing package(s): $missing_deps"
        else
            log "Could not verify installed packages — reinstalling to be safe"
        fi
        log "Installing Python dependencies (this requires internet)..."
        pip install -q --upgrade pip 2>/dev/null || true
        pip install -q -r requirements.txt || {
            warn "Could not install dependencies (no internet?). Using venv as-is..."
            warn "The Plots tab needs matplotlib and numpy; it will be disabled without them."
        }
    fi

    success "Python environment ready"
}

# ============================================================================
# Test SSH Connection
# ============================================================================

# Probe SSH to a host and classify the failure.
#
# The checks run with BatchMode=yes, which means ssh cannot prompt "accept this
# host key?". So a host that is up, reachable and has our key installed still
# fails on the *first* connection with "Host key verification failed" — nothing
# to do with authentication. Record the key on first sight (fingerprint printed
# so it can be verified) and retry, rather than telling the operator to run
# ssh-copy-id, which does not address that failure at all.
#
# A key that has *changed* is never auto-accepted: that is either a genuine
# rebuild or a man-in-the-middle, and only a human can tell the difference.
#
# Echoes: 0 = OK, 1 = auth failed, 2 = unreachable, 3 = host key changed
ssh_probe() {
    local user="$1" host="$2" out

    out=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "${user}@${host}" "echo SSH_OK" 2>&1) && return 0

    if grep -qi "REMOTE HOST IDENTIFICATION HAS CHANGED" <<< "$out"; then
        return 3
    fi

    if grep -qi "host key verification failed" <<< "$out"; then
        log "First connection to ${host} — recording host key:"
        ssh-keyscan -T 5 "$host" 2>/dev/null | ssh-keygen -lf - 2>/dev/null | sed 's/^/     /' || true
        ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            "${user}@${host}" "echo SSH_OK" &> /dev/null && return 0
        out=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "${user}@${host}" "echo SSH_OK" 2>&1) || true
    fi

    grep -qi "permission denied\|no supported authentication\|publickey" <<< "$out" && return 1
    return 2
}

# Report a failed probe with advice that matches the actual cause.
ssh_advice() {
    local rc="$1" user="$2" host="$3"
    case "$rc" in
        1)
            echo ""
            echo "Your SSH key is not authorized on ${host}. Run (as $(whoami), not root):"
            echo "  ssh-keygen -t ed25519   # only if you have no key yet"
            echo "  ssh-copy-id ${user}@${host}"
            ;;
        2)
            echo ""
            echo "${host} is not reachable over SSH. Check that the host is powered on,"
            echo "on the same network, and running sshd (systemctl status ssh)."
            ;;
        3)
            echo ""
            echo "WARNING: the host key for ${host} has CHANGED since it was recorded."
            echo "This is expected if that PC was reinstalled — but it also looks exactly"
            echo "like a man-in-the-middle attack, so it is not accepted automatically."
            echo "If (and only if) you know the host was rebuilt, run:"
            echo "  ssh-keygen -R ${host}"
            echo "then start.sh will record the new key on the next run."
            ;;
    esac
}

test_ssh() {
    local rc

    log "Testing SSH connection to remote PC ($HPLMN_IP)..."
    rc=0; ssh_probe "$HPLMN_USER" "$HPLMN_IP" || rc=$?
    if [ "$rc" -eq 0 ]; then
        success "SSH connection to remote PC successful"
    else
        warn "Cannot connect to remote PC via SSH"
        ssh_advice "$rc" "$HPLMN_USER" "$HPLMN_IP"
        echo ""
        echo "The web UI will still work, but remote network control will fail."
    fi

    # Performance server: required for N6 delay and iperf/download/video tests,
    # so the batch runner's preflight hard-fails if this SSH doesn't work.
    if [ -n "$PERF_SERVER_IP" ]; then
        log "Testing SSH connection to performance server ($PERF_SERVER_IP)..."
        rc=0; ssh_probe "$PERF_SERVER_USER" "$PERF_SERVER_IP" || rc=$?
        if [ "$rc" -eq 0 ]; then
            success "SSH connection to performance server successful"
        else
            warn "Cannot connect to performance server via SSH"
            ssh_advice "$rc" "$PERF_SERVER_USER" "$PERF_SERVER_IP"
            echo ""
            echo "Until this works, batch runs that use N6 delay will fail preflight"
            echo "(\"Performance server SSH check failed\") on every config."
        fi
    fi
}

# ============================================================================
# Force Kill Ports - NEW FUNCTION
# ============================================================================

force_kill_ports() {
    log "Ensuring ports 9090 and 9091 are free..."
    
    # Kill anything on port 9090
    if sudo fuser 9090/tcp &>/dev/null; then
        sudo fuser -k 9090/tcp &>/dev/null || true
        sleep 1
    fi
    
    # Kill anything on port 9091
    if sudo fuser 9091/tcp &>/dev/null; then
        sudo fuser -k 9091/tcp &>/dev/null || true
        sleep 1
    fi
    
    # Also kill by process name as backup
    pkill -9 -f "python.*app.py" 2>/dev/null || true
    pkill -9 -f "serve.py" 2>/dev/null || true
    pkill -9 -f "http.server 9091" 2>/dev/null || true
    
    sleep 1
    success "Ports cleared"
}

# ============================================================================
# Start Services
# ============================================================================

start_backend() {
    log "Starting backend server..."
    
    cd "$BACKEND_DIR"
    local backend_python="$BACKEND_DIR/venv/bin/python3"
    if [ ! -x "$backend_python" ]; then
        backend_python="$BACKEND_DIR/venv/bin/python"
    fi
    if [ ! -x "$backend_python" ]; then
        error "Python virtual environment is missing or incomplete."
        echo "Run './start.sh start' again so it can recreate backend/venv."
        exit 1
    fi
    
    # Start backend in background
    nohup "$backend_python" app.py > "$SCRIPT_DIR/logs/backend.log" 2>&1 &
    BACKEND_PID=$!
    
    # Wait for backend to start
    sleep 3
    
    # Verify it's actually listening on port 9090
    if ss -tln 2>/dev/null | grep -q ":9090"; then
        success "Backend started (PID: $BACKEND_PID)"
        echo "   API: http://localhost:9090"
    else
        error "Failed to start backend. Check logs/backend.log"
        cat "$SCRIPT_DIR/logs/backend.log"
        exit 1
    fi
}

start_frontend() {
    log "Starting frontend server..."
    
    cd "$FRONTEND_DIR"
    
    # Use serve.py with no-cache headers if available, otherwise fallback
    if [ -f "serve.py" ]; then
        nohup python3 serve.py 9091 > "$SCRIPT_DIR/logs/frontend.log" 2>&1 &
    else
        nohup python3 -m http.server 9091 > "$SCRIPT_DIR/logs/frontend.log" 2>&1 &
    fi
    FRONTEND_PID=$!
    
    sleep 2
    
    # Verify it's actually listening on port 9091
    if ss -tln 2>/dev/null | grep -q ":9091"; then
        success "Frontend started (PID: $FRONTEND_PID)"
        echo "   UI: http://localhost:9091"
    else
        error "Failed to start frontend. Check logs/frontend.log"
        cat "$SCRIPT_DIR/logs/frontend.log"
        exit 1
    fi
}

# ============================================================================
# Stop Services
# ============================================================================

stop_all() {
    log "Stopping all services..."
    
    # Kill by process name
    pkill -9 -f "python.*app.py" 2>/dev/null && success "Backend stopped" || warn "Backend not running"
    pkill -9 -f "serve.py" 2>/dev/null && success "Frontend stopped" || pkill -9 -f "http.server 9091" 2>/dev/null && success "Frontend stopped" || warn "Frontend not running"
    
    # Force kill ports as backup
    sudo fuser -k 9090/tcp 2>/dev/null || true
    sudo fuser -k 9091/tcp 2>/dev/null || true
    
    sleep 1
    success "All services stopped"
}

# ============================================================================
# Show Status
# ============================================================================

show_status() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Open5GS Roaming Testbed - Web UI Status"
    echo "═══════════════════════════════════════════════════════════════"
    
    # Backend status - check by port
    if ss -tln 2>/dev/null | grep -q ":9090"; then
        echo -e "  Backend:  ${GREEN}Running${NC}  │  http://localhost:9090"
    else
        echo -e "  Backend:  ${RED}Stopped${NC}"
    fi
    
    # Frontend status - check by port
    if ss -tln 2>/dev/null | grep -q ":9091"; then
        echo -e "  Frontend: ${GREEN}Running${NC}  │  http://localhost:9091"
    else
        echo -e "  Frontend: ${RED}Stopped${NC}"
    fi
    
    # SSH status
    if ssh -o ConnectTimeout=2 -o BatchMode=yes ${HPLMN_USER}@${HPLMN_IP} "exit" &> /dev/null; then
        echo -e "  SSH:      ${GREEN}Connected${NC} to $HPLMN_IP"
    else
        echo -e "  SSH:      ${RED}Not connected${NC}"
    fi
    
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
}

# ============================================================================
# Main
# ============================================================================

main() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║     Open5GS Roaming Testbed - Web UI                         ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Create logs directory
    mkdir -p "$SCRIPT_DIR/logs"
    
    case "${1:-start}" in
        start)
            check_dependencies
            setup_python
            test_ssh
            force_kill_ports  # Always clean ports before starting
            start_backend
            start_frontend
            show_status
            echo ""
            echo "Open the Web UI in your browser: http://localhost:9091"
            echo ""
            echo "Press Ctrl+C to view logs, or run: $0 stop"
            ;;
        stop)
            stop_all
            ;;
        restart)
            stop_all
            sleep 2
            main start
            ;;
        status)
            show_status
            ;;
        logs)
            echo "Backend logs:"
            tail -50 "$SCRIPT_DIR/logs/backend.log" 2>/dev/null || echo "No backend logs"
            echo ""
            echo "Frontend logs:"
            tail -50 "$SCRIPT_DIR/logs/frontend.log" 2>/dev/null || echo "No frontend logs"
            ;;
        *)
            echo "Usage: $0 {start|stop|restart|status|logs}"
            exit 1
            ;;
    esac
}

main "$@"
