#!/usr/bin/env bash

# Test if the WebUI is reachable from another machine
# Usage: ./test_webui.sh <target_ip>

TARGET_IP="${1:-10.0.0.10}"
BACKEND_PORT="9090"
FRONTEND_PORT="9091"

echo "Testing WebUI accessibility from remote machine"
echo "Target: $TARGET_IP"
echo ""

# Test backend API
echo "[1] Testing Backend API on port $BACKEND_PORT..."
if timeout 3 curl -s "http://$TARGET_IP:$BACKEND_PORT/api/health" >/dev/null 2>&1; then
    echo "✓ Backend API is reachable"
else
    echo "✗ Backend API is NOT reachable (timeout or connection refused)"
    echo "  Trying with verbose output:"
    timeout 5 curl -v "http://$TARGET_IP:$BACKEND_PORT/" 2>&1 | head -20
fi

echo ""

# Test frontend
echo "[2] Testing Frontend on port $FRONTEND_PORT..."
if timeout 3 curl -s "http://$TARGET_IP:$FRONTEND_PORT/" >/dev/null 2>&1; then
    echo "✓ Frontend is reachable"
else
    echo "✗ Frontend is NOT reachable (timeout or connection refused)"
fi

echo ""

# Test connectivity
echo "[3] Network connectivity tests..."
echo "Ping $TARGET_IP:"
timeout 2 ping -c 1 "$TARGET_IP" >/dev/null 2>&1 && echo "✓ Ping OK" || echo "✗ Ping failed"

echo ""
echo "Port scan:"
for port in 22 9090 9091; do
    timeout 1 bash -c "echo >/dev/tcp/$TARGET_IP/$port" 2>/dev/null && echo "✓ Port $port open" || echo "✗ Port $port closed"
done

echo ""
echo "Try accessing the WebUI in your browser:"
echo "  http://$TARGET_IP:9091"
