#!/bin/bash

# ============================================================================
# Open5GS VPLMN — Comprehensive IP Update Script
# Reads VPLMN_IP and HPLMN_IP from .env and updates every file where they
# appear. After applying, updates its own OLD_* values for the next run.
#
# Files updated:
#   Open5GS configs : docker/upf-docker/{upf,upf_tls}.yaml
#                     docker/smf-docker/{smf,smf_tls}.yaml
#                     docker/sepp-docker/sepp.yaml
#                     docker-compose.yml
#   Testbed scripts : testbed_automation.sh
#                     (HPLMN_IP, REMOTE_PC_USER, SERVER_IP, SERVER_USER)
#                     testbed_automation_dongle.sh (VPLMN_USER)
#   IPsec scripts   : docker/ipsectunnel/01_setup_ca.sh
#                     docker/ipsectunnel/ipsec_certificates/pc1/03_setup_ipsec_pc1_cert.sh
#                     docker/ipsectunnel/ipsec_certificates/pc2/03_setup_ipsec_pc2_cert.sh
#                     docker/ipsectunnel/ipsec_update_configs/esp_config.sh
#                     docker/ipsectunnel/ipsec_certificates/pc1/README.txt (VPLMN IP)
#                     docker/ipsectunnel/ipsec_certificates/pc2/README.txt (HPLMN IP)
#   WebUI           : webui/backend/app.py (PERF_SERVER_IP / PERF_SERVER_USER)
#                     webui/frontend/index.html (const SERVER_IP / SERVER_USER)
#                     webui/start.sh
#                     The WebUI ping targets are not written here: they default
#                     to PERF_SERVER_IP (backend) / SERVER_IP (frontend) rather
#                     than a literal, so they follow whatever those get set to
#                     below. Keep it that way — a hardcoded ping target would
#                     need its own rule here and would silently go stale.
#   Test configs    : configs/generate_confs.sh (rewrites its SERVER_IP var,
#                     then regenerates configs/*.conf), plus configs/main.conf
#                     and roaming_*.conf (hand-written, rewritten in place)
#                     (PERF_SERVER_IP → IPERF_SERVER_IP / SERVER_IP /
#                      DOWNLOAD_TEST_URL / VIDEO_TEST_URL host, and PING_TARGET
#                      only when it currently equals the perf-server IP)
# ============================================================================

echo "=========================================="
echo "  Open5GS Testbed — IP Update (from .env)"
echo "=========================================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# .env lives in the project root (parent of lib/setup/)
ENV_FILE="$PROJECT_DIR/.env"
[[ ! -f "$ENV_FILE" ]] && ENV_FILE="$SCRIPT_DIR/.env"

# ── Current IPs in config files (auto-updated after each run) ──
OLD_VPLMN_IP="10.162.149.192"
OLD_HPLMN_IP="10.162.149.24"
OLD_HPLMN_USER="wassim"
OLD_VPLMN_USER="wassim"
OLD_PERF_SERVER_IP="10.162.149.115"
OLD_PERF_SERVER_USER="roaming"

# ── Read new IPs from .env ──
[[ ! -f "$ENV_FILE" ]] && { echo "ERROR: .env not found at $ENV_FILE"; exit 1; }

NEW_VPLMN_IP=$(grep -E '^VPLMN_IP=' "$ENV_FILE" | cut -d'=' -f2 | cut -d'#' -f1 | tr -d '[:space:]')
NEW_HPLMN_IP=$(grep -E '^HPLMN_IP=' "$ENV_FILE" | cut -d'=' -f2 | cut -d'#' -f1 | tr -d '[:space:]')
NEW_HPLMN_USER=$(grep -E '^HPLMN_USER=' "$ENV_FILE" | cut -d'=' -f2 | cut -d'#' -f1 | tr -d '[:space:]')
NEW_PERF_SERVER_IP=$(grep -E '^PERF_SERVER_IP=' "$ENV_FILE" | cut -d'=' -f2 | cut -d'#' -f1 | tr -d '[:space:]')
NEW_PERF_SERVER_USER=$(grep -E '^PERF_SERVER_USER=' "$ENV_FILE" | cut -d'=' -f2 | cut -d'#' -f1 | tr -d '[:space:]')
NEW_VPLMN_USER=$(grep -E '^VPLMN_USER=' "$ENV_FILE" | cut -d'=' -f2 | cut -d'#' -f1 | tr -d '[:space:]')

