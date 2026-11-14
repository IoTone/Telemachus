#!/usr/bin/env python3
"""Send a JSON body that is NOT an object to every write route, and fail on a 500.

    python3 -I test/body-shape-sweep.py <base-url> <bearer> <routes-file>

<routes-file> is one "METHOD /path" per line, printed from server/routes.rkt by
server-smoke.sh, so a route added to the table is swept the day it lands — a
hand-kept list would be the one place a new route is forgotten.

What this asks is narrow on purpose: valid JSON that is a string, an array, a
number or null must be a REFUSAL (4xx) or an ordinary answer, never a server
fault. `read-json-body` used to hand such a value straight to handlers that
`hash-ref` it, which is a 500 for a mistake that is entirely the caller's — the
Research tab found it by sending `JSON.stringify(...)` through `api()`, which
encodes the body itself. Whether the route then DOES anything sensible with an
empty body is each route's own business and is not asserted here.

A 500 is what `handle` answers for an unhandled exception, so it is the fault
this looks for, along with a dropped connection. Another 5xx is a deliberate
answer — `/api/agent` is a 503 naming TMACH_MODEL_URL on a box with no model,
whatever the body — and is left alone.

Path parameters are filled with a value that names nothing, so most routes
answer 404 — and still have to get there without a 500.
"""
import json
import sys
import urllib.error
import urllib.request

# A route that would end the very session the sweep is using. Nothing else is
# excluded: the sweep runs near the end of the smoke, so what it changes is
# changed for nothing after it.
SKIP = {("POST", "/api/logout")}
BODIES = ['"x"', "[1]", "1", "null"]


def fill(path):
    return "/".join(
        "nope" if seg.startswith(":") or seg.startswith("*") else seg
        for seg in path.split("/")
    )


def main():
    base, token, routes_file = sys.argv[1:4]
    if not base.startswith("http"):
        base = "http://" + base
    routes = []
    with open(routes_file) as f:
        for line in f:
            parts = line.split()
            if len(parts) == 2 and (parts[0], parts[1]) not in SKIP:
                routes.append((parts[0], parts[1]))
    bad = []
    for method, path in routes:
        for body in BODIES:
            req = urllib.request.Request(
                base + fill(path), data=body.encode(), method=method,
                headers={"Authorization": "Bearer " + token,
                         "Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=30) as r:
                    status = r.status
            except urllib.error.HTTPError as e:
                status = e.code
            except Exception as e:  # a dropped connection or a hang is a fault too
                status = "error: " + type(e).__name__
            if not isinstance(status, int) or status == 500:
                bad.append(f"{method} {path} body={body} -> {status}")
    print(json.dumps({"routes": len(routes), "requests": len(routes) * len(BODIES),
                      "faults": bad}))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
