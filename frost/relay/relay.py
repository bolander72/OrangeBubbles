#!/usr/bin/env python3
"""Debug relay for OrangeBubbles vault testing — stands in for iMessage
card exchange so 2 sims + a phone can run a real FROST ceremony together.

NOT part of the product. The app's real transport is end-to-end encrypted
iMessage; this is an append-only bulletin board keyed by vault so three
app instances can pass Codable ceremony messages during development.

GET  /vault/<id>            -> {"messages": [ ... all posted, in order ]}
POST /vault/<id>  {msg}     -> appends msg, returns {"ok": true, "count": n}
POST /reset/<id>            -> clears a vault's log
"""
import json, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()
BOARD = {}  # vaultID -> [message, ...]

class H(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parts = self.path.strip("/").split("/")
        if len(parts) == 2 and parts[0] == "vault":
            with LOCK:
                self._send(200, {"messages": BOARD.get(parts[1], [])})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        parts = self.path.strip("/").split("/")
        n = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(n) if n else b"{}"
        if len(parts) == 2 and parts[0] == "vault":
            msg = json.loads(raw or b"{}")
            with LOCK:
                BOARD.setdefault(parts[1], []).append(msg)
                self._send(200, {"ok": True, "count": len(BOARD[parts[1]])})
        elif len(parts) == 2 and parts[0] == "reset":
            with LOCK:
                BOARD[parts[1]] = []
                self._send(200, {"ok": True})
        else:
            self._send(404, {"error": "not found"})

    def log_message(self, *a):
        pass  # quiet

if __name__ == "__main__":
    print("vault debug relay on 0.0.0.0:8781 — reachable at http://192.168.1.46:8781")
    ThreadingHTTPServer(("0.0.0.0", 8781), H).serve_forever()
