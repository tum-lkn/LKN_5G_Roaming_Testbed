#!/bin/bash
mkdir -p files
# Copy binary files
cp ~/open5gs/install/bin/open5gs-pcfd files/open5gs-pcfd

# Copy configuration and TLS certificates
cp ~/open5gs/install/etc/open5gs/pcf.yaml files/pcf.yaml
cp ~/open5gs/install/etc/open5gs/tls/ca.crt files/
cp ~/open5gs/install/etc/open5gs/tls/pcf.crt files/
cp ~/open5gs/install/etc/open5gs/tls/pcf.key files/

# Copy shared library files
cp ~/open5gs/install/lib/*/libogsproto.so.2 files/
cp ~/open5gs/install/lib/*/libogscore.so.2 files/
cp ~/open5gs/install/lib/*/libogssbi.so.2 files/
cp ~/open5gs/install/lib/*/libogsapp.so.2 files/
cp ~/open5gs/install/lib/*/libogssbi-openapi.so.2 files/
cp ~/open5gs/install/lib/*/libogscrypt.so.2 files/
cp ~/open5gs/install/lib/*/libogsdbi.so.2 files/
cp ~/open5gs/install/lib/*/libprom.so files/
cp ~/open5gs/install/lib/*/libogsmetrics.so.2 files/

# Create source_file directory
mkdir -p source_file
cp ~/open5gs/src/main.c ~/LKN_5G_Roaming_Testbed/HPLMN/docker/pcf-docker/source_file/
# List of files to copy from the ~/open5gs/src/pcf directory
SRC_DIR=~/open5gs/src/pcf
FILES=(
    "am-sm.c" "app.c" "context.c" "context.h" "event.c" "event.h"
    "init.c" "metrics.c" "metrics.h" "naf-build.c" "naf-build.h"
    "namf-build.c" "namf-build.h" "nbsf-build.c" "nbsf-build.h"
    "nbsf-handler.c" "nbsf-handler.h" "nnrf-handler.c" "nnrf-handler.h"
    "npcf-handler.c" "npcf-handler.h" "nsmf-build.c" "nsmf-build.h"
    "nudr-build.c" "nudr-build.h" "nudr-handler.c" "nudr-handler.h"
    "pcf-sm.c" "pcf-sm.h" "sbi-path.c" "sbi-path.h" "sm-sm.c"
)

# Copy each source file into the source_file directory
for file in "${FILES[@]}"; do
    cp "$SRC_DIR/$file" source_file/
done

# Report success only if the critical artifacts actually copied. Optional
# TLS/lib copies stay non-fatal; a missing binary or source is a real failure
# that must not be reported to prepare_nfs.sh as success.
if [[ -s files/open5gs-pcfd && -s source_file/main.c ]]; then
    echo "All necessary files and source files have been copied successfully for PCF."
else
    echo "ERROR: PCF preparation incomplete - missing binary (files/open5gs-pcfd) or source (source_file/main.c)" >&2
    exit 1
fi
