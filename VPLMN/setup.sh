#!/bin/bash

# ==============================================================================
# VPLMN (Visited PLMN - PC1) — Automated Setup Script
# ==============================================================================
# Automates the complete initialization of the VPLMN testbed from scratch
# Covers IP configuration, binary preparation, Docker image builds,
# and network setup.
#
# Usage:
#   ./setup.sh
#
# Or run from project root:
#   ./VPLMN/setup.sh
#
# This script must be run from within the VPLMN directory or called
# from the parent directory.
# ==============================================================================

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Determine script directory and ensure we're in the VPLMN directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPLMN_DIR="$SCRIPT_DIR"

# Check if we're in the correct directory
if [ ! -f "$VPLMN_DIR/docker-compose.yml" ]; then
    echo -e "${RED}ERROR: docker-compose.yml not found at $VPLMN_DIR${NC}"
    echo -e "${YELLOW}This script must be run from the VPLMN directory or called as:${NC}"
    echo -e "${BLUE}  ./VPLMN/setup.sh${NC}"
    exit 1
fi

# ── Ensure the project directory is named LKN_5G_Roaming_Testbed ──────────────
# The GitLab repo is 'roamingtb_main', so `git clone` lands in ~/roamingtb_main,
# but many scripts and the docs hardcode the path ~/LKN_5G_Roaming_Testbed. If
# the project root has any other name, rename it once and re-exec setup from the
# corrected path so every later step sees the expected layout.
ensure_project_dir_name() {
    local root parent target sub
    root="$(cd "$SCRIPT_DIR/.." && pwd)"          # parent of VPLMN/ = project root
    if [ "$(basename "$root")" = "LKN_5G_Roaming_Testbed" ]; then
        return 0
    fi
    parent="$(dirname "$root")"
    target="$parent/LKN_5G_Roaming_Testbed"
    sub="$(basename "$SCRIPT_DIR")"               # VPLMN (or HPLMN)
    if [ -e "$target" ]; then
        echo -e "${RED}ERROR:${NC} project is in '$(basename "$root")' but '$target' already exists."
        echo    "The testbed must live at $target (scripts and docs hardcode that path)."
        echo    "Move or remove the existing directory, then re-run setup."
        exit 1
    fi
    echo -e "${YELLOW}Renaming project directory to the expected name:${NC}"
    echo    "  $root"
    echo    "  -> $target"
    if ! mv "$root" "$target"; then
        echo -e "${RED}ERROR:${NC} could not rename '$root' -> '$target'."
        exit 1
    fi
    echo -e "${GREEN}Re-running setup from the new location...${NC}"
    exec "$target/$sub/setup.sh" "$@"
}
ensure_project_dir_name "$@"

# Script configuration
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="$VPLMN_DIR/setup_logs"
LOG_FILE="${LOG_DIR}/setup_${TIMESTAMP}.log"

# ── Reclaim ownership of the project's own files ─────────────────────────────
# setup.sh is meant to run as a normal user (it calls sudo itself where needed).
# A clone made as root, or an earlier `sudo ./setup.sh`, leaves the project files
# owned by root, and the run then fails in confusing ways: every log line becomes
# "Permission denied", and give_permissions.sh reports "chmod: Operation not
# permitted" for each script.
#
# Only the project's *own* files are reclaimed: git-tracked files plus setup_logs.
# Container output (pq-ike-docker/results, conf/…) is root-owned by design —
# Docker runs as root — so it is deliberately left alone; chowning it would fire
# on every run of a healthy machine.
reclaim_project_ownership() {
    [ "$(id -u)" -eq 0 ] && return 0

    local me grp foreign
    me="$(id -un)"; grp="$(id -gn)"

    if git -C "$VPLMN_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
        # stat, not `xargs find`: xargs appends the file list, but find requires
        # paths before the expression, so `xargs find ! -user X` never works.
        foreign="$( (cd "$VPLMN_DIR" && git ls-files -z 2>/dev/null \
                    | xargs -0 -r stat -c '%U|%n' 2>/dev/null \
                    | awk -F'|' -v u="$me" '$1 != u { print $2; exit }') 2>/dev/null || true)"
    else
        # Not a git checkout (e.g. extracted tarball): fall back to the scripts,
        # which are what give_permissions.sh must chmod.
        foreign="$(find "$VPLMN_DIR" -name '*.sh' ! -user "$me" -print -quit 2>/dev/null || true)"
    fi
    [ -d "$LOG_DIR" ] && [ ! -O "$LOG_DIR" ] && foreign="${foreign:-$LOG_DIR}"

    [ -z "$foreign" ] && return 0

    echo "Project files under $VPLMN_DIR are not owned by '$me' (e.g. $foreign)."
    echo "That happens after a root clone or a 'sudo ./setup.sh'. Reclaiming ownership..."

    local ok=1
    if git -C "$VPLMN_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
        (cd "$VPLMN_DIR" && git ls-files -z 2>/dev/null \
            | while IFS= read -r -d '' path; do
                [ -e "$path" ] && printf '%s\0' "$path"
            done \
            | xargs -0 -r sudo chown "$me:$grp") || ok=0
    else
        find "$VPLMN_DIR" -name '*.sh' -print0 2>/dev/null \
            | xargs -0 -r sudo chown "$me:$grp" || ok=0
    fi
    if [ -d "$LOG_DIR" ]; then
        sudo chown -R "$me:$grp" "$LOG_DIR" 2>/dev/null || ok=0
    fi

    if [ "$ok" -eq 1 ]; then
        echo "Ownership reclaimed."
    else
        echo "WARNING: could not reclaim ownership (sudo unavailable or refused)."
        echo "Setup will likely fail. Fix it with:"
        echo "  sudo chown -R $me:$grp $VPLMN_DIR"
    fi
    echo ""
}
reclaim_project_ownership

# Under sudo, $HOME becomes /root, but the Open5GS source build and the shell
# profile belong to the invoking user. Resolve that user's home explicitly.
if [ -n "$SUDO_USER" ]; then
    REAL_USER="$SUDO_USER"
    REAL_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
    REAL_USER="${USER:-$(id -un)}"
    REAL_HOME="$HOME"
fi

OPEN5GS_DIR="${OPEN5GS_DIR:-$REAL_HOME/open5gs}"
OPEN5GS_INSTALL="$OPEN5GS_DIR/install"

# Run a command as the invoking user, so files landing in their home stay
# owned by them even when this script is started with sudo.
run_as_real_user() {
    if [ "$(id -u)" -eq 0 ] && [ -n "$SUDO_USER" ]; then
        sudo -u "$REAL_USER" -H "$@"
    else
        "$@"
    fi
}

# Append a line to the invoking user's ~/.profile, once.
append_profile() {
    local line="$1"
    local profile="$REAL_HOME/.profile"
    grep -qxF "$line" "$profile" 2>/dev/null && return 0
    run_as_real_user tee -a "$profile" > /dev/null <<< "$line"
}

# A populated install/ directory is not proof of a usable build: an interrupted
# `ninja install` leaves the tree behind. Require the daemons themselves.
open5gs_installed() {
    [ -x "$OPEN5GS_INSTALL/bin/open5gs-amfd" ] && \
    [ -x "$OPEN5GS_INSTALL/bin/open5gs-upfd" ] && \
    [ -x "$OPEN5GS_INSTALL/bin/open5gs-smfd" ]
}

