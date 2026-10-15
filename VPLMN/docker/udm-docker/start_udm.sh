#!/bin/bash

# Copy binary files
cp ~/open5gs/install/bin/open5gs-udmd files/open5gs-udmd

# Copy TLS certificates
cp ~/open5gs/install/etc/open5gs/tls/ca.crt files/
cp ~/open5gs/install/etc/open5gs/tls/udm.crt files/
cp ~/open5gs/install/etc/open5gs/tls/udm.key files/

# Copy hnet keys (Commented out, keeping it for reference)
#cp ~/open5gs/install/etc/open5gs/hnet/curve25519-1.key files/hnet/
#cp ~/open5gs/install/etc/open5gs/hnet/secp256r1-2.key files/hnet/
#cp ~/open5gs/install/etc/open5gs/hnet/curve25519-3.key files/hnet/
#cp ~/open5gs/install/etc/open5gs/hnet/secp256r1-4.key files/hnet/
#cp ~/open5gs/install/etc/open5gs/hnet/curve25519-5.key files/hnet/
#cp ~/open5gs/install/etc/open5gs/hnet/secp256r1-6.key files/hnet/

# Copy shared library files
cp ~/open5gs/install/lib/*/libogscrypt.so.2 files/
cp ~/open5gs/install/lib/*/libogsproto.so.2 files/
cp ~/open5gs/install/lib/*/libogscore.so.2 files/
cp ~/open5gs/install/lib/*/libogssbi.so.2 files/
cp ~/open5gs/install/lib/*/libogsapp.so.2 files/
cp ~/open5gs/install/lib/*/libogssbi-openapi.so.2 files/

# Create source_file directory
mkdir -p source_file
cp ~/open5gs/src/main.c ~/LKN_5G_Roaming_Testbed/VPLMN/docker/udm-docker/source_file/
# List of files to copy from the ~/open5gs/src/udm directory
SRC_DIR=~/open5gs/src/udm
FILES=(
    "app.c" "context.c" "context.h" "event.c" "event.h"
    "init.c" "meson.build" "nnrf-handler.c" "nnrf-handler.h"
    "nudm-handler.c" "nudm-handler.h" "nudr-build.c" "nudr-build.h"
    "nudr-handler.c" "nudr-handler.h" "sbi-path.c" "sbi-path.h"
    "sess-sm.c" "ue-sm.c" "udm-sm.c" "udm-sm.h"
)

# Copy each source file into the source_file directory
for file in "${FILES[@]}"; do
    cp "$SRC_DIR/$file" source_file/
done

# Report success only if the critical artifacts actually copied. Optional
# TLS/lib copies stay non-fatal; a missing binary or source is a real failure
# that must not be reported to prepare_nfs.sh as success.
if [[ -s files/open5gs-udmd && -s source_file/main.c ]]; then
    echo "All necessary files and source files have been copied successfully for UDM."
else
    echo "ERROR: UDM preparation incomplete - missing binary (files/open5gs-udmd) or source (source_file/main.c)" >&2
    exit 1
fi