[[ -z "$NEW_VPLMN_IP" ]] && { echo "ERROR: VPLMN_IP not set in $ENV_FILE"; exit 1; }
[[ -z "$NEW_HPLMN_IP" ]] && { echo "ERROR: HPLMN_IP not set in $ENV_FILE"; exit 1; }

echo "Read from .env:"
echo "  VPLMN_IP         = $NEW_VPLMN_IP"
echo "  HPLMN_IP         = $NEW_HPLMN_IP"
[[ -n "$NEW_HPLMN_USER" ]]       && echo "  HPLMN_USER       = $NEW_HPLMN_USER"
[[ -n "$NEW_PERF_SERVER_IP" ]]   && echo "  PERF_SERVER_IP   = $NEW_PERF_SERVER_IP"
[[ -n "$NEW_PERF_SERVER_USER" ]] && echo "  PERF_SERVER_USER = $NEW_PERF_SERVER_USER"
[[ -n "$NEW_VPLMN_USER" ]]       && echo "  VPLMN_USER       = $NEW_VPLMN_USER"
echo ""
echo "Changes:"
echo "  VPLMN:            $OLD_VPLMN_IP → $NEW_VPLMN_IP"
echo "  HPLMN:            $OLD_HPLMN_IP → $NEW_HPLMN_IP"
[[ -n "$NEW_VPLMN_USER" ]]       && echo "  VPLMN_USER:       $OLD_VPLMN_USER → $NEW_VPLMN_USER"
[[ -n "$NEW_HPLMN_USER" ]]       && echo "  HPLMN_USER:       $OLD_HPLMN_USER → $NEW_HPLMN_USER"
[[ -n "$NEW_PERF_SERVER_IP" ]]   && echo "  PERF_SERVER_IP:   $OLD_PERF_SERVER_IP → $NEW_PERF_SERVER_IP"
[[ -n "$NEW_PERF_SERVER_USER" ]] && echo "  PERF_SERVER_USER: $OLD_PERF_SERVER_USER → $NEW_PERF_SERVER_USER"
echo ""

# Detect current WebUI IPs dynamically from app.py (may differ from $OLD_*
# if this is the first run on a freshly cloned setup)
WEBUI_APP="$PROJECT_DIR/webui/backend/app.py"
if [[ -f "$WEBUI_APP" ]]; then
    CUR_WEBUI_VPLMN=$(grep '"local"' "$WEBUI_APP" | grep -oP '"ip":\s*"\K[^"]+' | head -1)
    CUR_WEBUI_HPLMN=$(grep '"remote"' "$WEBUI_APP" | grep -oP '"host":\s*"\K[^"]+' | head -1)
    CUR_WEBUI_HPLMN_USER=$(grep '"remote"' "$WEBUI_APP" | grep -oP '"user":\s*"\K[^"]+' | head -1)
    CUR_WEBUI_VPLMN_USER=$(grep -oP '^VPLMN_USER\s*=\s*"\K[^"]+' "$WEBUI_APP" | head -1)
    CUR_SERVER_IP=$(grep -oP '^SERVER_IP\s*=\s*"\K[^"]+' "$WEBUI_APP" | head -1)
    CUR_SERVER_USER=$(grep -oP '^SERVER_USER\s*=\s*"\K[^"]+' "$WEBUI_APP" | head -1)
    [[ -n "$CUR_WEBUI_VPLMN" && "$CUR_WEBUI_VPLMN" != "$NEW_VPLMN_IP" ]] && \
        echo "  WebUI VPLMN: $CUR_WEBUI_VPLMN → $NEW_VPLMN_IP"
    [[ -n "$CUR_WEBUI_HPLMN" && "$CUR_WEBUI_HPLMN" != "$NEW_HPLMN_IP" ]] && \
        echo "  WebUI HPLMN: $CUR_WEBUI_HPLMN → $NEW_HPLMN_IP"
    [[ -n "$NEW_HPLMN_USER" && -n "$CUR_WEBUI_HPLMN_USER" && "$CUR_WEBUI_HPLMN_USER" != "$NEW_HPLMN_USER" ]] && \
        echo "  WebUI HPLMN user: $CUR_WEBUI_HPLMN_USER → $NEW_HPLMN_USER"
    [[ -n "$NEW_VPLMN_USER" && -n "$CUR_WEBUI_VPLMN_USER" && "$CUR_WEBUI_VPLMN_USER" != "$NEW_VPLMN_USER" ]] && \
        echo "  WebUI VPLMN user: $CUR_WEBUI_VPLMN_USER → $NEW_VPLMN_USER"
    [[ -n "$NEW_PERF_SERVER_IP" && -n "$CUR_SERVER_IP" && "$CUR_SERVER_IP" != "$NEW_PERF_SERVER_IP" ]] && \
        echo "  WebUI SERVER_IP: $CUR_SERVER_IP → $NEW_PERF_SERVER_IP"
    [[ -n "$NEW_PERF_SERVER_USER" && -n "$CUR_SERVER_USER" && "$CUR_SERVER_USER" != "$NEW_PERF_SERVER_USER" ]] && \
        echo "  WebUI SERVER_USER: $CUR_SERVER_USER → $NEW_PERF_SERVER_USER"