# Create log directory. If it is not writable (e.g. ownership repair above could
# not run because sudo was unavailable), fall back to a temp file rather than
# emitting a "Permission denied" for every single line the script prints.
mkdir -p "$LOG_DIR" 2>/dev/null || true
if ! { : >> "$LOG_FILE"; } 2>/dev/null; then
    LOG_FILE="$(mktemp -t vplmn_setup_XXXXXX.log)"
    echo "NOTE: $LOG_DIR is not writable — logging to $LOG_FILE instead."
    echo ""
fi

# Logging function
log() {
    echo -e "$1"
    # The redirection must be grouped: with `>> "$LOG_FILE" 2>/dev/null`, bash
    # opens the file (and prints its own "Permission denied") *before* applying
    # 2>/dev/null, so the error still reaches the terminal.
    { echo -e "$1" >> "$LOG_FILE"; } 2>/dev/null || true
}

log_step() {
    log "${CYAN}===================================================${NC}"
    log "${GREEN}[STEP] $1${NC}"
    log "${CYAN}===================================================${NC}"
}

log_success() {
    log "${GREEN}✓ $1${NC}"
}

log_error() {
    log "${RED}✗ ERROR: $1${NC}"
}

log_warning() {
    log "${YELLOW}⚠ WARNING: $1${NC}"
}

# Validation function
check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "$1 not found. Please install it before proceeding."
        return 1
    fi
    return 0
}

# ── Docker invocation: sudo only when necessary ──────────────────────────────
# On a fresh VM, setup installs Docker and adds the user to the 'docker' group,
# but that membership is not active in the current shell — so plain `docker`
# fails with "permission denied ... /var/run/docker.sock". Always using sudo is
# wrong (breaks rootless Docker and leaves images owned oddly); never using it
# breaks the fresh-VM first run. So detect what actually works and use that.
DOCKER_SUDO=""
detect_docker_sudo() {
    if docker info &>/dev/null 2>&1; then
        DOCKER_SUDO=""
    elif sudo docker info &>/dev/null 2>&1; then
        DOCKER_SUDO="sudo"
        log_warning "Docker isn't usable without sudo in this shell yet."
        log "That's expected right after a fresh install — you were added to the"
        log "'docker' group, but it only takes effect on your next login."
        log "Using sudo for Docker steps so setup can finish now. To use Docker"
        log "without sudo afterwards, log out and back in (or run: newgrp docker)."
        log ""
    else
        DOCKER_SUDO=""
        log_warning "Docker does not appear reachable with or without sudo — Docker steps may fail."
    fi
}

# ── Passwordless SSH setup + verification ────────────────────────────────────
# Configures key-based SSH from the invoking user to user@host, then VERIFIES it
# actually works. Two things this gets right that the old inline code did not:
#   1. All ssh/ssh-copy-id/ssh-keygen run as the invoking user (run_as_real_user),
#      so the key that gets authorized is the one the WebUI and automation use —
#      not root's, when setup is started with sudo.
#   2. Success is decided by a real BatchMode test afterwards, NOT by ssh-copy-id's
#      exit status through a `| tee` pipe (that pipe reports tee's status — always
#      0 — so a failed copy used to be logged as "configured").
# Returns 0 only when passwordless SSH genuinely works at the end.
setup_passwordless_ssh() {
    local user="$1" host="$2" label="$3"

    if run_as_real_user ssh -o ConnectTimeout=5 -o BatchMode=yes \
           -o StrictHostKeyChecking=accept-new "${user}@${host}" "echo ok" &>/dev/null; then
        log_success "Passwordless SSH to ${user}@${host} ($label) already works"
        return 0
    fi

    log_warning "Passwordless SSH to ${label} (${user}@${host}) not configured yet — setting it up"
    if [ ! -f "$REAL_HOME/.ssh/id_ed25519" ] && [ ! -f "$REAL_HOME/.ssh/id_rsa" ]; then
        log "Generating an SSH key for $REAL_USER..."
        if run_as_real_user ssh-keygen -t ed25519 -N "" -f "$REAL_HOME/.ssh/id_ed25519" >>"$LOG_FILE" 2>&1; then
            log_success "SSH key generated: $REAL_HOME/.ssh/id_ed25519"
        else
            log_warning "Could not generate an SSH key — skipping ${label} SSH setup"
            return 1
        fi
    fi

    log "Copying your SSH key to ${user}@${host}."
    log "Enter that account's password when prompted (one time):"
    log ""
    # No pipe into tee here on purpose — see note above.
    run_as_real_user ssh-copy-id -o StrictHostKeyChecking=accept-new "${user}@${host}" || true
    log ""

    if run_as_real_user ssh -o ConnectTimeout=5 -o BatchMode=yes \
           "${user}@${host}" "echo ok" &>/dev/null; then
        log_success "Passwordless SSH to ${user}@${host} ($label) is now configured"
        return 0
    fi
    log_warning "Passwordless SSH to ${label} still not working. Set it up manually (as $REAL_USER):"
    log "  ssh-copy-id ${user}@${host}"
    return 1
}

# ============================================================================
# PREREQUISITE INSTALLATION FUNCTIONS
# ============================================================================

install_system_packages() {
    log_step "Installing system packages and dependencies"
    
    log "Updating package manager..."
    sudo apt-get update || {
        log_error "Failed to update package manager"
        return 1
    }
    log_success "Package manager updated"
    log ""
    
    # Install Docker CE + Compose plugin (v2)
    log "Checking Docker installation..."
    if ! check_command docker; then
        log "Installing Docker CE..."
        sudo apt-get install -y ca-certificates curl gnupg lsb-release || {
            log_error "Failed to install Docker prerequisites"
            return 1
        }
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
            sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin || {
            log_error "Failed to install Docker CE"
            return 1
        }
        sudo usermod -aG docker "$USER" || {
            log_warning "Failed to add user to docker group (may need manual setup)"
        }
        log_success "Docker CE installed"
    else
        log_success "Docker already installed: $(docker --version)"
    fi
    log ""
    
    # Verify docker compose v2 plugin
    log "Checking Docker Compose v2 plugin..."
    if ! docker compose version &>/dev/null; then
        log "Installing Docker Compose plugin..."
        sudo apt-get install -y docker-compose-plugin || {
            log_error "Failed to install Docker Compose plugin"
            return 1
        }
        log_success "Docker Compose plugin installed"
    else
        log_success "Docker Compose already installed: $(docker compose version)"
    fi
    log ""
    
    # Install Open5GS build dependencies plus the runtime tools the automation
    # and batch runner require. jq and bc are checked by testbed_automation.sh's
    # preflight (`for cmd in docker ssh jq bc curl`); without jq every batch
    # config aborts immediately with "❌ Missing: jq". curl/git come in above
    # with Docker, but jq/bc are otherwise unlisted, so pin them here.
    # strongSwan is included here (not only a build dep) so `ipsec` is on PATH
    # before Step 11's setup_sudoers.sh runs — that script resolves command paths
    # at runtime and silently omits ipsec from the passwordless-sudo grant if it
    # isn't installed yet, which breaks `sudo ipsec` (N9 HR tunnel) in the
    # automation/WebUI and the deploy_ipsec.sh status checks.
    # sshpass and tshark are needed by the commercial-RAN dongle scripts
    # (lib/dsk; checked by dsk_preflight in lib/automation/dsk.sh). tshark's
    # debconf question (non-root capture) is answered "no" via noninteractive —
    # the batch runs it through sudo anyway.
    log "Installing Open5GS build dependencies and automation runtime tools..."
    local deps="python3-pip python3-setuptools python3-wheel ninja-build \
      build-essential flex bison git cmake libsctp-dev libgnutls28-dev \
      libgcrypt-dev libssl-dev libmongoc-dev libbson-dev libyaml-dev \
      libnghttp2-dev libmicrohttpd-dev libcurl4-gnutls-dev \
      libtins-dev libtalloc-dev meson libidn11-dev jq bc \
      strongswan strongswan-pki strongswan-starter sshpass tshark"

    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $deps || {
        log_error "Failed to install Open5GS build dependencies"
        return 1
    }
    log_success "Open5GS build dependencies installed"
    log ""
    
    log_success "All system packages installed ✓"
    return 0
}

