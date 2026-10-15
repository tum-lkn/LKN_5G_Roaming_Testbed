#!/bin/bash

# Copy binary files
cp ~/open5gs/install/bin/open5gs-ausfd files/open5gs-ausfd
cp ~/open5gs/install/etc/open5gs/tls/ca.crt files/
cp ~/open5gs/install/etc/open5gs/tls/ausf.crt files/
cp ~/open5gs/install/etc/open5gs/tls/ausf.key files/
cp ~/open5gs/install/lib/*/libogscrypt.so.2 files/
cp ~/open5gs/install/lib/*/libogsproto.so.2 files/
cp ~/open5gs/install/lib/*/libogscore.so.2 files/
cp ~/open5gs/install/lib/*/libogssbi.so.2 files/
cp ~/open5gs/install/lib/*/libogsapp.so.2 files/
cp ~/open5gs/install/lib/*/libogssbi-openapi.so.2 files/
cp ~/open5gs/install/lib/*/libogsmetrics.so.2 files/
cp ~/open5gs/install/lib/*/libogssctp.so.2 files/
cp ~/open5gs/install/lib/*/libogsngap.so.2 files/
cp ~/open5gs/install/lib/*/libogsasn1c-ngap.so.2 files/
cp ~/open5gs/install/lib/*/libogsasn1c-common.so.2 files/
cp ~/open5gs/install/lib/*/libogsasn1c-util.so.2 files/
cp ~/open5gs/install/lib/*/libogsnas-5gs.so.2 files/
cp ~/open5gs/install/lib/*/libogsnas-common.so.2 files/
cp ~/open5gs/install/lib/*/libprom.so files/

# Copy source files one by one to retain the structure
mkdir -p source_file
cp ~/open5gs/src/main.c ~/LKN_5G_Roaming_Testbed/VPLMN/docker/ausf-docker/source_file/

# List of files to copy from the ~/open5gs/src/ausf directory
SRC_DIR=~/open5gs/src/ausf
FILES=(
    "app.c" "ausf-sm.c" "ausf-sm.h" "context.c" "context.h"
    "event.c" "event.h" "init.c" "nausf-handler.c" "nausf-handler.h"
    "nnrf-handler.c" "nnrf-handler.h" "nudm-build.c" "nudm-build.h"
    "nudm-handler.c" "nudm-handler.h" "sbi-path.c" "sbi-path.h"
    "ue-sm.c"
)

# Copy each file into the source_file directory
for file in "${FILES[@]}"; do
    cp "$SRC_DIR/$file" source_file/
done

# Report success only if the critical artifacts actually copied. Optional
# TLS/lib copies stay non-fatal; a missing binary or source is a real failure
# that must not be reported to prepare_nfs.sh as success.
if [[ -s files/open5gs-ausfd && -s source_file/main.c ]]; then
    echo "All necessary files and source files have been copied successfully for AUSF."
else
    echo "ERROR: AUSF preparation incomplete - missing binary (files/open5gs-ausfd) or source (source_file/main.c)" >&2
    exit 1
fi
