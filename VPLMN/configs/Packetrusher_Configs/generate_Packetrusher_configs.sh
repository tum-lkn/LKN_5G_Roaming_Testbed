#!/bin/bash
# ============================================================================
# PacketRusher per-iteration config generator.
#
# Expands each base config_<type>_roaming.yml into a <type>_roaming/ folder of
# 100 files (config_1.yml .. config_100.yml), each with the MSIN incremented by
# one — so batch runs can start a distinct UE per iteration (lib/automation/tests.sh picks
# config_${iteration}.yml). The 100-file folders are committed, so you only need
# to run this to regenerate them (e.g. after changing a base MSIN).
#
# setup.sh runs this as a final step; you can also run it by hand from anywhere
# (it cd's into its own directory first):
#   configs/Packetrusher_Configs/generate_Packetrusher_configs.sh
# ============================================================================

# Operate on this script's own directory so it works no matter where it is
# called from (setup.sh runs it by path). The base config_*_roaming.yml and the
# generated <type>_roaming/ folders all live alongside this file.
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

# Function to generate configs for a given type
generate_for_type() {
  local config_type=$1
  local original_file="config_${config_type}.yml"
  local output_dir="${config_type%_*}_roaming"
  
  # Check if original file exists
  if [[ ! -f "$original_file" ]]; then
    echo "Warning: $original_file not found, skipping $config_type"
    return 1
  fi
  
  # Get the current msin value from the file
  local current_msin=$(grep "msin:" "$original_file" | sed -E 's/.*"([0-9]+)".*/\1/')
  
  # Create output directory
  mkdir -p "$output_dir"
  
  # Base MSIN value (will be incremented) - force base 10 to handle leading zeros
  local base_msin_num=$((10#$current_msin))  # Use full value as base
  
  for i in {1..100}; do
    new_msin_num=$((base_msin_num + i - 1))  # Start from base (config_1 = base, config_2 = base+1, etc.)
    new_msin=$(printf "%010d" $new_msin_num)  # 10 digits to match original MSIN length
    
    # Create new file with updated msin
    sed "s/msin: \"$current_msin\"/msin: \"$new_msin\"/" "$original_file" > "$output_dir/config_$i.yml"
  done
  
  echo "Generated 100 config files for $config_type in $output_dir/"
}

# Generate for all config types
generate_for_type "lbo_roaming"
generate_for_type "hr_roaming"
generate_for_type "non_roaming"
