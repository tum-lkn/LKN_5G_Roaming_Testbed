#!/bin/bash

# IPsec IP Address Update Script (v2)
# Updates all IP addresses in the IPsec setup scripts for new testbed
# Handles scripts in ipsec_certificates/pc1/ and ipsec_certificates/pc2/ subdirectories

set -e

echo "=========================================="
echo "IPsec Configuration IP Address Updater"
echo "=========================================="
echo ""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default old IPs (current configuration)
OLD_PC1_IP="10.0.0.10"
OLD_PC2_IP="10.0.0.21"

# Function to validate IP address format
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -ra ADDR <<< "$ip"
        for i in "${ADDR[@]}"; do
            if [ "$i" -gt 255 ]; then
                return 1
            fi
        done
        return 0
    else
        return 1
    fi
}

# Function to update IP in a file
update_ip_in_file() {
    local file=$1
    local old_ip=$2
    local new_ip=$3
    local count
    
    if [ -f "$file" ]; then
        count=$(grep -c "$old_ip" "$file" 2>/dev/null || true)
        if [ "${count:-0}" -gt 0 ]; then
            sed -i "s/$old_ip/$new_ip/g" "$file"
            echo -e "  ${GREEN}✓${NC} Updated $old_ip → $new_ip ($count occurrences) in $(basename $file)"
        fi
    fi
}

# Parse command line arguments
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --old-pc1 IP    Old PC1 IP address (default: $OLD_PC1_IP)"
    echo "  --old-pc2 IP    Old PC2 IP address (default: $OLD_PC2_IP)"
    echo "  --new-pc1 IP    New PC1 IP address (required)"
    echo "  --new-pc2 IP    New PC2 IP address (required)"
    echo "  --dry-run       Show what would be changed without making changes"
    echo "  -h, --help      Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 --new-pc1 192.168.1.10 --new-pc2 192.168.1.21"
    exit 1
}

# Default values
DRY_RUN=false
NEW_PC1_IP=""
NEW_PC2_IP=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --old-pc1)
            OLD_PC1_IP="$2"
            shift 2
            ;;
        --old-pc2)
            OLD_PC2_IP="$2"
            shift 2
            ;;
        --new-pc1)
            NEW_PC1_IP="$2"
            shift 2
            ;;
        --new-pc2)
            NEW_PC2_IP="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            ;;
    esac
done

# Interactive mode if new IPs not provided
if [ -z "$NEW_PC1_IP" ] || [ -z "$NEW_PC2_IP" ]; then
    echo "Interactive Mode - Enter new IP addresses"
    echo "=========================================="
    echo ""
    echo "Current configuration:"
    echo "  PC1 (VPLMN): $OLD_PC1_IP"
    echo "  PC2 (HPLMN): $OLD_PC2_IP"
    echo ""
    
    read -p "Enter NEW PC1 IP address: " NEW_PC1_IP
    read -p "Enter NEW PC2 IP address: " NEW_PC2_IP
    echo ""
fi

# Validate IP addresses
echo "Validating IP addresses..."
if ! validate_ip "$OLD_PC1_IP"; then
    echo -e "${RED}ERROR: Invalid old PC1 IP: $OLD_PC1_IP${NC}"
    exit 1
fi
if ! validate_ip "$OLD_PC2_IP"; then
    echo -e "${RED}ERROR: Invalid old PC2 IP: $OLD_PC2_IP${NC}"
    exit 1
fi
if ! validate_ip "$NEW_PC1_IP"; then
    echo -e "${RED}ERROR: Invalid new PC1 IP: $NEW_PC1_IP${NC}"
    exit 1
fi
if ! validate_ip "$NEW_PC2_IP"; then
    echo -e "${RED}ERROR: Invalid new PC2 IP: $NEW_PC2_IP${NC}"
    exit 1
fi
echo -e "${GREEN}✓ All IP addresses are valid${NC}"
echo ""

# Display changes
echo "=========================================="
echo "IP Address Changes:"
echo "=========================================="
echo ""
echo "  PC1 (VPLMN UPF): $OLD_PC1_IP → $NEW_PC1_IP"
echo "  PC2 (HPLMN UPF): $OLD_PC2_IP → $NEW_PC2_IP"
echo ""

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}DRY RUN MODE - No changes will be made${NC}"
    echo ""
fi

# Find script directory (where this script is located)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Define all possible file locations
declare -a FILE_PATHS=(
    "$SCRIPT_DIR/01_setup_ca.sh"
    "$SCRIPT_DIR/ipsec_certificates/pc1/02_install_certs_pc1.sh"
    "$SCRIPT_DIR/ipsec_certificates/pc1/03_setup_ipsec_pc1_cert.sh"
    "$SCRIPT_DIR/ipsec_certificates/pc1/README.txt"
    "$SCRIPT_DIR/ipsec_certificates/pc2/02_install_certs_pc2.sh"
    "$SCRIPT_DIR/ipsec_certificates/pc2/03_setup_ipsec_pc2_cert.sh"
    "$SCRIPT_DIR/ipsec_certificates/pc2/README.txt"
    # Also check current directory variants
    "./01_setup_ca.sh"
    "./ipsec_certificates/pc1/02_install_certs_pc1.sh"
    "./ipsec_certificates/pc1/03_setup_ipsec_pc1_cert.sh"
    "./ipsec_certificates/pc1/README.txt"
    "./ipsec_certificates/pc2/02_install_certs_pc2.sh"
    "./ipsec_certificates/pc2/03_setup_ipsec_pc2_cert.sh"
    "./ipsec_certificates/pc2/README.txt"
)

