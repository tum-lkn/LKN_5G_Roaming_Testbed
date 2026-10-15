#!/bin/bash

# Script to redistribute certificates and keys from backup to each NF
# Author: Auto-generated script for Open5GS testbed certificate management

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default backup directory
CERTS_BACKUP_DIR="./lib/setup/certificates_backup"

echo -e "${GREEN}=== Open5GS Certificate Redistribution Script ===${NC}"
echo -e "${YELLOW}This script will redistribute certificates and keys to NF containers${NC}\n"

# Check if backup directory exists
if [ ! -d "${CERTS_BACKUP_DIR}" ]; then
    echo -e "${RED}Error: Backup directory '${CERTS_BACKUP_DIR}' not found!${NC}"
    echo -e "${YELLOW}Usage:${NC}"
    echo -e "  1. If you have a tarball: tar -xzf <tarball_name>.tar.gz"
    echo -e "  2. Run this script from the testbed root directory"
    echo -e "  3. Or specify backup directory: CERTS_BACKUP_DIR=/path/to/backup $0"
    exit 1
fi

echo -e "${GREEN}Using backup directory: ${CERTS_BACKUP_DIR}${NC}\n"

# List of NFs
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

echo -e "${GREEN}Starting certificate redistribution...${NC}\n"

RESTORED_COUNT=0
FAILED_COUNT=0
SKIPPED_COUNT=0

for nf in "${NFS[@]}"; do
    BACKUP_NF_DIR="${CERTS_BACKUP_DIR}/${nf}"
    TARGET_NF_DIR="docker/${nf}/files"
    
    if [ -d "${BACKUP_NF_DIR}" ] && [ "$(ls -A ${BACKUP_NF_DIR})" ]; then
        echo -e "${YELLOW}Processing ${nf}...${NC}"
        
        # Create target directory if it doesn't exist
        if [ ! -d "${TARGET_NF_DIR}" ]; then
            mkdir -p "${TARGET_NF_DIR}"
            echo "  ✓ Created directory ${TARGET_NF_DIR}"
        fi
        
        # Copy all certificate and key files
        COPIED_FILES=false
        
        for file in "${BACKUP_NF_DIR}"/*; do
            if [ -f "$file" ]; then
                filename=$(basename "$file")
                cp "$file" "${TARGET_NF_DIR}/${filename}"
                echo "  ✓ Restored ${filename}"
                COPIED_FILES=true
            fi
        done
        
        if [ "$COPIED_FILES" = true ]; then
            # Set proper permissions
            chmod 644 "${TARGET_NF_DIR}"/*.crt 2>/dev/null || true
            chmod 600 "${TARGET_NF_DIR}"/*.key 2>/dev/null || true
            
            RESTORED_COUNT=$((RESTORED_COUNT + 1))
            echo -e "  ${GREEN}✓ ${nf} certificates restored${NC}"
        fi
        echo ""
    else
        if [ ! -d "${BACKUP_NF_DIR}" ]; then
            echo -e "${YELLOW}⚠ No backup found for ${nf} - skipping${NC}\n"
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        elif [ ! "$(ls -A ${BACKUP_NF_DIR})" ]; then
            echo -e "${YELLOW}⚠ Backup directory for ${nf} is empty - skipping${NC}\n"
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        fi
    fi
done

# Display summary
echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}Certificate redistribution complete!${NC}"
echo -e "Restored to ${GREEN}${RESTORED_COUNT}${NC} NFs"
if [ ${SKIPPED_COUNT} -gt 0 ]; then
    echo -e "Skipped ${YELLOW}${SKIPPED_COUNT}${NC} NFs (no backup)"
fi
if [ ${FAILED_COUNT} -gt 0 ]; then
    echo -e "Failed for ${RED}${FAILED_COUNT}${NC} NFs"
fi
echo -e "${GREEN}================================${NC}\n"

echo -e "${YELLOW}Next steps:${NC}"
echo -e "  1. Verify certificates are in place"
echo -e "  2. Rebuild containers if necessary: ${GREEN}./build_all.sh${NC}"
echo -e "  3. Start your testbed: ${GREEN}./start_all_nfs.sh${NC}\n"

exit 0
