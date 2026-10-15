#!/bin/bash

# Copy binary files
cp ~/open5gs/install/bin/open5gs-bsfd files/open5gs-bsfd
cp ~/open5gs/install/etc/open5gs/tls/ca.crt files/
cp ~/open5gs/install/etc/open5gs/tls/bsf.crt files/
cp ~/open5gs/install/etc/open5gs/tls/bsf.key files/
cp ~/open5gs/install/lib/*/libogscrypt.so.2 files/
cp ~/open5gs/install/lib/*/libogsproto.so.2 files/
cp ~/open5gs/install/lib/*/libogscore.so.2 files/
cp ~/open5gs/install/lib/*/libogssbi.so.2 files/
cp ~/open5gs/install/lib/*/libogsapp.so.2 files/
cp ~/open5gs/install/lib/*/libogssbi-openapi.so.2 files/

# Copy source files one by one to retain the structure
mkdir -p source_file
cp ~/open5gs/src/main.c ~/LKN_5G_Roaming_Testbed/VPLMN/docker/bsf-docker/source_file/
# List of files to copy from the ~/open5gs/src/bsf directory
SRC_DIR=~/open5gs/src/bsf
FILES=(
    "app.c" "bsf-sm.c" "bsf-sm.h" "context.c" "context.h"
    "event.c" "event.h" "init.c" "nbsf-handler.c" "nbsf-handler.h"
    "nnrf-handler.c" "nnrf-handler.h" "sbi-path.c" "sbi-path.h"
)

# Copy each file into the source_file directory
for file in "${FILES[@]}"; do
    cp "$SRC_DIR/$file" source_file/
done

# Report success only if the critical artifacts actually copied. Optional
# TLS/lib copies stay non-fatal; a missing binary or source is a real failure
# that must not be reported to prepare_nfs.sh as success.
if [[ -s files/open5gs-bsfd && -s source_file/main.c ]]; then
    echo "All necessary files and source files have been copied successfully for BSF."
else
    echo "ERROR: BSF preparation incomplete - missing binary (files/open5gs-bsfd) or source (source_file/main.c)" >&2
    exit 1
fi