fi

echo ""
read -p "Proceed? (y/n): " confirm
[[ ! $confirm =~ ^[Yy]$ ]] && { echo "Cancelled."; exit 0; }

echo ""
echo "Updating files..."

# Count occurrences of old IPs before replacement (for verification at the end)
OLD_VPLMN_ESC=$(printf '%s' "$OLD_VPLMN_IP" | sed 's/\./\\./g')
OLD_HPLMN_ESC=$(printf '%s' "$OLD_HPLMN_IP" | sed 's/\./\\./g')
VPLMN_OLD_COUNT=$(grep -roP "${OLD_VPLMN_ESC}(?!\d)" \
    "$PROJECT_DIR/docker/upf-docker" "$PROJECT_DIR/docker/smf-docker" \
    "$PROJECT_DIR/docker-compose.yml" "$PROJECT_DIR/docker/sepp-docker" \
    "$PROJECT_DIR/testbed_automation.sh" \
    "$PROJECT_DIR/docker/ipsectunnel" \
    "$PROJECT_DIR/webui" 2>/dev/null | grep -v ".bak." | grep -v "configure_ip_from_env.sh" | wc -l)
HPLMN_OLD_COUNT=$(grep -roP "${OLD_HPLMN_ESC}(?!\d)" \
    "$PROJECT_DIR/docker/upf-docker" "$PROJECT_DIR/docker/smf-docker" \
    "$PROJECT_DIR/docker-compose.yml" "$PROJECT_DIR/docker/sepp-docker" \
    "$PROJECT_DIR/testbed_automation.sh" \
    "$PROJECT_DIR/docker/ipsectunnel" \
    "$PROJECT_DIR/webui" 2>/dev/null | grep -v ".bak." | grep -v "configure_ip_from_env.sh" | wc -l)

# ── Helpers ──
# Match any IPv4 on lines tagged with # VPLMN_IP or # HPLMN_IP comment,
# regardless of what value is currently there.
do_sed_vplmn() {
    local file="$PROJECT_DIR/$1"
    [[ -f "$file" ]] || { echo "  SKIP (not found): $1"; return; }
    sed -i -E "s/([0-9]{1,3}\.){3}[0-9]{1,3}(.*# VPLMN_IP)/$NEW_VPLMN_IP\2/g" "$file"
    echo "  ✓ $1"
}

do_sed_hplmn() {
    local file="$PROJECT_DIR/$1"
    [[ -f "$file" ]] || { echo "  SKIP (not found): $1"; return; }
    sed -i -E "s/([0-9]{1,3}\.){3}[0-9]{1,3}(.*# HPLMN_IP)/$NEW_HPLMN_IP\2/g" "$file"
    echo "  ✓ $1"
}

