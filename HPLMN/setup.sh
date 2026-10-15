#!/bin/bash

# ==============================================================================
# HPLMN (Home PLMN - PC2) — Automated Setup Script
# ==============================================================================
# Automates the complete initialization of the HPLMN testbed from scratch
# Covers IP configuration, binary preparation, Docker image builds,
# and network setup.
#
# Usage:
#   ./setup.sh
#
# Or run from project root:
#   ./HPLMN/setup.sh
#
# This script must be run from within the HPLMN directory or called
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

# Determine script directory and ensure we're in the HPLMN directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HPLMN_DIR="$SCRIPT_DIR"

# Check if we're in the correct directory
if [ ! -f "$HPLMN_DIR/docker-compose.yml" ]; then
    echo -e "${RED}ERROR: docker-compose.yml not found at $HPLMN_DIR${NC}"
    echo -e "${YELLOW}This script must be run from the HPLMN directory or called as:${NC}"
    echo -e "${BLUE}  ./HPLMN/setup.sh${NC}"
    exit 1
fi

# ── Ensure the project directory is named LKN_5G_Roaming_Testbed ──────────────
# The GitLab repo is 'roamingtb_main', so `git clone` lands in ~/roamingtb_main,
# but many scripts and the docs hardcode the path ~/LKN_5G_Roaming_Testbed. If
# the project root has any other name, rename it once and re-exec setup from the
# corrected path so every later step sees the expected layout.
ensure_project_dir_name() {
    local root parent target sub
    root="$(cd "$SCRIPT_DIR/.." && pwd)"          # parent of HPLMN/ = project root
    if [ "$(basename "$root")" = "LKN_5G_Roaming_Testbed" ]; then
        return 0
    fi
    parent="$(dirname "$root")"
    target="$parent/LKN_5G_Roaming_Testbed"
    sub="$(basename "$SCRIPT_DIR")"               # HPLMN (or VPLMN)
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
LOG_DIR="$HPLMN_DIR/setup_logs"
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

    if git -C "$HPLMN_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
        # stat, not `xargs find`: xargs appends the file list, but find requires
        # paths before the expression, so `xargs find ! -user X` never works.
        foreign="$( (cd "$HPLMN_DIR" && git ls-files -z 2>/dev/null \
                    | xargs -0 -r stat -c '%U|%n' 2>/dev/null \
                    | awk -F'|' -v u="$me" '$1 != u { print $2; exit }') 2>/dev/null || true)"
    else
        # Not a git checkout (e.g. extracted tarball): fall back to the scripts,
        # which are what give_permissions.sh must chmod.
        foreign="$(find "$HPLMN_DIR" -name '*.sh' ! -user "$me" -print -quit 2>/dev/null || true)"
    fi
    [ -d "$LOG_DIR" ] && [ ! -O "$LOG_DIR" ] && foreign="${foreign:-$LOG_DIR}"

    [ -z "$foreign" ] && return 0

    echo "Project files under $HPLMN_DIR are not owned by '$me' (e.g. $foreign)."
    echo "That happens after a root clone or a 'sudo ./setup.sh'. Reclaiming ownership..."

    local ok=1
    if git -C "$HPLMN_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
        (cd "$HPLMN_DIR" && git ls-files -z 2>/dev/null \
            | while IFS= read -r -d '' path; do
                [ -e "$path" ] && printf '%s\0' "$path"
            done \
            | xargs -0 -r sudo chown "$me:$grp") || ok=0
    else
        find "$HPLMN_DIR" -name '*.sh' -print0 2>/dev/null \
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
        echo "  sudo chown -R $me:$grp $HPLMN_DIR"
    fi
    echo ""
}
reclaim_project_ownership

# Under sudo, $HOME becomes /root, but the Open5GS source build belongs to the
# invoking user. Resolve that user's home explicitly.
if [ -n "$SUDO_USER" ]; then
    REAL_USER="$SUDO_USER"
    REAL_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
    REAL_USER="${USER:-$(id -un)}"
    REAL_HOME="$HOME"
fi

