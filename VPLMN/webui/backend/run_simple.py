#!/usr/bin/env bash

# Simpler alternative backend runner for offline networks
# This avoids potential eventlet/gevent issues

BACKEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/backend"
LOGS_DIR="$(dirname "$BACKEND_DIR")/logs"

mkdir -p "$LOGS_DIR"

cd "$BACKEND_DIR"
source venv/bin/activate

# Use Flask's built-in server with threading (avoid eventlet/gevent)
python3 << 'PYEOF'
import os
import sys

# Force threaded mode to avoid eventlet/gevent issues
os.environ['WERKZEUG_RUN_MAIN'] = 'true'

# Minimal Flask app without socketio async libraries
from flask import Flask, jsonify
from flask_cors import CORS

app = Flask(__name__)
CORS(app, origins="*")

# Import the rest of app.py
sys.path.insert(0, os.getcwd())
from app import *  # This gets all routes and functionality

if __name__ == '__main__':
    print("=" * 60)
    print(" Open5GS Testbed API (Simple Mode - Threading, No Async)")
    print("=" * 60)
    # Use simple Flask threading instead of socketio async
    app.run(host='0.0.0.0', port=9090, debug=False, threaded=True, use_reloader=False)
PYEOF