# ── Open5GS service configs (VPLMN IP) ──
echo ""
echo "[ Open5GS configs — VPLMN IP ]"
do_sed_vplmn "docker/upf-docker/upf.yaml"
do_sed_vplmn "docker/upf-docker/upf_tls.yaml"
do_sed_vplmn "docker/smf-docker/smf.yaml"
do_sed_vplmn "docker/smf-docker/smf_tls.yaml"

# ── Open5GS service configs (HPLMN IP) ──
echo ""
echo "[ Open5GS configs — HPLMN IP ]"
do_sed_hplmn "docker-compose.yml"
do_sed_hplmn "docker/sepp-docker/sepp.yaml"

# ── Testbed shell scripts (anchored HPLMN_IP line) ──
echo ""
echo "[ Testbed scripts ]"
for f in testbed_automation.sh; do
    file="$PROJECT_DIR/$f"
    [[ -f "$file" ]] || { echo "  SKIP (not found): $f"; continue; }
    sed -i "s/^HPLMN_IP=\"[^\"]*\"/HPLMN_IP=\"$NEW_HPLMN_IP\"/" "$file"
    echo "  ✓ $f (HPLMN_IP)"
    if [[ -n "$NEW_HPLMN_USER" ]]; then
        sed -i "s/^REMOTE_PC_USER=\"[^\"]*\"/REMOTE_PC_USER=\"$NEW_HPLMN_USER\"/" "$file"
        echo "  ✓ $f (REMOTE_PC_USER)"
    fi
    if [[ -n "$NEW_PERF_SERVER_IP" ]]; then
        sed -i "s/^SERVER_IP=\"[^\"]*\"/SERVER_IP=\"$NEW_PERF_SERVER_IP\"/" "$file"
        echo "  ✓ $f (SERVER_IP)"
    fi
    if [[ -n "$NEW_PERF_SERVER_USER" ]]; then
        sed -i "s/^SERVER_USER=\"[^\"]*\"/SERVER_USER=\"$NEW_PERF_SERVER_USER\"/" "$file"
        echo "  ✓ $f (SERVER_USER)"
    fi
done

# ── Dongle script (VPLMN_USER only — it SSHes to the VPLMN, not the HPLMN,
#    and declares no HPLMN_IP/SERVER_* vars, so it can't join the loop above) ──
dongle="$PROJECT_DIR/testbed_automation_dongle.sh"
if [[ ! -f "$dongle" ]]; then
    echo "  SKIP (not found): testbed_automation_dongle.sh"
elif [[ -z "$NEW_VPLMN_USER" ]]; then
    echo "  SKIP: VPLMN_USER not set in .env (testbed_automation_dongle.sh)"
else
    sed -i "s/^VPLMN_USER=\"[^\"]*\"/VPLMN_USER=\"$NEW_VPLMN_USER\"/" "$dongle"
    echo "  ✓ testbed_automation_dongle.sh (VPLMN_USER)"
fi

# ── Test configs — performance server IP ──
# The configs/*.conf set is generated by configs/generate_confs.sh from a single
# SERVER_IP variable, so we rewrite THAT variable (tagged `# PERF_SERVER_IP`) and
# regenerate — the generated files themselves are never edited in place. The
# hand-written roaming_*.conf at the project root are not generated, so they keep
# the per-file rewrite below: value-agnostic (forces the perf-server keys to the
# .env IP no matter what they hold), touching IPERF_SERVER_IP, SERVER_IP, the
# IPv4 host in DOWNLOAD_TEST_URL / VIDEO_TEST_URL, and PING_TARGET only when it
# currently equals that file's perf IP (so a deliberate 8.8.8.8 is left alone).
# Commented lines and hostname (non-IPv4) URLs are never touched.
echo ""
echo "[ Test configs — performance server IP ]"
if [[ -z "$NEW_PERF_SERVER_IP" ]]; then
    echo "  SKIP: PERF_SERVER_IP not set in .env"
