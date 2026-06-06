#!/usr/bin/env python3

from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import socket


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = (
            "virtual-network-delay backend\n"
            f"host={socket.gethostname()}\n"
            f"path={self.path}\n"
            f"time={datetime.now(timezone.utc).isoformat()}\n"
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
