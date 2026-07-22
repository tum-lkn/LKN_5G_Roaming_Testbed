#!/usr/bin/env bash

# Diagnostic script to identify startup bottlenecks in offline network

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$SCRIPT_DIR/backend"

echo "════════════════════════════════════════════════════════════════"
echo "  WebUI Startup Diagnostics (Offline Network)"
echo "════════════════════════════════════════════════════════════════"
echo ""

# Test 1: Check Python imports directly
echo "[TEST 1] Python import timing..."
cd "$BACKEND_DIR"
timeout 10 python3 -c "
import sys
import time
t0 = time.time()

print('Importing Flask...', end='', flush=True)
from flask import Flask
print(f' {time.time()-t0:.2f}s')

print('Importing flask_cors...', end='', flush=True)
from flask_cors import CORS
print(f' {time.time()-t0:.2f}s')

print('Importing flask_socketio...', end='', flush=True)
from flask_socketio import SocketIO
print(f' {time.time()-t0:.2f}s')

print(f'Total import time: {time.time()-t0:.2f}s')
" 2>&1 || echo "ERROR: Imports failed or timed out!"
echo ""

# Test 2: Check venv activation speed
echo "[TEST 2] Virtual environment activation..."
time source venv/bin/activate
echo ""

# Test 3: Start backend with detailed output
echo "[TEST 3] Backend startup (will run for 10 seconds)..."
echo "If backend hangs here, the issue is in app.py initialization!"
echo ""

cd "$BACKEND_DIR"
source venv/bin/activate

# Run backend with output to see where it hangs
timeout 10 python3 app.py 2>&1 &
BACKEND_PID=$!

# Give it time to start or fail
sleep 5

# Check if it's listening
if ss -tlnp 2>/dev/null | grep -q ":9090"; then
    echo "✓ Backend successfully listening on port 9090"
    kill $BACKEND_PID 2>/dev/null
else
    echo "✗ Backend NOT listening on port 9090 after 5 seconds"
    echo "This suggests app.py is hanging during startup"
    kill $BACKEND_PID 2>/dev/null
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  If backend is hanging, check backend.log for errors:"
echo "  tail -100 $SCRIPT_DIR/logs/backend.log"
echo "════════════════════════════════════════════════════════════════"
