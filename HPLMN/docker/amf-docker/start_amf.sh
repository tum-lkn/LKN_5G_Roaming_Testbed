#!/bin/bash

# Copy binary files
cp ~/open5gs/install/bin/open5gs-amfd files/open5gs-amfd
cp ~/open5gs/install/etc/open5gs/tls/ca.crt files/
cp ~/open5gs/install/etc/open5gs/tls/amf.crt files/
cp ~/open5gs/install/etc/open5gs/tls/amf.key files/
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
cp ~/open5gs/src/main.c ~/LKN_5G_Roaming_Testbed/HPLMN/docker/amf-docker/source_file/

# List of files to copy from the ~/open5gs/src/amf directory
SRC_DIR=~/open5gs/src/amf
FILES=(
    "amf-sm.c" "amf-sm.h" "app.c" "context.c" "context.h"
    "event.c" "event.h" "gmm-build.c" "gmm-build.h"
    "gmm-handler.c" "gmm-handler.h" "gmm-sm.c" "init.c"
    "metrics.c" "metrics.h" "namf-build.c" "namf-build.h"
    "namf-handler.c" "namf-handler.h" "nas-path.c"
    "nas-path.h" "nas-security.c" "nas-security.h"
    "nausf-build.c" "nausf-build.h" "nausf-handler.c"
    "nausf-handler.h" "ngap-build.c" "ngap-build.h"
    "ngap-handler.c" "ngap-handler.h" "ngap-path.c"
    "ngap-path.h" "ngap-sctp.c" "ngap-sm.c" "nnrf-build.c"
    "nnrf-build.h" "nnrf-handler.c" "nnrf-handler.h"
    "nnssf-build.c" "nnssf-build.h" "nnssf-handler.c"
    "nnssf-handler.h" "npcf-build.c" "npcf-build.h"
    "npcf-handler.c" "npcf-handler.h" "nsmf-build.c"
    "nsmf-build.h" "nsmf-handler.c" "nsmf-handler.h"
    "nudm-build.c" "nudm-build.h" "nudm-handler.c"
    "nudm-handler.h" "sbi-path.c" "sbi-path.h" "timer.c"
    "timer.h"
)

# Copy each file into the file_source directory
for file in "${FILES[@]}"; do
    cp "$SRC_DIR/$file" source_file/
done

# Report success only if the critical artifacts actually copied. Optional
# TLS/lib copies stay non-fatal; a missing binary or source is a real failure
# that must not be reported to prepare_nfs.sh as success.
if [[ -s files/open5gs-amfd && -s source_file/main.c ]]; then
    echo "All necessary files and source files have been copied successfully."
else
    echo "ERROR: AMF preparation incomplete - missing binary (files/open5gs-amfd) or source (source_file/main.c)" >&2
    exit 1
fi
