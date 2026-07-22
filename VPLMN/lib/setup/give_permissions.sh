#!/bin/bash
# Script to grant execute permissions to all .sh files in the project
# File: set_permissions.sh

echo "Setting execute permissions for all .sh files in the project..."

# Get the directory where this script is located (lib/setup/) and resolve the
# project root two levels up. chmod'ing from the project root covers setup.sh,
# every NF's start_*.sh, and lib/features/ — not just the scripts in lib/setup/.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

# Change to the project root directory
cd "$PROJECT_ROOT" || { echo "ERROR: could not cd to project root ($PROJECT_ROOT)"; exit 1; }

# Find and chmod all .sh files
find . -type f -name "*.sh" -exec chmod +x {} \;

# Count how many files were modified
count=$(find . -type f -name "*.sh" | wc -l)

echo "✓ Execute permissions set for $count .sh files"
echo ""
echo "Files that were modified:"
find . -type f -name "*.sh" -print

echo ""
echo "Done! All shell scripts now have execute permissions."
