#!/bin/bash

# Script to run all NF setup scripts that copy files from open5gs installation
# This prepares all NF directories with necessary binaries and source files

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLMN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCKER_DIR="$PLMN_ROOT/docker"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Open5GS NF Setup - Copy Files Script${NC}"
echo -e "${GREEN}========================================${NC}\n"

# Check if we're in a valid testbed checkout
if [ ! -f "$PLMN_ROOT/docker-compose.yml" ]; then
    echo -e "${RED}Error: docker-compose.yml not found!${NC}"
    echo -e "${YELLOW}Expected it at $PLMN_ROOT/docker-compose.yml${NC}"
    exit 1
fi

if [ ! -d "$DOCKER_DIR" ]; then
    echo -e "${RED}Error: docker directory not found at $DOCKER_DIR${NC}"
    exit 1
fi

# Check if open5gs installation exists
if [ ! -d "$HOME/open5gs/install" ]; then
    echo -e "${RED}Error: open5gs installation not found at $HOME/open5gs/install${NC}"
    echo -e "${YELLOW}Please ensure open5gs is installed before running this script${NC}"
    exit 1
fi

# List of all available NFs with their setup scripts
declare -A ALL_NF_SCRIPTS
ALL_NF_SCRIPTS=(
    ["amf-docker"]="start_amf.sh"
    ["smf-docker"]="start_smf.sh"
    ["ausf-docker"]="start_ausf.sh"
    ["udm-docker"]="start_udm.sh"
    ["udr-docker"]="start_udr.sh"
    ["pcf-docker"]="start_pcf.sh"
    ["nrf-docker"]="start_nrf.sh"
    ["nssf-docker"]="start_nssf.sh"
    ["bsf-docker"]="start_bsf.sh"
    ["scp-docker"]="start_scp.sh"
    ["sepp-docker"]="start_sepp.sh"
    ["upf-docker"]="start_upf.sh"
    ["upf2-docker"]="start_upf2.sh"
)

# Ask user for setup mode
echo -e "${CYAN}Is this an initial setup (setting up all NFs for the first time)?${NC}"
echo -e "${YELLOW}[Y/n]:${NC} "
read -r INITIAL_SETUP

INITIAL_SETUP=${INITIAL_SETUP:-Y}

declare -A NF_SCRIPTS

if [[ "$INITIAL_SETUP" =~ ^[Yy]$ ]]; then
    echo -e "\n${GREEN}Initial setup mode: Processing all NFs${NC}\n"
    # Copy all NFs to the working array
    for nf in "${!ALL_NF_SCRIPTS[@]}"; do
        NF_SCRIPTS["$nf"]="${ALL_NF_SCRIPTS[$nf]}"
    done
