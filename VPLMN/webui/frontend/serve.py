#!/usr/bin/env python3
"""
Simple HTTP server with no-cache headers.
Prevents browser caching issues during development.
"""
from http.server import HTTPServer, SimpleHTTPRequestHandler
import sys

class NoCacheHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        # Add no-cache headers to prevent browser caching
        self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0')
        self.send_header('Pragma', 'no-cache')
        self.send_header('Expires', '0')
        super().end_headers()
    
    def log_message(self, format, *args):
        # Quieter logging
        pass

if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9091
    print(f"Frontend server running on http://0.0.0.0:{port} (no-cache enabled)")
    HTTPServer(('0.0.0.0', port), NoCacheHandler).serve_forever()
