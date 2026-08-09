"""Loopback stand-in for the staging repo: answers every request with 404 and
records the User-Agent it was asked with, so the harness can check both the
first-publish path and the header Cloudflare's managed rules care about.

Usage: staging-db-server.py <ua-capture-file>. Prints "port <n>" once bound.
"""

import http.server
import sys

capture = sys.argv[1]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(capture, "a", encoding="utf-8") as f:
            f.write(self.headers.get("User-Agent", "") + "\n")
        self.send_error(404)

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
print("port %d" % server.server_address[1], flush=True)
server.serve_forever()
