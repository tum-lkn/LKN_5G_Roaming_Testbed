#!/usr/bin/env bash
# regenerate_nf_certificates.sh
# Regenerate every Open5GS NF SBI certificate in this repo (VPLMN + HPLMN),
# signed by the shared ca.localdomain CA, valid for ~10 years.
#
# Scope: NF SBI/TLS certs only (amf ausf bsf nrf nssf pcf scp sepp smf udm udr).
#        It does NOT touch the IPsec PKI (N9: docker/ipsectunnel/, N4:
#        docker/n4-ipsec/) — those are a separate CA/cert set with their own
#        install scripts. It does NOT regenerate the CA itself (REGEN_CA=false)
#        so existing trust anchors keep working; flip REGEN_CA=true to rebuild it.
#
# Run from the repo root:  ./regenerate_nf_certificates.sh
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
DAYS=3650                       # ~10 years
KEYBITS=2048
REGEN_CA=false                  # true = also regenerate the shared CA (forces full re-sign)
PLMNS=(VPLMN HPLMN)             # trees present in this repo
BACKUP_SUFFIX=".bak.$(date +%Y%m%d-%H%M%S)"

# Per-PLMN MCC/MNC and SEPP alias
declare -A MCC=( [VPLMN]=999 [HPLMN]=001 )
declare -A MNC=( [VPLMN]=071 [HPLMN]=001 )
declare -A SEPP_ALIAS=( [VPLMN]=sepp1 [HPLMN]=sepp2 )

# NF groups (naming conventions differ)
FQDN_NFS=(nrf ausf bsf nssf smf udm)      # CN = <nf>.5gc.mnc<MNC>.mcc<MCC>.3gppnetwork.org
LOCAL_NFS=(amf pcf scp udr)               # CN = <nf>.localdomain
# sepp handled specially (extra sepp<N>.localdomain SAN)

SUBJ_BASE="/C=US/ST=State/L=Locality/O=Open5GS"

# ---------------------------------------------------------------------------
# Locate the shared CA (any NF files/ dir that holds both ca.crt and ca.key)
# ---------------------------------------------------------------------------
find_ca() {
    local plmn="$1" d
    for d in "$plmn"/docker/*-docker/files; do
        [ -f "$d/ca.crt" ] && [ -f "$d/ca.key" ] && { echo "$d"; return 0; }
    done
    return 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Regenerate the shared CA (optional)
# ---------------------------------------------------------------------------
regen_ca() {
    local cadir="$1"
    echo ">> Regenerating shared CA in $cadir"
    cp -a "$cadir/ca.crt" "$cadir/ca.crt$BACKUP_SUFFIX"
    cp -a "$cadir/ca.key" "$cadir/ca.key$BACKUP_SUFFIX"
    openssl req -x509 -new -nodes -newkey rsa:4096 -sha256 -days "$DAYS" \
        -keyout "$cadir/ca.key" -out "$cadir/ca.crt" \
        -subj "/CN=ca.localdomain/C=KO/ST=Seoul/O=NeoPlane"
}

# ---------------------------------------------------------------------------
# Sign one NF leaf cert
#   sign_nf <plmn> <nf> <cn> <san>
# ---------------------------------------------------------------------------
sign_nf() {
    local plmn="$1" nf="$2" cn="$3" san="$4"
    local dir="$plmn/docker/${nf}-docker/files"
    [ -d "$dir" ] || { echo "   -- skip $plmn/$nf (no files dir)"; return 0; }

    local ou; ou="$(echo "$nf" | tr '[:lower:]' '[:upper:]')"

    # Back up whatever is there now
    [ -f "$dir/${nf}.crt" ] && cp -a "$dir/${nf}.crt" "$dir/${nf}.crt$BACKUP_SUFFIX"
    [ -f "$dir/${nf}.key" ] && cp -a "$dir/${nf}.key" "$dir/${nf}.key$BACKUP_SUFFIX"

    printf 'subjectAltName=%s\n' "$san" > "$TMP/san_${plmn}_${nf}.cnf"

    openssl req -new -newkey "rsa:$KEYBITS" -nodes \
        -keyout "$dir/${nf}.key" -out "$TMP/${nf}.csr" \
        -subj "$SUBJ_BASE/OU=${ou}/CN=${cn}" 2>/dev/null

    openssl x509 -req -in "$TMP/${nf}.csr" \
        -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
        -out "$dir/${nf}.crt" -days "$DAYS" -sha256 \
        -extfile "$TMP/san_${plmn}_${nf}.cnf" 2>/dev/null

    # Make sure the CA cert sits alongside every NF (trust chain)
    [ "$CA_CRT" -ef "$dir/ca.crt" ] || cp -f "$CA_CRT" "$dir/ca.crt"

    echo "   ✓ ${plmn}/${nf}: CN=${cn}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
for plmn in "${PLMNS[@]}"; do
    [ -d "$plmn/docker" ] || { echo "!! $plmn/docker not found, skipping"; continue; }
    echo "==================== $plmn (mcc${MCC[$plmn]} mnc${MNC[$plmn]}) ===================="

    CA_DIR="$(find_ca "$plmn")" || { echo "!! no ca.crt+ca.key found under $plmn, skipping"; continue; }
    [ "$REGEN_CA" = "true" ] && regen_ca "$CA_DIR"
    CA_CRT="$CA_DIR/ca.crt"
    CA_KEY="$CA_DIR/ca.key"
    echo ">> Signing off CA: $CA_CRT"

    # 3GPP-FQDN NFs
    for nf in "${FQDN_NFS[@]}"; do
        cn="${nf}.5gc.mnc${MNC[$plmn]}.mcc${MCC[$plmn]}.3gppnetwork.org"
        san="DNS:${cn},DNS:${nf}.localdomain,DNS:open5gs-${nf}"
        sign_nf "$plmn" "$nf" "$cn" "$san"
    done

    # .localdomain NFs
    for nf in "${LOCAL_NFS[@]}"; do
        cn="${nf}.localdomain"
        san="DNS:${nf}.localdomain,DNS:open5gs-${nf}"
        sign_nf "$plmn" "$nf" "$cn" "$san"
    done

    # SEPP (extra sepp<N>.localdomain SAN so N32 peer-name matching works)
    alias="${SEPP_ALIAS[$plmn]}"
    sign_nf "$plmn" "sepp" "sepp.localdomain" \
        "DNS:sepp.localdomain,DNS:${alias}.localdomain,DNS:open5gs-sepp"
done

echo
echo "Done. Backups of replaced files were kept with suffix: $BACKUP_SUFFIX"
echo "Next steps:"
echo "  1. Sync the source-of-truth backups:   (per PLMN)  ./lib/setup/collect_certificates.sh"
echo "  2. HPLMN tree lives on PC2 — rsync HPLMN/docker/*/files to PC2, or run this there too."
echo "  3. Rebuild is NOT required (certs are bind-mounted); restart the core to pick them up:"
echo "       docker compose up -d --force-recreate"
