#!/bin/bash

# Collects every NF's certificates and keys into lib/setup/certificates_backup/.
# The reverse of redistribute_certificates.sh, which copies them back out.
#
# Run from the testbed root (VPLMN), not from inside lib/setup/:
#   cd ~/LKN_5G_Roaming_Testbed/VPLMN && bash lib/setup/collect_certificates.sh
# Its paths are relative to the testbed root, and it creates the backup dir
# rather than requiring it, so a wrong working directory would otherwise
# silently produce an empty backup instead of failing — hence the guard below.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if we're in the correct directory
if [ ! -f "docker-compose.yml" ]; then
    echo -e "${RED}Error: docker-compose.yml not found!${NC}"
    echo -e "${YELLOW}Please run this script from the testbed root directory (VPLMN)${NC}"
    exit 1
fi

CERTS_BACKUP_DIR="./lib/setup/certificates_backup"

echo -e "${GREEN}=== Open5GS Certificate Collection Script ===${NC}"
echo -e "${YELLOW}This script will collect all certificates and keys from NF containers${NC}\n"

# Create backup directory structure
mkdir -p "${CERTS_BACKUP_DIR}"

# List of NFs that typically have certificates
NFS=(
    "amf-docker"
    "smf-docker"
    "ausf-docker"
    "udm-docker"
    "udr-docker"
    "pcf-docker"
    "nrf-docker"
    "nssf-docker"
    "bsf-docker"
    "scp-docker"
    "sepp-docker"
)

echo -e "${GREEN}Starting certificate collection...${NC}\n"

COLLECTED_COUNT=0
FAILED_COUNT=0

for nf in "${NFS[@]}"; do
    NF_DIR="docker/${nf}/files"
    
    if [ -d "${NF_DIR}" ]; then
        echo -e "${YELLOW}Processing ${nf}...${NC}"
        
        # Create NF-specific directory in backup
        mkdir -p "${CERTS_BACKUP_DIR}/${nf}"
        
        # Check and copy certificates and keys
        FOUND_FILES=false
        
        if [ -f "${NF_DIR}/ca.crt" ]; then
            cp "${NF_DIR}/ca.crt" "${CERTS_BACKUP_DIR}/${nf}/"
            echo "  ✓ Copied ca.crt"
            FOUND_FILES=true
        fi
        
        if [ -f "${NF_DIR}/ca.key" ]; then
            cp "${NF_DIR}/ca.key" "${CERTS_BACKUP_DIR}/${nf}/"
            echo "  ✓ Copied ca.key"
            FOUND_FILES=true
        fi
        
        # Extract NF name (e.g., amf from amf-docker)
        NF_NAME="${nf%-docker}"
        
        if [ -f "${NF_DIR}/${NF_NAME}.crt" ]; then
            cp "${NF_DIR}/${NF_NAME}.crt" "${CERTS_BACKUP_DIR}/${nf}/"
            echo "  ✓ Copied ${NF_NAME}.crt"
            FOUND_FILES=true
        fi
        
        if [ -f "${NF_DIR}/${NF_NAME}.key" ]; then
            cp "${NF_DIR}/${NF_NAME}.key" "${CERTS_BACKUP_DIR}/${nf}/"
            echo "  ✓ Copied ${NF_NAME}.key"
            FOUND_FILES=true
        fi
        
        if [ "$FOUND_FILES" = true ]; then
            COLLECTED_COUNT=$((COLLECTED_COUNT + 1))
            echo -e "  ${GREEN}✓ ${nf} certificates collected${NC}"
        else
            echo -e "  ${YELLOW}⚠ No certificates found in ${nf}${NC}"
        fi
        echo ""
    else
        echo -e "${RED}✗ Directory ${NF_DIR} not found${NC}\n"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
done

# Create a manifest file with collection information
MANIFEST_FILE="${CERTS_BACKUP_DIR}/manifest.txt"
echo "Certificate Collection Manifest" > "${MANIFEST_FILE}"
echo "================================" >> "${MANIFEST_FILE}"
echo "Collection Date: $(date)" >> "${MANIFEST_FILE}"
echo "Collection Path: $(pwd)" >> "${MANIFEST_FILE}"
echo "" >> "${MANIFEST_FILE}"
echo "Collected NFs: ${COLLECTED_COUNT}" >> "${MANIFEST_FILE}"
echo "Failed NFs: ${FAILED_COUNT}" >> "${MANIFEST_FILE}"
echo "" >> "${MANIFEST_FILE}"
echo "Directory Structure:" >> "${MANIFEST_FILE}"
tree "${CERTS_BACKUP_DIR}" >> "${MANIFEST_FILE}" 2>/dev/null || find "${CERTS_BACKUP_DIR}" -type f >> "${MANIFEST_FILE}"

echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}Certificate collection complete!${NC}"
echo -e "Collected from ${GREEN}${COLLECTED_COUNT}${NC} NFs"
if [ ${FAILED_COUNT} -gt 0 ]; then
    echo -e "Failed for ${RED}${FAILED_COUNT}${NC} NFs"
fi
echo -e "Backup location: ${GREEN}${CERTS_BACKUP_DIR}${NC}"
echo -e "Manifest file: ${GREEN}${MANIFEST_FILE}${NC}"
echo -e "${GREEN}================================${NC}\n"

echo -e "${YELLOW}To transfer to another PC, copy the '${CERTS_BACKUP_DIR}' folder${NC}\n"

exit 0
