#!/bin/bash
set -e  # Exit immediately if a command exits with a non-zero status

##############################################
# 🔧 CONFIGURATION
##############################################
# Change this to switch between versions:
# VERSION="open5gs"
VERSION="open5gs"

# Base directories
BASE_DIR=~/$VERSION
INSTALL_DIR="$BASE_DIR/install"
SRC_DIR="$BASE_DIR/src"

# Output directories
FILES_DIR="./files"
SRC_OUT_DIR="./source_file"

mkdir -p "$FILES_DIR" "$SRC_OUT_DIR"

echo "📦 Copying files for version: $VERSION"
echo "Base directory: $BASE_DIR"
echo "----------------------------------------"

##############################################
# 1️⃣ Copy Binary Files
##############################################
BIN_DIR="$INSTALL_DIR/bin"
BIN_FILES=( "open5gs-upfd" )

for file in "${BIN_FILES[@]}"; do
    cp "$BIN_DIR/$file" "$FILES_DIR/"
done
echo "✅ Binary files copied."


##############################################
# 2️⃣ Copy Configuration Files
##############################################
CONF_DIR="$INSTALL_DIR/etc/open5gs"
CONF_FILES=( "upf.yaml" )

for file in "${CONF_FILES[@]}"; do
    cp "$CONF_DIR/$file" "$FILES_DIR/"
done
echo "✅ Configuration files copied."


##############################################
# 3️⃣ Copy TLS Certificates (optional)
##############################################
TLS_DIR="$CONF_DIR/tls"
TLS_FILES=(
    "ca.crt"
    # "upf.crt"
    # "upf.key"
)

for file in "${TLS_FILES[@]}"; do
    cp "$TLS_DIR/$file" "$FILES_DIR/" 2>/dev/null || true
done
echo "✅ TLS certificates copied (if available)."


##############################################
# 4️⃣ Copy Shared Libraries
##############################################
LIB_DIR="$INSTALL_DIR/lib"
LIB_FILES=(
    "libogscrypt.so.2"
    "libogsproto.so.2"
    "libogscore.so.2"
    "libogssbi.so.2"
    "libogsapp.so.2"
    "libogssbi-openapi.so.2"
    "libogsmetrics.so.2"
    "libogsngap.so.2"
    "libogsasn1c-ngap.so.2"
    "libogsasn1c-common.so.2"
    "libogsasn1c-util.so.2"
    "libogsnas-5gs.so.2"
    "libogsnas-common.so.2"
    "libogsdiameter-gx.so.2"
    "libogsdiameter-common.so.2"
    "libogsdiameter-gy.so.2"
    "libogsdiameter-s6b.so.2"
    "libogsdiameter-rx.so.2"
    "libogspfcp.so.2"
    "libogsgtp.so.2"
    "libogstun.so.2"
    "libogsipfw.so.2"
    "libfdcore.so.7"
    "libfdproto.so.7"
    "libprom.so"
)

for file in "${LIB_FILES[@]}"; do
    cp "$LIB_DIR"/*/"$file" "$FILES_DIR/" 2>/dev/null || true
done
echo "✅ Shared libraries copied."


##############################################
# 5️⃣ Copy Source Files
##############################################
UPF_SRC="$SRC_DIR/upf"
UPF_FILES=(
    "app.c"
    "arp-nd.cpp" "arp-nd.h"
    "context.c" "context.h"
    "event.c" "event.h"
    "gtp-path.c" "gtp-path.h"
    "init.c"
    "metrics.c" "metrics.h"
    "n4-build.c" "n4-build.h"
    "n4-handler.c" "n4-handler.h"
    "pfcp-path.c" "pfcp-path.h"
    "pfcp-sm.c"
    "rule-match.c" "rule-match.h"
    "timer.c" "timer.h"
    "upf-sm.c" "upf-sm.h"
)

for file in "${UPF_FILES[@]}"; do
    cp "$UPF_SRC/$file" "$SRC_OUT_DIR/"
done

cp "$SRC_DIR/main.c" ~/LKN_5G_Roaming_Testbed/HPLMN/docker/upf-docker/source_file/
echo "✅ Source files copied."


##############################################
# ✅ DONE
##############################################
echo "🎉 All necessary files for $VERSION have been copied successfully!"
