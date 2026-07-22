#!/bin/bash

# Copy binary files
cp ~/open5gs/install/bin/open5gs-seppd files/open5gs-seppd

# Copy TLS certificates
cp ~/open5gs/install/etc/open5gs/tls/ca.crt files/
cp ~/open5gs/install/etc/open5gs/tls/sepp1.crt files/
cp ~/open5gs/install/etc/open5gs/tls/sepp1.key files/

# Copy shared library files
cp ~/open5gs/install/lib/*/libogsproto.so.2 files/
cp ~/open5gs/install/lib/*/libogscore.so.2 files/
cp ~/open5gs/install/lib/*/libogssbi.so.2 files/
cp ~/open5gs/install/lib/*/libogsapp.so.2 files/
cp ~/open5gs/install/lib/*/libogssbi-openapi.so.2 files/
cp ~/open5gs/install/lib/*/libogscrypt.so.2 files/

# Create source_file directory
mkdir -p source_file
cp ~/open5gs/src/main.c ~/LKN_5G_Roaming_Testbed/VPLMN/docker/sepp-docker/source_file/
# List of files to copy from the ~/open5gs/src/sepp directory
SRC_DIR=~/open5gs/src/sepp
FILES=(
    "app.c" "context.c" "context.h" "event.c" "event.h"
    "handshake-sm.c" "init.c" "meson.build"
    "n32c-build.c" "n32c-build.h" "n32c-handler.c" "n32c-handler.h"
    "sbi-path.c" "sbi-path.h" "sepp-sm.c" "sepp-sm.h"
    "timer.c" "timer.h"
)

# Copy each source file into the source_file directory
for file in "${FILES[@]}"; do
    cp "$SRC_DIR/$file" source_file/
done

# Report success only if the critical artifacts actually copied. Optional
# TLS/lib copies stay non-fatal; a missing binary or source is a real failure
# that must not be reported to prepare_nfs.sh as success.
if [[ -s files/open5gs-seppd && -s source_file/main.c ]]; then
    echo "All necessary files and source files have been copied successfully for SEPP."
else
    echo "ERROR: SEPP preparation incomplete - missing binary (files/open5gs-seppd) or source (source_file/main.c)" >&2
    exit 1
fi