else
    echo -e "\n${CYAN}Selective setup mode${NC}"
    echo -e "${YELLOW}Available NFs:${NC}\n"
    
    # Display numbered list of NFs
    NF_LIST=()
    i=1
    for nf in "${!ALL_NF_SCRIPTS[@]}"; do
        NF_LIST+=("$nf")
        echo -e "  ${BLUE}$i)${NC} ${nf%-docker}"
        ((i++))
    done
    
    echo -e "\n${CYAN}Enter NF numbers to setup (space-separated, e.g., '1 3 5'):${NC}"
    echo -e "${CYAN}Or enter 'all' to setup all NFs:${NC}"
    echo -e "${YELLOW}Selection:${NC} "
    read -r NF_SELECTION
    
    if [[ "$NF_SELECTION" == "all" ]]; then
        echo -e "\n${GREEN}Setting up all NFs${NC}\n"
        for nf in "${!ALL_NF_SCRIPTS[@]}"; do
            NF_SCRIPTS["$nf"]="${ALL_NF_SCRIPTS[$nf]}"
        done
    else
        echo -e "\n${GREEN}Setting up selected NFs${NC}\n"
        # Parse user selection
        for num in $NF_SELECTION; do
            if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#NF_LIST[@]}" ]; then
                idx=$((num - 1))
                selected_nf="${NF_LIST[$idx]}"
                NF_SCRIPTS["$selected_nf"]="${ALL_NF_SCRIPTS[$selected_nf]}"
            else
                echo -e "${YELLOW}Warning: Invalid selection '$num' - skipping${NC}"
            fi
        done
        
        if [ ${#NF_SCRIPTS[@]} -eq 0 ]; then
            echo -e "${RED}No valid NFs selected. Exiting.${NC}"
            exit 1
        fi
        
        echo -e "${GREEN}Selected NFs:${NC}"
        for nf in "${!NF_SCRIPTS[@]}"; do
            echo -e "  - ${nf%-docker}"
        done
        echo ""
    fi
fi

SUCCESS_COUNT=0
FAILED_COUNT=0
SKIPPED_COUNT=0

echo -e "${BLUE}Starting NF file preparation...${NC}\n"

for nf_dir in "${!NF_SCRIPTS[@]}"; do
    script_name="${NF_SCRIPTS[$nf_dir]}"
    nf_path="$DOCKER_DIR/$nf_dir"
    script_path="${nf_path}/${script_name}"
    
    echo -e "${YELLOW}Processing ${nf_dir}...${NC}"
    
    # Check if NF directory exists
    if [ ! -d "${nf_path}" ]; then
        echo -e "  ${RED}✗ Directory docker/${nf_dir} not found - skipping${NC}\n"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        continue
    fi
    
    # Check if setup script exists
    if [ ! -f "${script_path}" ]; then
        echo -e "  ${YELLOW}⚠ Setup script ${script_name} not found in docker/${nf_dir} - skipping${NC}\n"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        continue
    fi
    
    # Make script executable if it isn't
    chmod +x "${script_path}"
    
    # Change to NF directory and run the script
    cd "${nf_path}" || {
        echo -e "  ${RED}✗ Could not enter docker/${nf_dir}${NC}\n"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    }
    
    if bash "${script_name}"; then
        echo -e "  ${GREEN}✓ Successfully prepared ${nf_dir}${NC}\n"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo -e "  ${RED}✗ Failed to prepare ${nf_dir}${NC}\n"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
    
    # Return to root directory
    cd "$PLMN_ROOT" || exit 1
done

# Summary
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}NF Setup Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "Successfully prepared: ${GREEN}${SUCCESS_COUNT}${NC} NFs"
if [ ${SKIPPED_COUNT} -gt 0 ]; then
    echo -e "Skipped: ${YELLOW}${SKIPPED_COUNT}${NC} NFs"
fi
if [ ${FAILED_COUNT} -gt 0 ]; then
    echo -e "Failed: ${RED}${FAILED_COUNT}${NC} NFs"
fi
echo -e "${GREEN}========================================${NC}\n"

if [ ${FAILED_COUNT} -gt 0 ]; then
    echo -e "${YELLOW}Some NFs failed to prepare. Check the output above for details.${NC}"
    exit 1
fi

if [ ${SUCCESS_COUNT} -eq 0 ]; then
    echo -e "${RED}No NFs were prepared successfully!${NC}"
    echo -e "${YELLOW}Please check:${NC}"
    echo -e "  1. open5gs is installed at ~/open5gs/install"
    echo -e "  2. NF directories contain the setup scripts"
    echo -e "  3. You have necessary permissions"
    exit 1
fi

echo -e "${GREEN}All NFs have been prepared successfully!${NC}"
echo -e "${YELLOW}Next steps:${NC}"
echo -e "  1. Restore certificates (if needed): ${GREEN}./redistribute_certificates.sh${NC}"
echo -e "  2. Build containers: ${GREEN}./build_all.sh${NC}"
echo -e "  3. Start testbed: ${GREEN}./start_all_nfs.sh${NC}\n"

exit 0