# Check which files exist and deduplicate
echo "Scanning for script files..."
echo ""
declare -A FOUND_FILES
for filepath in "${FILE_PATHS[@]}"; do
    if [ -f "$filepath" ]; then
        # Get absolute path to deduplicate
        abs_path=$(realpath "$filepath" 2>/dev/null || echo "$filepath")
        if [ -z "${FOUND_FILES[$abs_path]}" ]; then
            FOUND_FILES[$abs_path]=1
            # Count occurrences
            count1=$(grep -c "$OLD_PC1_IP" "$filepath" 2>/dev/null || true); count1=${count1:-0}
            count2=$(grep -c "$OLD_PC2_IP" "$filepath" 2>/dev/null || true); count2=${count2:-0}
            rel_path="${filepath#$SCRIPT_DIR/}"
            rel_path="${rel_path#./}"
            echo -e "  ${GREEN}✓${NC} Found: $rel_path (PC1 IP: $count1, PC2 IP: $count2 occurrences)"
        fi
    fi
done
echo ""

if [ ${#FOUND_FILES[@]} -eq 0 ]; then
    echo -e "${RED}ERROR: No script files found!${NC}"
    echo ""
    echo "Expected directory structure:"
    echo "  ./01_setup_ca.sh"
    echo "  ./ipsec_certificates/pc1/02_install_certs_pc1.sh"
    echo "  ./ipsec_certificates/pc1/03_setup_ipsec_pc1_cert.sh"
    echo "  ./ipsec_certificates/pc2/02_install_certs_pc2.sh"
    echo "  ./ipsec_certificates/pc2/03_setup_ipsec_pc2_cert.sh"
    exit 1
fi

# Confirm changes
if [ "$DRY_RUN" = false ]; then
    read -p "Proceed with IP address updates? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
    echo ""
fi

# Create backups
if [ "$DRY_RUN" = false ]; then
    echo "Creating backups..."
    BACKUP_DIR="$SCRIPT_DIR/backup_$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    for filepath in "${!FOUND_FILES[@]}"; do
        filename=$(basename "$filepath")
        # Preserve directory structure in backup
        rel_dir=$(dirname "$filepath")
        rel_dir="${rel_dir#$SCRIPT_DIR/}"
        mkdir -p "$BACKUP_DIR/$rel_dir" 2>/dev/null || true
        cp "$filepath" "$BACKUP_DIR/$rel_dir/" 2>/dev/null || cp "$filepath" "$BACKUP_DIR/"
    done
    echo -e "${GREEN}✓ Backups created in: $BACKUP_DIR${NC}"
    echo ""
fi

# Update files
echo "Updating IP addresses..."
echo ""

if [ "$DRY_RUN" = true ]; then
    echo "Changes that would be made:"
    for filepath in "${!FOUND_FILES[@]}"; do
        echo "  - $filepath"
    done
else
    for filepath in "${!FOUND_FILES[@]}"; do
        filename=$(basename "$filepath")
        echo "Processing: $filepath"
        
        # Update PC1 IP
        update_ip_in_file "$filepath" "$OLD_PC1_IP" "$NEW_PC1_IP"
        
        # Update PC2 IP
        update_ip_in_file "$filepath" "$OLD_PC2_IP" "$NEW_PC2_IP"
    done
fi

echo ""
echo "=========================================="
echo -e "${GREEN}✓ IP Address Update Complete!${NC}"
echo "=========================================="
echo ""

if [ "$DRY_RUN" = false ]; then
    echo "Updated Configuration:"
    echo "  PC1 (VPLMN): $NEW_PC1_IP"
    echo "  PC2 (HPLMN): $NEW_PC2_IP"
    echo ""
    echo "=========================================="
    echo "Next Steps:"
    echo "=========================================="
    echo ""
    echo "⚠️  IMPORTANT: You need to regenerate certificates!"
    echo "The old certificates contain the old IP addresses."
    echo ""
    echo "1. Regenerate certificates (on this machine):"
    echo "   sudo ./01_setup_ca.sh"
    echo ""
    echo "2. Copy PC1 files to new PC1 ($NEW_PC1_IP):"
    echo "   scp -r ./ipsec_certificates/pc1/* user@$NEW_PC1_IP:~/ipsec_certs/"
    echo ""
    echo "3. Copy PC2 files to new PC2 ($NEW_PC2_IP):"
    echo "   scp -r ./ipsec_certificates/pc2/* user@$NEW_PC2_IP:~/ipsec_certs/"
    echo ""
    echo "4. On PC1 ($NEW_PC1_IP):"
    echo "   cd ~/ipsec_certs"
    echo "   chmod +x *.sh"
    echo "   sudo ./02_install_certs_pc1.sh"
    echo "   sudo ./03_setup_ipsec_pc1_cert.sh"
    echo ""
    echo "5. On PC2 ($NEW_PC2_IP):"
    echo "   cd ~/ipsec_certs"
    echo "   chmod +x *.sh"
    echo "   sudo ./02_install_certs_pc2.sh"
    echo "   sudo ./03_setup_ipsec_pc2_cert.sh"
    echo ""
    echo "6. Verify tunnel on both PCs:"
    echo "   sudo ipsec statusall"
    echo ""
fi