build_open5gs_from_source() {
    log_step "Building Open5GS v2.8.0 from source"
    
    if open5gs_installed; then
        log_success "Open5GS already built at $OPEN5GS_INSTALL"
        return 0
    fi

    if [ ! -d "$OPEN5GS_DIR" ]; then
        log "Cloning Open5GS repository..."
        cd "$(dirname "$OPEN5GS_DIR")" || return 1
        git clone https://github.com/open5gs/open5gs "$(basename "$OPEN5GS_DIR")" || {
            log_error "Failed to clone Open5GS repository"
            return 1
        }
        log_success "Repository cloned"
        log ""
    else
        log_warning "Open5GS directory already exists at $OPEN5GS_DIR (skipping clone)"
    fi

    cd "$OPEN5GS_DIR" || return 1
    log "Fetching latest refs and checking out Open5GS v2.8.0..."
    git fetch origin --tags || {
        log_error "Failed to fetch from origin"
        return 1
    }
    git checkout v2.8.0 || {
        log_error "Failed to checkout Open5GS v2.8.0"
        return 1
    }
    log_success "Open5GS v2.8.0 checked out"
    log ""
    
    if [ ! -f "$OPEN5GS_DIR/build/build.ninja" ]; then
        log "Configuring Open5GS with meson..."
        meson build --prefix="$OPEN5GS_INSTALL" || {
            log_error "Meson configuration failed"
            return 1
        }
        log_success "Meson configuration complete"
    else
        log_warning "Build directory already configured (skipping meson configuration)"
    fi
    log ""
    
    log "Compiling with ninja (this may take 5-10 minutes)..."
    ninja -C build || {
        log_error "Ninja build failed"
        return 1
    }
    log_success "Compilation complete"
    log ""
    
    log "Installing Open5GS..."
    ninja -C build install || {
        log_error "Installation failed"
        return 1
    }
    log_success "Open5GS installed at $OPEN5GS_INSTALL"
    log ""
    
    cd "$VPLMN_DIR" || return 1
    return 0
}

# ============================================================================
# PREREQUISITE CHECKS
# ============================================================================

verify_prerequisites() {
    log_step "Verifying and Installing Prerequisites"
    log ""
    
    # Check if we need to install anything
    local need_docker=0
    local need_docker_compose=0
    local need_open5gs=0
    
    log "Checking for required tools..."
    log ""
    
    if ! check_command docker; then
        need_docker=1
    else
        log_success "Docker: $(docker --version)"
    fi
    
    if ! docker compose version &>/dev/null; then
        need_docker_compose=1
    else
        log_success "Docker Compose: $(docker compose version)"
    fi
    
    if ! open5gs_installed; then
        need_open5gs=1
    else
        log_success "Open5GS installation: Found at $OPEN5GS_INSTALL"
    fi
    
    # If anything is missing, offer to install
    if [ $need_docker -eq 1 ] || [ $need_docker_compose -eq 1 ] || [ $need_open5gs -eq 1 ]; then
        log ""
        log_warning "Some prerequisites are missing. They need to be installed."
        log ""
        log "The following will be installed:"
        [ $need_docker -eq 1 ] && log "  - Docker"
        [ $need_docker_compose -eq 1 ] && log "  - Docker Compose v2"
        [ $need_open5gs -eq 1 ] && log "  - Open5GS v2.8.0 (will take 10-20 minutes)"
        log ""
        read -p "Proceed with automatic installation? (y/N) " -r confirm
        echo
        if [[ ! $confirm =~ ^[Yy]$ ]]; then
            log_error "Setup aborted by user"
            return 1
        fi
        
        # Install system packages
        if [ $need_docker -eq 1 ] || [ $need_docker_compose -eq 1 ] || [ $need_open5gs -eq 1 ]; then
            if ! install_system_packages; then
                log_error "Failed to install system packages"
                return 1
            fi
        fi
        
        # Build Open5GS
        if [ $need_open5gs -eq 1 ]; then
            if ! build_open5gs_from_source; then
                log_error "Failed to build Open5GS"
                return 1
            fi
        fi
        
        log ""
        log_success "All prerequisites installed successfully ✓"
    else
        log_success "Docker: $(docker --version)"
        log_success "Docker Compose: $(docker compose version)"
        log_success "Open5GS installation: Found at $OPEN5GS_INSTALL"
        log ""
        log_success "All prerequisites already installed ✓"
    fi
    
    # Check for sudo access
    log ""
    if ! sudo -n true 2>/dev/null; then
        log_warning "Sudo access requires authentication"
        log "You may be prompted for a password during network and Docker setup"
    else
        log_success "Sudo access: Available (no password required)"
    fi
    
    # Check required project files
    log ""
    local req_files_ok=0
    if [ ! -f "docker-compose.yml" ]; then
        log_error "docker-compose.yml not found"
        req_files_ok=1
    else
        log_success "docker-compose.yml: Found"
    fi
    
    if [ ! -d "lib/setup" ]; then
        log_error "lib/setup/ directory not found"
        req_files_ok=1
    else
        log_success "lib/setup/ directory: Found"
    fi
    
    if [ $req_files_ok -eq 1 ]; then
        return 1
    fi
    
    log ""
    log_success "All prerequisites verified ✓"
    return 0
}

# ============================================================================
# SETUP FUNCTIONS
# ============================================================================