else
    # 1) generator variable, then regenerate configs/*.conf with the new IP
    GEN="$PROJECT_DIR/configs/generate_confs.sh"
    if [[ -f "$GEN" ]]; then
        sed -i -E "s|^(SERVER_IP=\")([0-9]{1,3}\.){3}[0-9]{1,3}(\"[[:space:]]*# PERF_SERVER_IP)|\1${NEW_PERF_SERVER_IP}\3|" "$GEN"
        echo "  ✓ configs/generate_confs.sh (SERVER_IP)"
        if bash "$GEN" >/dev/null 2>&1; then
            echo "  ✓ regenerated configs/*.conf from generator"
        else
            echo "  ⚠️  generate_confs.sh failed — configs/*.conf not regenerated"
        fi
    else
        echo "  SKIP (not found): configs/generate_confs.sh"
    fi

    # 2) hand-written, non-generated configs — per-file rewrite. main.conf is the
    #    batch parameter matrix (not template output, so not regenerated) and the
    #    roaming_*.conf are hand-written scenarios; both carry the perf-server IP.
    IPV4_RE='([0-9]{1,3}\.){3}[0-9]{1,3}'
    perf_cfg_files=0
    for file in "$PROJECT_DIR"/configs/main.conf "$PROJECT_DIR"/roaming_*.conf; do
        [[ -f "$file" ]] || continue
        tmp=$(mktemp); cp "$file" "$tmp"

        # bare-IP perf keys (active lines only; only IPv4 values; not *_PORT)
        for k in SERVER_IP IPERF_SERVER_IP; do
            sed -i -E "s#^([[:space:]]*${k}=)${IPV4_RE}([[:space:]].*)?\$#\1${NEW_PERF_SERVER_IP}\3#" "$tmp"
        done
        # URL host: rewrite only the IPv4 host between :// and the next :/
        for k in DOWNLOAD_TEST_URL VIDEO_TEST_URL; do
            sed -i -E "s#^([[:space:]]*${k}=\"?[a-zA-Z][a-zA-Z0-9+.-]*://)${IPV4_RE}#\1${NEW_PERF_SERVER_IP}#" "$tmp"
        done
        # PING_TARGET: only if it currently points at this file's perf-server IP
        cur_perf=$(grep -E '^[[:space:]]*(IPERF_SERVER_IP|SERVER_IP)=' "$file" \
                     | grep -vE '^[[:space:]]*#' | head -1 | cut -d= -f2 | tr -d '[:space:]')
        if [[ "$cur_perf" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            cur_perf_esc=${cur_perf//./\\.}
            sed -i -E "s#^([[:space:]]*PING_TARGET=)${cur_perf_esc}([[:space:]].*)?\$#\1${NEW_PERF_SERVER_IP}\2#" "$tmp"
        fi

        if ! diff -q "$file" "$tmp" >/dev/null; then
            n=$(diff "$file" "$tmp" | grep -cE '^>')
            cp "$tmp" "$file"
            echo "  ✓ ${file#$PROJECT_DIR/} ($n line(s))"
            perf_cfg_files=$((perf_cfg_files + 1))
        fi
        rm -f "$tmp"
    done
    [[ "$perf_cfg_files" -eq 0 ]] && echo "  (main.conf + roaming_*.conf already at $NEW_PERF_SERVER_IP)"
fi

# ── IPsec scripts (hardcoded IPs) ──
echo ""
echo "[ IPsec scripts ]"
for f in \
    docker/ipsectunnel/01_setup_ca.sh \
    docker/ipsectunnel/ipsec_certificates/pc1/03_setup_ipsec_pc1_cert.sh \
    docker/ipsectunnel/ipsec_certificates/pc2/03_setup_ipsec_pc2_cert.sh; do
    file="$PROJECT_DIR/$f"
    [[ -f "$file" ]] || { echo "  SKIP (not found): $f"; continue; }
    sed -i "s/^VPLMN_IP=\"[^\"]*\"/VPLMN_IP=\"$NEW_VPLMN_IP\"/" "$file"
    sed -i "s/^HPLMN_IP=\"[^\"]*\"/HPLMN_IP=\"$NEW_HPLMN_IP\"/" "$file"
    sed -i "s/^# PC1: [0-9.]\+\(.*# VPLMN_IP\)/# PC1: $NEW_VPLMN_IP\1/" "$file"
    sed -i "s/^# PC2: [0-9.]\+\(.*# HPLMN_IP\)/# PC2: $NEW_HPLMN_IP\1/" "$file"
    echo "  ✓ $f"
done
for f in docker/ipsectunnel/ipsec_update_configs/esp_config.sh; do
    file="$PROJECT_DIR/$f"
    [[ -f "$file" ]] || { echo "  SKIP (not found): $f"; continue; }
    sed -i "s/^HPLMN_IP=\"[^\"]*\"/HPLMN_IP=\"$NEW_HPLMN_IP\"/" "$file"
    # PC2 SSH user is the HPLMN user (not the perf-server user)
    [[ -n "$NEW_HPLMN_USER" ]] && sed -i "s/^REMOTE_PC_USER=\"[^\"]*\"/REMOTE_PC_USER=\"$NEW_HPLMN_USER\"/" "$file"
    echo "  ✓ $f"
done

# ── IPsec README files (PC1 → VPLMN IP, PC2 → HPLMN IP) ──
pc1_readme="$PROJECT_DIR/docker/ipsectunnel/ipsec_certificates/pc1/README.txt"
pc2_readme="$PROJECT_DIR/docker/ipsectunnel/ipsec_certificates/pc2/README.txt"
if [[ -f "$pc1_readme" ]]; then
    sed -i -E "s/^(IP Address: ).*/\1$NEW_VPLMN_IP/" "$pc1_readme"
    echo "  ✓ docker/ipsectunnel/ipsec_certificates/pc1/README.txt"
else
    echo "  SKIP (not found): docker/ipsectunnel/ipsec_certificates/pc1/README.txt"
fi
if [[ -f "$pc2_readme" ]]; then
    sed -i -E "s/^(IP Address: ).*/\1$NEW_HPLMN_IP/" "$pc2_readme"
    echo "  ✓ docker/ipsectunnel/ipsec_certificates/pc2/README.txt"
else
    echo "  SKIP (not found): docker/ipsectunnel/ipsec_certificates/pc2/README.txt"
fi

# ── WebUI — python3 targeted replacements ──
echo ""
echo "[ WebUI ]"

python3 - "$PROJECT_DIR" "$NEW_VPLMN_IP" "$NEW_HPLMN_IP" "${NEW_HPLMN_USER:-}" "${NEW_PERF_SERVER_IP:-}" "${NEW_PERF_SERVER_USER:-}" "${NEW_VPLMN_USER:-}" << 'PYEOF'
import re, sys, os

base       = sys.argv[1]
new_vplmn  = sys.argv[2]
new_hplmn  = sys.argv[3]
new_hplmn_user       = sys.argv[4] if len(sys.argv) > 4 else ''
new_perf_server_ip   = sys.argv[5] if len(sys.argv) > 5 else ''
new_perf_server_user = sys.argv[6] if len(sys.argv) > 6 else ''
new_vplmn_user       = sys.argv[7] if len(sys.argv) > 7 else ''

# ── backend/app.py ──
app_path = os.path.join(base, "webui/backend/app.py")
if os.path.isfile(app_path):
    with open(app_path) as f:
        content = f.read()

    # Detect current IPs — each field detected independently
    m = re.search(r'"local".*?"ip":\s*"([\d.]+)"', content)
    old_vplmn = m.group(1) if m else None
    m = re.search(r'"remote".*?"host":\s*"([\d.]+)"', content)
    old_hplmn = m.group(1) if m else None
    m = re.search(r'^VPLMN_IP\s*=\s*"([\d.]+)"', content, re.MULTILINE)
    old_vplmn_var = m.group(1) if m else None
    m = re.search(r'^HPLMN_IP\s*=\s*"([\d.]+)"', content, re.MULTILINE)
    old_hplmn_var = m.group(1) if m else None

    if old_vplmn:
        esc = old_vplmn.replace('.', r'\.')
        content = re.sub(rf'"local"(\s*:\s*\{{[^}}]*"ip":\s*"){esc}"',
                         lambda x: x.group(0).replace(old_vplmn, new_vplmn), content)
    if old_vplmn_var:
        esc = old_vplmn_var.replace('.', r'\.')
        content = re.sub(rf'^VPLMN_IP\s*=\s*"{esc}"',
                         f'VPLMN_IP = "{new_vplmn}"', content, flags=re.MULTILINE)
    if old_hplmn:
        esc = old_hplmn.replace('.', r'\.')
        content = re.sub(rf'"remote"(\s*:\s*\{{[^}}]*)"host":\s*"{esc}"',
                         lambda x: x.group(0).replace(old_hplmn, new_hplmn), content)
        content = re.sub(rf'"remote"(\s*:\s*\{{[^}}]*)"ip":\s*"{esc}"',
                         lambda x: x.group(0).replace(old_hplmn, new_hplmn), content)
    if old_hplmn_var:
        esc = old_hplmn_var.replace('.', r'\.')
        content = re.sub(rf'^HPLMN_IP\s*=\s*"{esc}"',
                         f'HPLMN_IP = "{new_hplmn}"', content, flags=re.MULTILINE)

    # Update HPLMN SSH user module-level variable (CONFIG["remote"]["user"] = HPLMN_USER)
    if new_hplmn_user:
        content = re.sub(
            r'^(HPLMN_USER\s*=\s*")[^"]*"',
            rf'\g<1>{new_hplmn_user}"', content, flags=re.MULTILINE)

    # Update VPLMN SSH user module-level variable (CONFIG["local"]["user"] = VPLMN_USER)
    if new_vplmn_user:
        content = re.sub(
            r'^(VPLMN_USER\s*=\s*")[^"]*"',
            rf'\g<1>{new_vplmn_user}"', content, flags=re.MULTILINE)

    # Update performance server IP and user
    if new_perf_server_ip:
        content = re.sub(
            r'^(PERF_SERVER_IP\s*=\s*")[^"]*(")',
            rf'\g<1>{new_perf_server_ip}\g<2>', content, flags=re.MULTILINE)
    if new_perf_server_user:
        content = re.sub(
            r'^(PERF_SERVER_USER\s*=\s*")[^"]*(")',
            rf'\g<1>{new_perf_server_user}\g<2>', content, flags=re.MULTILINE)

    with open(app_path, 'w') as f:
        f.write(content)
    print(f"  ✓ webui/backend/app.py")

# ── frontend/index.html ──
html_path = os.path.join(base, "webui/frontend/index.html")
if os.path.isfile(html_path):
    with open(html_path) as f:
        content = f.read()

    # Target the const declarations at the top of the script block — same pattern
    # as app.py. This avoids any substring-match risk and survives manual IP edits.
    content = re.sub(r'(const VPLMN_IP\s*=\s*")[\d.]+"', f'\\g<1>{new_vplmn}"', content)
    content = re.sub(r'(const HPLMN_IP\s*=\s*")[\d.]+"', f'\\g<1>{new_hplmn}"', content)
    if new_perf_server_ip:
        content = re.sub(r'(const SERVER_IP\s*=\s*")[\d.]+"', f'\\g<1>{new_perf_server_ip}"', content)
    if new_perf_server_user:
        content = re.sub(r'(const SERVER_USER\s*=\s*")[^"]+"', f'\\g<1>{new_perf_server_user}"', content)

    with open(html_path, 'w') as f:
        f.write(content)
    print(f"  ✓ webui/frontend/index.html")

# ── webui/start.sh ──
startsh_path = os.path.join(base, "webui/start.sh")
if os.path.isfile(startsh_path):
    with open(startsh_path) as f:
        content = f.read()

    # Target the HPLMN_IP= declaration at the top of the script
    content = re.sub(r'(HPLMN_IP=")[\d.]+"', f'\\g<1>{new_hplmn}"', content)

    with open(startsh_path, 'w') as f:
        f.write(content)
    print(f"  ✓ webui/start.sh")
PYEOF

# ── Update this script's OLD_* values for next run ──
echo ""
echo "[ Updating OLD IPs in this script ]"
SELF="$SCRIPT_DIR/configure_ip_from_env.sh"
sed -i "s/^OLD_VPLMN_IP=\"[^\"]*\"/OLD_VPLMN_IP=\"$NEW_VPLMN_IP\"/" "$SELF"
sed -i "s/^OLD_HPLMN_IP=\"[^\"]*\"/OLD_HPLMN_IP=\"$NEW_HPLMN_IP\"/" "$SELF"
[[ -n "$NEW_HPLMN_USER" ]]       && sed -i "s/^OLD_HPLMN_USER=\"[^\"]*\"/OLD_HPLMN_USER=\"$NEW_HPLMN_USER\"/" "$SELF"
[[ -n "$NEW_PERF_SERVER_IP" ]]   && sed -i "s/^OLD_PERF_SERVER_IP=\"[^\"]*\"/OLD_PERF_SERVER_IP=\"$NEW_PERF_SERVER_IP\"/" "$SELF"
[[ -n "$NEW_PERF_SERVER_USER" ]] && sed -i "s/^OLD_PERF_SERVER_USER=\"[^\"]*\"/OLD_PERF_SERVER_USER=\"$NEW_PERF_SERVER_USER\"/" "$SELF"
[[ -n "$NEW_VPLMN_USER" ]]       && sed -i "s/^OLD_VPLMN_USER=\"[^\"]*\"/OLD_VPLMN_USER=\"$NEW_VPLMN_USER\"/" "$SELF"
echo "  ✓ configure_ip_from_env.sh"

# ── Verification ──
echo ""
echo "=========================================="
echo "  Verification"
echo "=========================================="
# Count occurrences of new IPs and compare against pre-update counts.
# Escape dots and use (?!\d) lookahead to avoid substring false positives.
VPLMN_ESC=$(printf '%s' "$NEW_VPLMN_IP" | sed 's/\./\\./g')
HPLMN_ESC=$(printf '%s' "$NEW_HPLMN_IP" | sed 's/\./\\./g')
VPLMN_NEW_COUNT=$(grep -roP "${VPLMN_ESC}(?!\d)" \
    "$PROJECT_DIR/docker/upf-docker" "$PROJECT_DIR/docker/smf-docker" \
    "$PROJECT_DIR/docker-compose.yml" "$PROJECT_DIR/docker/sepp-docker" \
    "$PROJECT_DIR/testbed_automation.sh" \
    "$PROJECT_DIR/docker/ipsectunnel" \
    "$PROJECT_DIR/webui" 2>/dev/null | grep -v ".bak." | grep -v "configure_ip_from_env.sh" | wc -l)
HPLMN_NEW_COUNT=$(grep -roP "${HPLMN_ESC}(?!\d)" \
    "$PROJECT_DIR/docker/upf-docker" "$PROJECT_DIR/docker/smf-docker" \
    "$PROJECT_DIR/docker-compose.yml" "$PROJECT_DIR/docker/sepp-docker" \
    "$PROJECT_DIR/testbed_automation.sh" \
    "$PROJECT_DIR/docker/ipsectunnel" \
    "$PROJECT_DIR/webui" 2>/dev/null | grep -v ".bak." | grep -v "configure_ip_from_env.sh" | wc -l)
if [[ "$VPLMN_NEW_COUNT" -eq "$VPLMN_OLD_COUNT" ]]; then
    echo "  ✓ VPLMN: $VPLMN_NEW_COUNT/$VPLMN_OLD_COUNT occurrences updated ($OLD_VPLMN_IP → $NEW_VPLMN_IP)"
else
    echo "  ✗ VPLMN: $VPLMN_NEW_COUNT/$VPLMN_OLD_COUNT occurrences found for $NEW_VPLMN_IP (expected $VPLMN_OLD_COUNT)"
fi
if [[ "$HPLMN_NEW_COUNT" -eq "$HPLMN_OLD_COUNT" ]]; then
    echo "  ✓ HPLMN: $HPLMN_NEW_COUNT/$HPLMN_OLD_COUNT occurrences updated ($OLD_HPLMN_IP → $NEW_HPLMN_IP)"
else
    echo "  ✗ HPLMN: $HPLMN_NEW_COUNT/$HPLMN_OLD_COUNT occurrences found for $NEW_HPLMN_IP (expected $HPLMN_OLD_COUNT)"
fi
echo ""
echo "✓ Done! Next steps:"
echo "  1. Restart services: docker compose up"
echo "  2. Restart WebUI:    cd webui && ./start.sh restart"
echo ""