OPEN5GS_DIR="${OPEN5GS_DIR:-$REAL_HOME/open5gs}"
OPEN5GS_INSTALL="$OPEN5GS_DIR/install"

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
    LOG_FILE="$(mktemp -t hplmn_setup_XXXXXX.log)"
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
    
    # Install Open5GS build dependencies. strongSwan is included here (not only a
    # build dep) so `ipsec` is on PATH before Step 9's setup_sudoers.sh runs —
    # that script resolves command paths at runtime and silently omits ipsec from
    # the passwordless-sudo grant if it isn't installed yet, which breaks the
    # VPLMN WebUI/deploy running `sudo ipsec` on this host over SSH.
    log "Installing Open5GS build dependencies..."
    local deps="python3-pip python3-setuptools python3-wheel ninja-build \
      build-essential flex bison git cmake libsctp-dev libgnutls28-dev \
      libgcrypt-dev libssl-dev libmongoc-dev libbson-dev libyaml-dev \
      libnghttp2-dev libmicrohttpd-dev libcurl4-gnutls-dev \
      libtins-dev libtalloc-dev meson libidn11-dev \
      strongswan strongswan-pki strongswan-starter"
    
    sudo apt-get install -y $deps || {
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
    
    cd "$HPLMN_DIR" || return 1
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

setup_hplmn() {
    log_step "Setting Up HPLMN (Home PLMN - PC2)"
    
    cd "$HPLMN_DIR" || return 1
    
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
    GIT_DIR=$(git -C "$HPLMN_DIR" rev-parse --git-dir 2>/dev/null)
    if [ -z "$GIT_DIR" ]; then
        log_warning "Not a git repository — skipping hook installation"
    else
        REPO_ROOT=$(git -C "$HPLMN_DIR" rev-parse --show-toplevel)
        CONFIGURE_REL=$(realpath --relative-to="$REPO_ROOT" "$HPLMN_DIR/lib/setup/configure_ip_from_env.sh")
        ENV_REL=$(realpath --relative-to="$REPO_ROOT" "$HPLMN_DIR/.env")
        ENV_TEMPLATE_REL=$(realpath --relative-to="$REPO_ROOT" "$HPLMN_DIR/lib/setup/.env.template")
        # GIT_DIR may be relative; resolve it from HPLMN_DIR
        [[ "$GIT_DIR" != /* ]] && GIT_DIR="$HPLMN_DIR/$GIT_DIR"
        mkdir -p "$GIT_DIR/hooks"
        # Install from the versioned hook file (single source of truth).
        if cp "$HPLMN_DIR/lib/setup/post-merge.hook" "$GIT_DIR/hooks/post-merge"; then
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
        read -p "  VPLMN (PC1) IP address: " vplmn_ip
        read -p "  HPLMN (this PC) IP address: " hplmn_ip
        
        if [ -z "$vplmn_ip" ] || [ -z "$hplmn_ip" ]; then
            log_error "IP addresses cannot be empty"
            return 1
        fi

        # HPLMN only needs the two IPs — it runs neither the automation nor the
        # performance-server tests (those live on VPLMN), so no PERF_SERVER_* here.
        {
            echo "VPLMN_IP=$vplmn_ip"
            echo "HPLMN_IP=$hplmn_ip"
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
    fi
    
    log_success ".env configuration verified"
    log "  VPLMN_IP   = $vplmn_ip"
    log "  HPLMN_IP   = $hplmn_ip"
    log ""
    
    # Step 2.5: Verify connectivity to VPLMN
    log_step "Step 2.5: Verifying network connectivity to VPLMN"
    if ping -c 1 -W 2 "$vplmn_ip" &>/dev/null; then
        log_success "Network connectivity to VPLMN ($vplmn_ip): OK"
    else
        log_warning "Cannot reach VPLMN at $vplmn_ip"
        log "This may be expected if:"
        log "  - VPLMN (PC1) is not yet powered on"
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
    # as root and is inconsistent with the un-sudo'd docker calls in Step 7.
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
    if create_hplmn_docker_networks; then
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

    # Step 9: Passwordless sudo for WebUI remote control.
    # The VPLMN WebUI controls HPLMN over SSH with `sudo docker compose up -d`
    # (and `down`/`ps`), `sudo docker exec` (N6 delays), and `sudo ipsec` (HR
    # tunnel). Those SSH commands are non-interactive, so without passwordless
    # sudo here the WebUI's "Start HPLMN" fails with
    # "sudo: a terminal is required to read the password".
    log_step "Step 9: Configuring passwordless sudo for WebUI remote control"
    if [ -f "lib/setup/setup_sudoers.sh" ]; then
        if bash lib/setup/setup_sudoers.sh; then
            log_success "Passwordless sudo configured (docker, ipsec)"
        else
            log_warning "Could not configure passwordless sudo automatically"
            log "The VPLMN WebUI won't be able to start/stop HPLMN until this is set."
            log "Run it later:  bash lib/setup/setup_sudoers.sh"
        fi
    else
        log_warning "setup_sudoers.sh not found in lib/setup/, skipping"
        log "The VPLMN WebUI drives HPLMN with 'sudo docker compose' over SSH —"
        log "without passwordless sudo, starting HPLMN from the WebUI will fail."
    fi

    # Step 10: Optional N4 IPsec (SMF <-> UPF, intra-HPLMN)
    log_step "Step 10: Optional N4 IPsec Tunnel Setup (SMF <-> UPF)"
    log "Encrypts N4/PFCP (UDP 8805) between the HPLMN SMF and UPF with IPsec"
    log "(tunnel mode, IKEv2, X.509 certs). Intra-HPLMN. This generates the certs"
    log "and pre-configures both ends; the tunnel stays OFF until started (via the"
    log "VPLMN WebUI N4 button or ./docker/n4-ipsec/n4_ipsec.sh start)."
    read -p "Set up the N4 (SMF<->UPF) IPsec now? (y/N) " -r n4confirm
    echo
    if [[ $n4confirm =~ ^[Yy]$ ]]; then
        if [ -x "docker/n4-ipsec/n4_ipsec.sh" ]; then
            # deploy is safe with the stack down: it stages certs + the host
            # responder config and defers the SMF-side config to the first 'start'.
            if docker/n4-ipsec/n4_ipsec.sh deploy; then
                log_success "N4 IPsec deploy completed (tunnel OFF; toggle from the VPLMN WebUI)"
            else
                log_warning "N4 IPsec deploy did not complete — run later: ./docker/n4-ipsec/n4_ipsec.sh deploy"
            fi
        else
            log_warning "docker/n4-ipsec/n4_ipsec.sh not found/executable — skipping N4 IPsec"
        fi
    else
        log_warning "N4 IPsec setup skipped — run later: ./docker/n4-ipsec/n4_ipsec.sh deploy"
    fi

    log_success "HPLMN setup completed successfully"
    return 0
}

# ============================================================================
# Docker Network Management
# ============================================================================

create_hplmn_docker_networks() {
    log "Creating HPLMN Docker network..."
    
    local name="my_custom_network"
    local subnet="192.168.60.0/24"
    
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
    
    return 0
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    log "=========================================="
    log "${GREEN}HPLMN (Home PLMN) Setup - PC2${NC}"
    log "=========================================="
    log "Timestamp: $TIMESTAMP"
    log "Location:  $HPLMN_DIR"
    log "Log file:  $LOG_FILE"
    log ""
    log "${YELLOW}This script will:${NC}"
    log "  1. Automatically install missing prerequisites"
    log "     - Docker & Docker Compose"
    log "     - Open5GS v2.8.0 (if not already built)"
    log "  2. Configure IP addresses from .env"
    log "  3. Prepare and build Docker images"
    log "  4. Create Docker networks"
    log "  5. Setup host networking for UPF"
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

    # Execute HPLMN setup
    if ! setup_hplmn; then
        log_error "=========================================="
        log_error "HPLMN setup failed"
        log_error "=========================================="
        log ""
        log "Check the log file for details: $LOG_FILE"
        log ""
        exit 1
    fi
    
    # Final summary
    log ""
    log_success "=========================================="
    log_success "HPLMN setup completed successfully!"
    log_success "=========================================="
    log ""
    log "Setup completed at: $(date)"
    log "Log file: $LOG_FILE"
    log ""
    log "Next steps:"
    log ""
    log "  1. (If not already done) Start the VPLMN testbed on PC1:"
    log "     ssh <user>@<VPLMN_IP>"
    log "     cd ~/LKN_5G_Roaming_Testbed/VPLMN"
    log "     ./setup.sh"
    log ""
    log "  2. Configure roaming mode on this PC:"
    log "     ./lib/features/set-open5gs-mode.sh"
    log ""
    log "  3. Start the HPLMN testbed:"
    log "     docker compose up"
    log ""
    if [ -n "$DOCKER_SUDO" ]; then
        log "  ⚠ Docker needed sudo during setup (fresh-install group gap). Until you"
        log "    log out and back in (or run 'newgrp docker'), prefix Docker with sudo:"
        log "     sudo docker compose up"
        log ""
    fi
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
