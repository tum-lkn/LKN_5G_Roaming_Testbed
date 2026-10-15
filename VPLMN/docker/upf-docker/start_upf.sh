#!/bin/bash

# Set Open5GS version directory (change this to switch versions)
OPEN5GS_DIR="open5gs"

# Copy binary files
cp ~/${OPEN5GS_DIR}/install/bin/open5gs-upfd files/open5gs-upfd

# Copy shared library files
cp ~/${OPEN5GS_DIR}/install/lib/*/libogsproto.so.2 files/
cp ~/${OPEN5GS_DIR}/install/lib/*/libogscore.so.2 files/
cp ~/${OPEN5GS_DIR}/install/lib/*/libogsapp.so.2 files/
cp ~/${OPEN5GS_DIR}/install/lib/*/libogspfcp.so.2 files/
cp ~/${OPEN5GS_DIR}/install/lib/*/libogsgtp.so.2 files/
cp ~/${OPEN5GS_DIR}/install/lib/*/libogstun.so.2 files/
cp ~/${OPEN5GS_DIR}/install/lib/*/libogsipfw.so.2 files/
cp ~/${OPEN5GS_DIR}/install/lib/*/libogsmetrics.so.2 files/
cp ~/${OPEN5GS_DIR}/install/lib/*/libprom.so files/