setup_vplmn() {
    log_step "Setting Up VPLMN (Visited PLMN - PC1)"
    
    cd "$VPLMN_DIR" || return 1
    
    # Step 1: Set script permissions
    log_step "Step 1: Setting script permissions"
    if [ -f "lib/setup/give_permissions.sh" ]; then
        chmod +x lib/setup/give_permissions.sh
        bash lib/setup/give_permissions.sh || {
            log_error "Failed to set script permissions"
            return 1
        }
        log_success "Script permissions set"
    else
        log_warning "give_permissions.sh not found in lib/setup/, setting permissions manually"
        find . -name "*.sh" -type f -exec chmod +x {} \; 2>/dev/null
        log_success "Script permissions set (manual)"
    fi
    
    # Step 1.5: Install git post-merge hook
    log_step "Step 1.5: Installing git post-merge hook"
    GIT_DIR=$(git -C "$VPLMN_DIR" rev-parse --git-dir 2>/dev/null)
    if [ -z "$GIT_DIR" ]; then
        log_warning "Not a git repository — skipping hook installation"
    else
        REPO_ROOT=$(git -C "$VPLMN_DIR" rev-parse --show-toplevel)
        CONFIGURE_REL=$(realpath --relative-to="$REPO_ROOT" "$VPLMN_DIR/lib/setup/configure_ip_from_env.sh")
        ENV_REL=$(realpath --relative-to="$REPO_ROOT" "$VPLMN_DIR/.env")
        ENV_TEMPLATE_REL=$(realpath --relative-to="$REPO_ROOT" "$VPLMN_DIR/lib/setup/.env.template")
        # GIT_DIR may be relative; resolve it from VPLMN_DIR
        [[ "$GIT_DIR" != /* ]] && GIT_DIR="$VPLMN_DIR/$GIT_DIR"
        mkdir -p "$GIT_DIR/hooks"
        # Install from the versioned hook file (single source of truth).
        if cp "$VPLMN_DIR/lib/setup/post-merge.hook" "$GIT_DIR/hooks/post-merge"; then
            chmod +x "$GIT_DIR/hooks/post-merge"
            log_success "post-merge hook installed — IPs auto-update and stale Open5GS images are flagged after every git pull"
        else
            log_warning "Could not install post-merge hook (lib/setup/post-merge.hook missing?)"
        fi
    fi
    
    # Step 2: Verify and configure .env file
    log_step "Step 2: Verifying IP configuration (.env)"
    
    # If .env doesn't exist, create it interactively
    if [ ! -f ".env" ]; then
        log_warning ".env file not found"
        log ""
        log "Enter your IP addresses and credentials for this testbed:"
        read -p "  VPLMN (this PC) IP address: " vplmn_ip
        read -p "  HPLMN (other PC) IP address: " hplmn_ip
        
        if [ -z "$vplmn_ip" ] || [ -z "$hplmn_ip" ]; then
            log_error "IP addresses cannot be empty"
            return 1
        fi

        read -p "  SSH username on this PC   [${USER}]: " vplmn_user
        vplmn_user="${vplmn_user:-$USER}"
        read -p "  SSH username on HPLMN     [${USER}]: " hplmn_user
        hplmn_user="${hplmn_user:-$USER}"
        read -p "  Performance server IP     (optional, Enter to skip): " perf_server_ip
        if [ -n "$perf_server_ip" ]; then
            read -p "  Performance server user   [roaming]: " perf_server_user
            perf_server_user="${perf_server_user:-roaming}"
        fi
        
        {
            echo "VPLMN_IP=$vplmn_ip"
            echo "HPLMN_IP=$hplmn_ip"
            echo "HPLMN_USER=$hplmn_user"
            echo "VPLMN_USER=$vplmn_user"
            [ -n "$perf_server_ip" ] && echo "PERF_SERVER_IP=$perf_server_ip"
            [ -n "$perf_server_ip" ] && echo "PERF_SERVER_USER=$perf_server_user"
        } > .env
        log_success ".env file created"
    else
        vplmn_ip=$(grep -E '^VPLMN_IP=' .env | cut -d'=' -f2 | cut -d'#' -f1 | tr -d '[:space:]')
        hplmn_ip=$(grep -E '^HPLMN_IP=' .env | cut -d'=' -f2 | cut -d'#' -f1 | tr -d '[:space:]')
        
        if [ -z "$vplmn_ip" ] || [ -z "$hplmn_ip" ]; then
            log_error ".env file incomplete: VPLMN_IP and/or HPLMN_IP not set"
            log "Edit .env manually and re-run setup.sh"
            return 1
        fi

        # Show current .env contents and ask user to confirm
        log ""
        log "Current .env file contents:"
        log "--------------------------------------------------"
        grep -v '^#' .env | grep -v '^$' | while IFS= read -r line; do log "  $line"; done
        log "--------------------------------------------------"
        log ""
        log_warning "Please verify the above values are correct for this machine."
        log "If anything is wrong, edit .env now (in another terminal) and then press y."
        log ""
        read -p "Are the .env values correct? Proceed with setup? (y/N) " -r confirm
        echo
        if [[ ! $confirm =~ ^[Yy]$ ]]; then
            log_warning "Setup aborted — edit .env and re-run ./setup.sh"
            return 1
        fi
        if ! grep -qE '^HPLMN_USER=' .env; then
            read -p "  HPLMN_USER not in .env — SSH username on HPLMN [${USER}]: " hplmn_user
            echo "HPLMN_USER=${hplmn_user:-$USER}" >> .env
        fi
        if ! grep -qE '^VPLMN_USER=' .env; then
            read -p "  VPLMN_USER not in .env — SSH username on this PC [${USER}]: " vplmn_user
            echo "VPLMN_USER=${vplmn_user:-$USER}" >> .env
        fi
    fi
    
    log_success ".env configuration verified"
    log "  VPLMN_IP   = $vplmn_ip"
    log "  HPLMN_IP   = $hplmn_ip"
    log "  HPLMN_USER = $(grep -oP '^HPLMN_USER=\K[^#\s]+' .env 2>/dev/null || echo '(not set)')"
    log "  VPLMN_USER = $(grep -oP '^VPLMN_USER=\K[^#\s]+' .env 2>/dev/null || echo '(not set)')"
    log ""
    
    # Step 2.5: Verify connectivity to HPLMN
    log_step "Step 2.5: Verifying network connectivity to HPLMN"
    if ping -c 1 -W 2 "$hplmn_ip" &>/dev/null; then
        log_success "Network connectivity to HPLMN ($hplmn_ip): OK"
    else
        log_warning "Cannot reach HPLMN at $hplmn_ip"
        log "This may be expected if:"
        log "  - HPLMN (PC2) is not yet powered on"
        log "  - The IP address is incorrect in .env"
        log "  - There is a firewall blocking ping requests"
        log "  - Network connectivity is not fully established yet"
        log ""
        read -p "Continue setup anyway? (y/N) " -r confirm
        echo
        if [[ ! $confirm =~ ^[Yy]$ ]]; then
            log_warning "Setup aborted by user"
            return 1
        fi
    fi
    log ""

    # Step 2.6: Setup passwordless SSH to HPLMN
    log_step "Step 2.6: Setting up passwordless SSH to HPLMN"
    # Try to read HPLMN user from .env, then app.py, then prompt
    hplmn_user=$(grep -oP '^HPLMN_USER=\K[^#\s]+' .env 2>/dev/null | tr -d '"')
    [[ -z "$hplmn_user" ]] && hplmn_user=$(grep -oP '"remote".*?"user":\s*"\K[^"]+' webui/backend/app.py 2>/dev/null | head -1)
    if [[ -z "$hplmn_user" ]]; then
        read -rp "  Enter SSH username for HPLMN (${hplmn_ip}): " hplmn_user
        [[ -z "$hplmn_user" ]] && hplmn_user="$USER"
    fi
    setup_passwordless_ssh "$hplmn_user" "$hplmn_ip" "HPLMN (PC2)" || true
    log ""

    # Step 2.7: Setup passwordless SSH to the performance server (if configured).
    # The WebUI / batch runner SSH into this host for N6-delay, iperf, download
    # and video tests — without a key there, every such run fails preflight with
    # "Performance server SSH check failed". It's optional: skip cleanly if no
    # PERF_SERVER_IP is set in .env.
    log_step "Step 2.7: Setting up passwordless SSH to the performance server"
    perf_ip=$(grep -oP '^PERF_SERVER_IP=\K[^#\s]+' .env 2>/dev/null | tr -d '"')
    perf_user=$(grep -oP '^PERF_SERVER_USER=\K[^#\s]+' .env 2>/dev/null | tr -d '"')
    if [[ -z "$perf_ip" ]]; then
        log "No PERF_SERVER_IP in .env — skipping."
        log "Only needed for N6-delay / iperf / download / video tests. To enable it,"
        log "add PERF_SERVER_IP (and PERF_SERVER_USER) to .env and re-run ./setup.sh."
    else
        [[ -z "$perf_user" ]] && perf_user="roaming"
        setup_passwordless_ssh "$perf_user" "$perf_ip" "performance server" || true
    fi
    log ""
    
    # Step 3: Configure IP addresses in all files
    log_step "Step 3: Configuring IP addresses across all files"
    if [ -f "lib/setup/configure_ip_from_env.sh" ]; then
        bash lib/setup/configure_ip_from_env.sh <<< 'y' || {
            log_error "Failed to configure IPs"
            return 1
        }
        log_success "IP configuration completed"
    else
        log_error "configure_ip_from_env.sh not found in lib/setup/"
        return 1
    fi
    
    # Step 4: Prepare NF binaries
    log_step "Step 4: Preparing NF binaries"
    if [ -f "lib/setup/prepare_nfs.sh" ]; then
        bash lib/setup/prepare_nfs.sh <<< 'Y' || {
            log_error "Failed to prepare NF binaries"
            return 1
        }
        log_success "NF binaries prepared"
    else
        log_error "prepare_nfs.sh not found in lib/setup/"
        return 1
    fi
    
    # Step 5: Restore TLS certificates
    log_step "Step 5: Restoring TLS certificates"
    if [ -f "lib/setup/redistribute_certificates.sh" ]; then
        bash lib/setup/redistribute_certificates.sh || {
            log_error "Failed to redistribute certificates"
            return 1
        }
        log_success "TLS certificates distributed"
    else
        log_warning "redistribute_certificates.sh not found, skipping certificate distribution"
    fi
    
    # Step 6: Build Docker images
    #
    # No confirmation prompt here: build_all.sh already asks the only question
    # worth asking ("Found N existing Open5GS image(s) — rebuild?"), and it only
    # builds what is missing otherwise. A second "Ready to start?" up here reads
    # as if declining would skip the build, when it actually aborted setup.
    log_step "Step 6: Building Docker images (this may take 10-15 minutes)"
    log ""

    # No sudo: build_all.sh only issues docker commands, which need docker-socket
    # access (the docker group), not root. Running it under sudo builds the images
    # as root and is inconsistent with the un-sudo'd docker calls elsewhere.
    if [ -f "lib/setup/build_all.sh" ]; then
        $DOCKER_SUDO bash lib/setup/build_all.sh || {
            log_error "Docker image build failed"
            log ""
            log "If it failed with a Docker permission error, add your user to the"
            log "docker group and re-run setup:"
            log "  sudo usermod -aG docker $REAL_USER   # then log out/in, or: newgrp docker"
            log ""
            log "If it failed due to missing files, ensure:"
            log "  1. Open5GS binaries are at $OPEN5GS_INSTALL"
            log "  2. TLS certificates are in lib/setup/certificates_backup/"
            log "  3. All IP addresses are configured correctly"
            return 1
        }
        log_success "All Docker images built successfully"
    else
        log_error "build_all.sh not found in lib/setup/"
        return 1
    fi
    
    # Step 7: Create Docker networks
    log_step "Step 7: Creating Docker networks"
    if create_vplmn_docker_networks; then
        log_success "Docker networks created/verified"
    else
        log_error "Failed to create Docker networks"
        return 1
    fi
    
    # Step 8: Setup host networking
    log_step "Step 8: Configuring host networking for UPF"
    if [ -f "lib/setup/open5gs_network_setup.sh" ]; then
        sudo bash lib/setup/open5gs_network_setup.sh || {
            log_error "Network setup failed"
            return 1
        }
        log_success "Host networking configured"
    else
        log_warning "open5gs_network_setup.sh not found, skipping network setup"
        log "Run: sudo ./lib/setup/open5gs_network_setup.sh manually"
    fi
    
    # Step 9: PacketRusher setup (VPLMN only)
    log_step "Step 9: Verifying PacketRusher setup"
    if [ -d "PacketRusher" ]; then
        log_success "PacketRusher directory found"
        log "Ensure PacketRusher is configured for your UE simulation needs"
    else
        log_warning "PacketRusher directory not found"
        log "You can install PacketRusher separately if you need UE simulation"
    fi

    # Step 10: WebUI setup
    log_step "Step 10: Configuring WebUI"
    if [ -f "webui/setup.sh" ]; then
        log "Running webui/setup.sh to configure IP addresses and credentials..."
        if bash webui/setup.sh; then
            log_success "WebUI configured successfully"
        else
            log_warning "WebUI setup did not complete successfully"
            log "You can run it later: cd webui && ./setup.sh"
        fi
    else
        log_warning "webui/setup.sh not found — skipping WebUI setup"
        log "Run manually: cd webui && ./setup.sh"
    fi

    # Step 11: Passwordless sudo for the automation user
    # The batch runner / automation apply delays and enter container namespaces
    # non-interactively (sudo tc / docker / nsenter / ipsec / modprobe). Without
    # passwordless sudo those steps fail mid-run ("a terminal is required to read
    # the password"). This installs a scoped /etc/sudoers.d drop-in.
    log_step "Step 11: Configuring passwordless sudo for automation commands"
    if [ -f "lib/setup/setup_sudoers.sh" ]; then
        if bash lib/setup/setup_sudoers.sh; then
            log_success "Passwordless sudo configured"
        else
            log_warning "Could not configure passwordless sudo automatically"
            log "Run it later:  bash lib/setup/setup_sudoers.sh"
        fi
    else
        log_warning "setup_sudoers.sh not found in lib/setup/, skipping"
        log "Batch/WebUI runs need passwordless sudo for tc/docker/nsenter —"
        log "set it up with: bash lib/setup/setup_sudoers.sh"
    fi

    # Step 12: Browsertime — web performance measurement through the 5G tunnel
    # lib/features/browsertime_5g.sh runs one `docker run <image>` per URL and relies on
    # Docker pulling that image on demand. Left to itself, the first measurement
    # stalls on a silent ~3 GB download, or dies opaquely on an offline host.
    # Pull it here so the first run is ready to go. Non-fatal: this only affects
    # the browsertime web tests, not the core testbed.
    log_step "Step 12: Preparing Browsertime (web performance tests)"
    if [ -f "lib/features/browsertime_5g.sh" ]; then
        # Read the tag from lib/features/browsertime_5g.sh rather than repeating it here, so
        # the two can't drift apart if the image is ever changed or pinned.
        local bt_image
        bt_image=$(grep -oP '^BT_IMAGE="\K[^"]+' lib/features/browsertime_5g.sh | head -1)
        [ -z "$bt_image" ] && bt_image="sitespeedio/browsertime"

        if $DOCKER_SUDO docker image inspect "$bt_image" >/dev/null 2>&1; then
            log_success "Browsertime image already present: $bt_image"
        else
            log "Pulling $bt_image ..."
            log "This is a one-time ~3 GB download and may take several minutes."
            if $DOCKER_SUDO docker pull "$bt_image" >> "$LOG_FILE" 2>&1; then
                log_success "Browsertime image pulled: $bt_image"
            else
                log_warning "Could not pull $bt_image"
                log "Not fatal — the core testbed is unaffected and the image"
                log "will be pulled on the first web test instead."
                log "To retry now:  docker pull $bt_image"
            fi
        fi

        # lib/features/browsertime_5g.sh parses browsertime.json with python3 for its
        # TTFB/Load summary, and enters the PacketRusher netns with nsenter.
        local bt_missing=""
        command -v python3 >/dev/null 2>&1 || bt_missing="python3"
        command -v nsenter  >/dev/null 2>&1 || bt_missing="$bt_missing nsenter"
        if [ -z "$bt_missing" ]; then
            log_success "Browsertime host tools present (python3, nsenter)"
        else
            log_warning "Missing tool(s) for browsertime:$bt_missing"
            log "Install with: sudo apt-get install -y python3 util-linux"
        fi

        log "Run a web test with:  ./lib/features/browsertime_5g.sh https://www.example.com"
    else
        log_warning "lib/features/browsertime_5g.sh not found — skipping Browsertime setup"
    fi

    # Step 13: Generate the per-mode test configs.
    # configs/generate_confs.sh emits the standard set (non_roaming, lbo, hr,
    # hr_ipsec_1-6) from a single template. Running it here means a fresh clone
    # ends setup with the configs the WebUI and testbed_automation expect,
    # already carrying the server IP that configure_ip_from_env.sh baked into
    # the generator. Non-fatal: the generator only rewrites its own 9 files.
    log_step "Step 13: Generating test configs"
    if [ -f "$VPLMN_DIR/configs/generate_confs.sh" ]; then
        if bash "$VPLMN_DIR/configs/generate_confs.sh" >> "$LOG_FILE" 2>&1; then
            log_success "Test configs generated in configs/"
        else
            log_warning "generate_confs.sh failed — configs/ may be incomplete"
            log "Regenerate later with:  bash configs/generate_confs.sh"
        fi
    else
        log_warning "configs/generate_confs.sh not found — skipping config generation"
    fi

    # Step 14: Generate the per-iteration PacketRusher UE configs.
    # Expands each base config_<mode>_roaming.yml into <mode>_roaming/config_1..100.yml
    # (MSIN incremented per file) so batch runs get a distinct UE per iteration —
    # lib/automation/tests.sh picks config_${iteration}.yml and lib/automation/preflight.sh checks
    # config_1.yml exists. Not committed, so a fresh clone needs this step.
    local pr_gen="$VPLMN_DIR/configs/Packetrusher_Configs/generate_Packetrusher_configs.sh"
    log_step "Step 14: Generating PacketRusher UE configs"
    if [ -f "$pr_gen" ]; then
        if bash "$pr_gen" >> "$LOG_FILE" 2>&1; then
            log_success "PacketRusher configs generated (hr_roaming/, lbo_roaming/, non_roaming/)"
        else
            log_warning "generate_Packetrusher_configs.sh failed — batch runs may not find config_N.yml"
            log "Regenerate later with:  bash configs/Packetrusher_Configs/generate_Packetrusher_configs.sh"
        fi
    else
        log_warning "generate_Packetrusher_configs.sh not found — skipping PacketRusher config generation"
    fi

    log_success "VPLMN setup completed successfully"
    return 0
}

# ============================================================================
# OPTIONAL PACKETRUSHER SETUP (VPLMN ONLY)
# ============================================================================

check_secure_boot() {
    log_step "Checking Secure Boot status"
    
    if [ ! -f /sys/firmware/efi/fw_platform_size ]; then
        log_warning "Secure Boot check not available (non-EFI system)"
        return 0
    fi
    
    if mokutil --sb-state &>/dev/null; then
        if mokutil --sb-state 2>/dev/null | grep -q "enabled"; then
            log_error "Secure Boot is enabled"
            log ""
            log "gtp5g kernel module requires Secure Boot to be disabled."
            log ""
            log "To disable Secure Boot:"
            log "  1. Reboot into BIOS/UEFI (usually F2, Del, or Esc during boot)"
            log "  2. Find 'Secure Boot' setting (usually in Security tab)"
            log "  3. Disable it and save"
            log "  4. Reboot and try again"
            log ""
            return 1
        fi
    fi
    
    log_success "Secure Boot: Not blocking kernel modules"
    return 0
}

setup_packetrusher() {
    log_step "Step 15: Optional PacketRusher Setup (VPLMN only)"
    log ""
    log "PacketRusher requires the gtp5g kernel module for GTP-U tunneling."
    log "Installation requires: Go compiler, build tools, and kernel module compilation."
    log ""
    read -p "Install PacketRusher and gtp5g kernel module? (y/N) " -r confirm
    echo
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        log_warning "PacketRusher installation skipped"
        log "You can install it later by re-running: ./setup.sh"
        return 0
    fi
    
    # Check Secure Boot
    if ! check_secure_boot; then
        log_warning "PacketRusher setup aborted due to Secure Boot"
        log "Disable Secure Boot in BIOS and try again"
        return 0
    fi
    
    log ""
    
    # Build the PacketRusher Docker image from source (packetrusher:20250225) —
    # the same tag the automation scripts and start_packetrusher.sh use. This
    # replaces the old ghcr.io/borjis131/packetrusher:main fork, which predated
    # PR #135 and sent QFI-less uplink that the Open5GS v2.8.0 UPF drops. The
    # build script (docker/packetrusher-docker/) clones the upstream source if
    # absent and is idempotent (skips if the image already exists).
    log_step "Building PacketRusher Docker image"
    if DOCKER_CMD="$DOCKER_SUDO docker" "$VPLMN_DIR/docker/packetrusher-docker/build_packetrusher.sh"; then
        log_success "PacketRusher image ready (packetrusher:20250225)"
    else
        log_error "Failed to build the PacketRusher image"
        log "Ensure git and Docker are available; for Docker without sudo:"
        log "  sudo usermod -aG docker $REAL_USER   # then log out/in, or: newgrp docker"
        return 1
    fi
    
    log ""
    
    # Install build dependencies
    log_step "Installing build dependencies for gtp5g"
    local deps="build-essential linux-headers-generic make git wget tar linux-modules-extra-$(uname -r)"
    
    if ! sudo apt-get install -y $deps 2>&1 | tail -20 >> "$LOG_FILE"; then
        log_error "Failed to install build dependencies"
        log "Try installing manually: sudo apt-get install $deps"
        return 1
    fi
    log_success "Build dependencies installed"
    
    log ""
    
    # Check if Go is already installed
    log_step "Checking Go installation"
    if command -v go &>/dev/null; then
        log_success "Go already installed: $(go version)"
    else
        log "Installing Go 1.24.1 (this may take 1-2 minutes)..."
        
        local go_url="https://go.dev/dl/go1.24.1.linux-amd64.tar.gz"
        local go_file="/tmp/go1.24.1.linux-amd64.tar.gz"
        
        if ! wget -q "$go_url" -O "$go_file" 2>/dev/null; then
            log_error "Failed to download Go from $go_url"
            log "Network connectivity issue? Try again or install Go manually:"
            log "  wget https://go.dev/dl/go1.24.1.linux-amd64.tar.gz"
            log "  sudo tar -C /usr/local -xzf go1.24.1.linux-amd64.tar.gz"
            return 1
        fi
        
        if ! sudo tar -C /usr/local -xzf "$go_file" 2>/dev/null; then
            log_error "Failed to extract Go archive"
            return 1
        fi
        
        # Add Go to PATH
        export PATH=$PATH:/usr/local/go/bin
        append_profile 'export PATH=$PATH:/usr/local/go/bin'
        
        log_success "Go installed: $(go version)"
        rm -f "$go_file"
    fi
    
    log ""
    
    # Clone and build gtp5g
    log_step "Cloning and building gtp5g kernel module"
    
    # An existing directory is not proof of a usable checkout: an interrupted or
    # partially-deleted clone leaves PacketRusher/ behind empty. Skipping the
    # clone on that basis makes the gtp5g build below die with a confusing
    # "cd: .../lib/gtp5g: No such file or directory", so test for the sources we
    # actually need rather than for the directory.
    if [ -f "$VPLMN_DIR/PacketRusher/lib/gtp5g/Makefile" ]; then
        log_warning "PacketRusher already present at $VPLMN_DIR/PacketRusher"
        log "Using existing checkout..."
    else
        if [ -d "$VPLMN_DIR/PacketRusher" ]; then
            log_warning "PacketRusher/ exists but has no lib/gtp5g sources — re-cloning"
            rm -rf "$VPLMN_DIR/PacketRusher"
        fi

        log "Cloning PacketRusher repository..."
        cd "$VPLMN_DIR" || return 1

        if ! git clone https://github.com/HewlettPackard/PacketRusher 2>&1 | tail -5 >> "$LOG_FILE"; then
            log_error "Failed to clone PacketRusher repository"
            cd "$VPLMN_DIR" || return 1
            return 1
        fi
        log_success "PacketRusher repository cloned"
    fi
    
    # Set PACKETRUSHER environment variable
    export PACKETRUSHER="$VPLMN_DIR/PacketRusher"
    append_profile "export PACKETRUSHER=$VPLMN_DIR/PacketRusher"
    
    log ""
    log "Building gtp5g kernel module (this may take 5-10 minutes)..."

    if [ ! -f "$PACKETRUSHER/lib/gtp5g/Makefile" ]; then
        log_error "gtp5g sources not found at $PACKETRUSHER/lib/gtp5g"
        log "The PacketRusher checkout is incomplete. Remove it and re-run setup.sh:"
        log "  rm -rf $PACKETRUSHER && ./setup.sh"
        cd "$VPLMN_DIR" || return 1
        return 1
    fi

    cd "$PACKETRUSHER/lib/gtp5g" || return 1

    make clean 2>&1 >> "$LOG_FILE" 2>/dev/null || log_warning "gtp5g clean step skipped (non-fatal)"

    if ! make 2>&1 | tail -10 >> "$LOG_FILE"; then
        log_error "Failed to compile gtp5g kernel module"
        log ""
        log "Possible causes:"
        log "  1. Kernel headers don't match your running kernel"
        log "  2. Secure Boot is still enabled"
        log "  3. Kernel configuration doesn't support the required features"
        log ""
        log "Try: sudo apt install linux-headers-$(uname -r)"
        cd "$VPLMN_DIR" || return 1
        return 1
    fi
    log_success "gtp5g kernel module compiled"

    log "Installing gtp5g kernel module..."
    if ! sudo make install 2>&1 | tail -10 >> "$LOG_FILE"; then
        log_error "Failed to install gtp5g kernel module"
        log ""
        log "Possible causes:"
        log "  1. Secure Boot is enabled in BIOS"
        log "  2. Module signature verification is enforced"
        log "  3. Permissions issue"
        log ""
        log "Check BIOS settings and ensure Secure Boot is disabled, then try:"
        log "  cd $PACKETRUSHER/lib/gtp5g && sudo make install"
        cd "$VPLMN_DIR" || return 1
        return 1
    fi
    log_success "gtp5g kernel module installed"
    
    log ""
    
    # Verify installation
    log_step "Verifying gtp5g kernel module"
    if ! lsmod | grep -q gtp5g; then
        if ! sudo modprobe gtp5g 2>&1 >> "$LOG_FILE"; then
            log_error "gtp5g kernel module installed but cannot be loaded"
            log "Run: sudo modprobe gtp5g"
            log "If this fails, check BIOS Secure Boot settings"
            cd "$VPLMN_DIR" || return 1
            return 1
        fi
    fi
    
    if lsmod | grep -q gtp5g; then
        log_success "gtp5g kernel module loaded successfully"
    else
        log_warning "gtp5g module installed but not loaded"
        log "It will be loaded automatically when PacketRusher starts"
    fi
    
    cd "$VPLMN_DIR" || return 1
    log ""
    log_success "PacketRusher setup completed successfully ✓"
    log ""
    log "You can now start PacketRusher:"
    log "  ./lib/features/start_packetrusher.sh"
    
    return 0
}

# ============================================================================
# Docker Network Management
# ============================================================================

create_vplmn_docker_networks() {
    log "Creating VPLMN Docker networks..."
    
    local -A networks=(
        ["my_custom_network"]="192.168.50.0/24"
        ["my_second_network"]="192.168.70.0/24"
        ["my_isolated_network"]="192.168.80.0/24"
    )
    
    for name in "${!networks[@]}"; do
        local subnet="${networks[$name]}"
        if $DOCKER_SUDO docker network inspect "$name" &>/dev/null; then
            log "  ✓ Docker network already exists: $name"
        else
            log "  Creating Docker network: $name ($subnet)"
            if ! $DOCKER_SUDO docker network create --driver bridge --subnet "$subnet" "$name" 2>&1 >> "$LOG_FILE"; then
                log_error "Failed to create Docker network: $name"
                log "Make sure your user can access Docker without sudo:"
                log "  sudo usermod -aG docker $REAL_USER"
                log "Then log out and back in, or run: newgrp docker"
                return 1
            fi
            log "  ✓ Docker network created: $name"
        fi
    done
    
    return 0
}

setup_ipsec() {
    log_step "Step 16: Optional N9 IPsec Tunnel Setup (HR roaming)"
    log ""
    log "Encrypts N9 GTP-U traffic between the VPLMN and HPLMN UPFs (3GPP TS 33.210)."
    log "Only needed for Home-Routed (HR) roaming. Requires:"
    log "  - The HPLMN PC (PC2) already set up and reachable via SSH (key auth)"
    log "  - Passwordless (or cached) sudo on both PCs"
    log ""
    read -p "Set up the N9 IPsec tunnel now? (y/N) " -r confirm
    echo
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        log_warning "IPsec setup skipped"
        log "You can run it later: ./lib/setup/deploy_ipsec.sh   (see docs/IPSEC.md)"
        return 0
    fi

    local deploy="$VPLMN_DIR/lib/setup/deploy_ipsec.sh"
    if [[ ! -x "$deploy" ]]; then
        log_error "IPsec deploy script not found or not executable: $deploy"
        return 1
    fi

    log "Launching IPsec deployment (drives PC1 + PC2 over SSH)..."
    log ""
    # deploy_ipsec.sh is interactive (its own prompts/colors) and manages its own
    # sudo/SSH; run it directly rather than through log() so its output is preserved.
    if "$deploy"; then
        log_success "IPsec tunnel setup completed"
    else
        log_error "IPsec tunnel setup did not complete (see output above)"
        log "You can retry later: ./lib/setup/deploy_ipsec.sh"
        return 1
    fi
    return 0
}

setup_n4_ipsec() {
    log_step "Step 17: Optional N4 IPsec Tunnel Setup (SMF <-> UPF)"
    log ""
    log "Encrypts N4/PFCP traffic (UDP 8805) between the VPLMN SMF and UPF with"
    log "IPsec (tunnel mode, IKEv2, X.509 certs — same 3GPP NDS/IP profile as N9)."
    log "Intra-VPLMN, so no second PC is involved. This step generates the certs"
    log "and pre-configures both ends; the tunnel stays OFF until you start it"
    log "(via the WebUI N4 button or ./docker/n4-ipsec/n4_ipsec.sh start)."
    log ""
    read -p "Set up the N4 (SMF<->UPF) IPsec now? (y/N) " -r confirm
    echo
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        log_warning "N4 IPsec setup skipped"
        log "You can run it later: ./docker/n4-ipsec/n4_ipsec.sh deploy   (see docker/n4-ipsec/README.md)"
        return 0
    fi

    local n4="$VPLMN_DIR/docker/n4-ipsec/n4_ipsec.sh"
    if [[ ! -x "$n4" ]]; then
        log_error "N4 IPsec script not found or not executable: $n4"
        return 1
    fi

    # deploy is safe with the stack down: it stages certs + the host responder
    # config, and defers the SMF-side config to the first 'start'. It manages its
    # own sudo/docker, so run it directly to preserve its output.
    log "Generating N4 certificates and pre-configuring both ends..."
    log ""
    if "$n4" deploy; then
        log_success "N4 IPsec deploy completed (tunnel OFF; toggle it from the WebUI or n4_ipsec.sh)"
    else
        log_error "N4 IPsec deploy did not complete (see output above)"
        log "You can retry later: ./docker/n4-ipsec/n4_ipsec.sh deploy"
        return 1
    fi
    return 0
}

setup_commercial_ran() {
    log_step "Step 18: Optional Commercial RAN (gNB + dongle UE)"
    log ""
    log "Adds dashboard support for testing with a real gNB (e.g. the DSK) and a"
    log "USB-dongle UE instead of PacketRusher: dongle/gNB control panels, and the"
    log "ping/iperf/download/webpage tests run through the dongle. It also makes"
    log "the AMF listen on all interfaces so the external gNB can reach NGAP."
    log "Leave it off if you only use PacketRusher (the dashboard then hides it)."
    log ""
    read -p "Do you have a commercial RAN you want to test with? (y/N) " -r confirm
    echo
    local mode="off"
    [[ $confirm =~ ^[Yy]$ ]] && mode="on"

    local script="$VPLMN_DIR/lib/features/set-dongle-mode.sh"
    if [[ ! -x "$script" ]]; then
        log_error "Dongle mode script not found or not executable: $script"
        return 1
    fi
    # Interactive in "on" mode (asks for the dongle control host / gNB SSH
    # settings); run it directly so its prompts are not swallowed by log().
    if "$script" "$mode"; then
        if [ "$mode" = "on" ]; then
            log_success "Commercial RAN support enabled (settings: webui/dongle.env)"
        else
            log_success "Commercial RAN support left disabled"
            log "You can enable it later: ./lib/features/set-dongle-mode.sh on"
        fi
    else
        return 1
    fi
    return 0
}


# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    log "=========================================="
    log "${GREEN}VPLMN (Visited PLMN) Setup - PC1${NC}"
    log "=========================================="
    log "Timestamp: $TIMESTAMP"
    log "Location:  $VPLMN_DIR"
    log "Log file:  $LOG_FILE"
    log ""
    log "${YELLOW}This script will:${NC}"
    log "  1. Automatically install missing prerequisites"
    log "     - Docker & Docker Compose"
    log "     - Open5GS v2.8.0 (if not already built)"
    log "  2. Configure IP addresses from .env"
    log "  3. Prepare and build Docker images"
    log "  4. Setup host networking for UPF"
    log "  5. Optionally enable commercial RAN (gNB + dongle) support"
    log ""
    log "Total time: ~30-45 minutes (mostly for Open5GS build)"
    log ""
    
    # Verify and install prerequisites
    if ! verify_prerequisites; then
        log_error "Prerequisites check failed. Exiting."
        exit 1
    fi

    log ""

    # Decide whether Docker steps need sudo (fresh-VM docker-group gap)
    detect_docker_sudo

    # Execute VPLMN setup
    if ! setup_vplmn; then
        log_error "=========================================="
        log_error "VPLMN setup failed"
        log_error "=========================================="
        log ""
        log "Check the log file for details: $LOG_FILE"
        log ""
        exit 1
    fi
    
    log ""
    
    # Optional: Setup PacketRusher (VPLMN only)
    if ! setup_packetrusher; then
        log_warning "PacketRusher setup did not complete successfully"
        log "You can install it later or manually follow the instructions in README.md"
    fi

    log ""

    # Optional: Setup N9 IPsec tunnel (HR roaming, drives both PCs over SSH)
    if ! setup_ipsec; then
        log_warning "IPsec setup did not complete successfully"
        log "You can run it later: ./lib/setup/deploy_ipsec.sh"
    fi

    log ""

    # Optional: Setup N4 IPsec tunnel (SMF <-> UPF, intra-VPLMN)
    if ! setup_n4_ipsec; then
        log_warning "N4 IPsec setup did not complete successfully"
        log "You can run it later: ./docker/n4-ipsec/n4_ipsec.sh deploy"
    fi

    log ""

    # Optional: commercial RAN (gNB + dongle UE) dashboard support — off by default
    if ! setup_commercial_ran; then
        log_warning "Commercial RAN setup did not complete successfully"
        log "You can run it later: ./lib/features/set-dongle-mode.sh"
    fi

    # Final summary
    log ""
    log_success "=========================================="
    log_success "VPLMN setup completed successfully!"
    log_success "=========================================="
    log ""
    log "Setup completed at: $(date)"
    log "Log file: $LOG_FILE"
    log ""
    log "Next steps:"
    log ""
    log "  1. (If not already done) Start the HPLMN testbed on PC2:"
    log "     ssh <user>@<HPLMN_IP>"
    log "     cd ~/LKN_5G_Roaming_Testbed/HPLMN"
    log "     ./setup.sh"
    log ""
    log "  2. Configure roaming mode on this PC:"
    log "     ./lib/features/set-open5gs-mode.sh"
    log ""
    log "  3. Start the VPLMN testbed:"
    log "     docker compose up"
    log ""
    if [ -n "$DOCKER_SUDO" ]; then
        log "  ⚠ Docker needed sudo during setup (fresh-install group gap). Until you"
        log "    log out and back in (or run 'newgrp docker'), prefix Docker with sudo:"
        log "     sudo docker compose up"
        log ""
    fi
    log "  4. Start the WebUI (optional monitoring dashboard):"
    log "     cd webui && ./start.sh start"
    log "     Then open: http://$(grep -oP '^VPLMN_IP=\K.*' .env 2>/dev/null || echo '<VPLMN_IP>'):9091"
    log ""
    log "  5. In another terminal, start the gNB simulation:"
    log "     ./lib/features/start_packetrusher.sh"
    log ""
    log "For more information, see:"
    log "  - README.md (for detailed documentation)"
    log "  - lib/setup/README.md (for step-by-step setup details)"
    log "  - setup_logs/setup_${TIMESTAMP}.log (for full setup logs)"
    log ""
    log "Documentation:"
    log "  - Setup guide:  lib/setup/README.md"
    log "  - README:       README.md"
    log "  - Setup logs:   setup_logs/"
    log ""
    exit 0
}

# Run main function
main
