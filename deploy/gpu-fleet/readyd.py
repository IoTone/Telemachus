#!/usr/bin/env python3
"""readyd.py — one readiness endpoint per GPU, for TMACH_WORKER_READY_URL (#93).

    python3 readyd.py <gpu-index>

Answers 200 when the inference server pinned to THIS card replies and no pause
flag is set, 503 otherwise. A worker GETs it before each claim: while it is not
2xx the worker reports `paused` ONCE and claims nothing, re-checking every
TMACH_WORKER_READY_INTERVAL seconds. Queued jobs keep their attempt.

WHY THE PLATFORM ASKS A URL RATHER THAN READING A GPU: what "ready" means is the
operator's, and it differs per rig — VRAM headroom, a temperature ceiling, ECC
errors, a maintenance window, a card that drives a desktop and should stand down
while somebody is using it. TMach needs no knowledge of GPUs at all, and this
file is the seam where yours goes. Add `nvidia-smi` checks here; do not add them
to the worker.

The pause flag is the manual lever, and it is the quickest live demonstration of
the readiness gate there is:

    touch ~/tmach/pause2      # GPU 2 stands down
    rm    ~/tmach/pause2      # …and comes back

Deliberately dependency-free (stdlib only, no Flask) and bound to LOOPBACK: it
is read by a worker on the same host and by nobody else. It answers no body at
all — the worker reads the status code and nothing more, and a body would be one
more thing to keep honest.
"""
import http.server
import os
import sys
import urllib.request

if len(sys.argv) != 2:
    sys.exit("usage: readyd.py <gpu-index>")

GPU = int(sys.argv[1])
# The port scheme is the runbook's: inference on 1143<i>, readiness on 890<i>.
# 1143<i> rather than 11434+<i> on purpose — see docs/ops/gpu-fleet-runbook.md.
MODEL = f"http://127.0.0.1:1143{GPU}/api/version"
PAUSE = os.path.expanduser(f"~/tmach/pause{GPU}")
PORT = 8900 + GPU


def ready():
    if os.path.exists(PAUSE):
        return False
    try:
        # A short timeout on purpose: this runs before EVERY claim, so a hung
        # probe would stall the worker rather than stand it down.
        urllib.request.urlopen(MODEL, timeout=3).read()
    except Exception:
        return False
    return True


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200 if ready() else 503)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *a):
        pass        # one line per claim per card, every 15s, forever


if __name__ == "__main__":
    http.server.HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
