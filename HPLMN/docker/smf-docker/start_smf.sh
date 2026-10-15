#!/bin/bash
mkdir -p files
# Copy binary files
cp ~/open5gs/install/bin/open5gs-smfd files/open5gs-smfd

# Copy configuration files
cp ~/open5gs/install/etc/open5gs/smf.yaml files/smf.yaml

# Copy TLS certificates
cp ~/open5gs/install/etc/open5gs/tls/ca.crt files/
cp ~/open5gs/install/etc/open5gs/tls/smf.crt files/
cp ~/open5gs/install/etc/open5gs/tls/smf.key files/

# Copy shared library files
cp ~/open5gs/install/lib/*/libogscrypt.so.2 files/
cp ~/open5gs/install/lib/*/libogsproto.so.2 files/
cp ~/open5gs/install/lib/*/libogscore.so.2 files/
cp ~/open5gs/install/lib/*/libogssbi.so.2 files/
cp ~/open5gs/install/lib/*/libogsapp.so.2 files/
cp ~/open5gs/install/lib/*/libogssbi-openapi.so.2 files/
cp ~/open5gs/install/lib/*/libogsmetrics.so.2 files/
cp ~/open5gs/install/lib/*/libogsngap.so.2 files/
cp ~/open5gs/install/lib/*/libogsasn1c-ngap.so.2 files/
cp ~/open5gs/install/lib/*/libogsasn1c-common.so.2 files/
cp ~/open5gs/install/lib/*/libogsasn1c-util.so.2 files/
cp ~/open5gs/install/lib/*/libogsnas-5gs.so.2 files/
cp ~/open5gs/install/lib/*/libogsnas-common.so.2 files/
cp ~/open5gs/install/lib/*/libogsdiameter-gx.so.2 files/
cp ~/open5gs/install/lib/*/libogsdiameter-common.so.2 files/
cp ~/open5gs/install/lib/*/libogsdiameter-gy.so.2 files/
cp ~/open5gs/install/lib/*/libogsdiameter-s6b.so.2 files/
cp ~/open5gs/install/lib/*/libogsdiameter-rx.so.2 files/
cp ~/open5gs/install/lib/*/libogspfcp.so.2 files/
cp ~/open5gs/install/lib/*/libogsgtp.so.2 files/
cp ~/open5gs/install/lib/*/libogsipfw.so.2 files/
cp ~/open5gs/install/lib/*/libfdcore.so.7 files/
cp ~/open5gs/install/lib/*/libfdproto.so.7 files/
cp ~/open5gs/install/lib/*/libprom.so files/

# Create source_file directory
mkdir -p source_file
cp ~/open5gs/src/main.c ~/LKN_5G_Roaming_Testbed/HPLMN/docker/smf-docker/source_file/
# List of files to copy from the ~/open5gs/src/smf directory
SRC_DIR=~/open5gs/src/smf
FILES=(
    "app.c" "binding.c" "binding.h" "context.c" "context.h" "event.c" "event.h"
    "fd-path.c" "fd-path.h" "gn-build.c" "gn-build.h" "gn-handler.c" "gn-handler.h"
    "gsm-build.c" "gsm-build.h" "gsm-handler.c" "gsm-handler.h" "gsm-sm.c"
    "gtp-path.c" "gtp-path.h" "gx-handler.c" "gx-handler.h" "gx-path.c"
    "gy-handler.c" "gy-handler.h" "gy-path.c" "init.c" "metrics.c" "metrics.h"
    "n4-build.c" "n4-build.h" "n4-handler.c" "n4-handler.h" "namf-build.c"
    "namf-build.h" "namf-handler.c" "namf-handler.h" "nas-path.c" "nas-path.h"
    "ngap-build.c" "ngap-build.h" "ngap-handler.c" "ngap-handler.h"
    "ngap-path.c" "ngap-path.h" "nnrf-handler.c" "nnrf-handler.h"
    "npcf-build.c" "npcf-build.h" "npcf-handler.c" "npcf-handler.h"
    "nsmf-handler.c" "nsmf-handler.h" "nudm-build.c" "nudm-build.h"
    "nudm-handler.c" "nudm-handler.h" "pfcp-path.c" "pfcp-path.h"
    "pfcp-sm.c" "s5c-build.c" "s5c-build.h" "s5c-handler.c" "s5c-handler.h"
    "s6b-path.c" "sbi-path.c" "sbi-path.h" "smf-sm.c" "smf-sm.h"
    "timer.c" "timer.h"
)

# Copy each source file into the source_file directory
for file in "${FILES[@]}"; do
    cp "$SRC_DIR/$file" source_file/
done

# Report success only if the critical artifacts actually copied. Optional
# TLS/lib copies stay non-fatal; a missing binary or source is a real failure
# that must not be reported to prepare_nfs.sh as success.
if [[ -s files/open5gs-smfd && -s source_file/main.c ]]; then
    echo "All necessary files and source files have been copied successfully for SMF."
else
    echo "ERROR: SMF preparation incomplete - missing binary (files/open5gs-smfd) or source (source_file/main.c)" >&2
    exit 1
fi
