#!/usr/bin/env python3
"""ORG-11's one real property, asserted over the STORED bytes.

`server-smoke.sh` asserts with `grep`, which cannot say "these two strings are
equal" — `differ()` exists for the opposite question and a prefix would satisfy
it. The round trip being byte-identical FOR THE BODY is the only property a user
of this interchange cares about, so it is checked by comparing the two bodies
and nothing else. Run with -I: it reads no files and imports nothing local, but
the rule is the rule for anything a smoke shells out to.
"""
import json
import sys
import urllib.request

# `$B` IN THIS SUITE CARRIES NO SCHEME (`127.0.0.1:8835`). `curl` tolerates that
# and `urllib` does not — it raises "unknown url type: 127.0.0.1" — so the scheme
# is added here rather than in the caller, where every other use of `$B` is a
# curl and would not want it.
B, tok, a, b = sys.argv[1:5]
if "://" not in B:
    B = "http://" + B


def body(note_id):
    req = urllib.request.Request(B + "/api/notes/" + note_id,
                                 headers={"Authorization": "Bearer " + tok})
    return json.loads(urllib.request.urlopen(req).read().decode("utf-8"))["body"]


ba, bb = body(a), body(b)
if ba == bb:
    print("  ok   org file: the body round-trips BYTE-IDENTICALLY")
    sys.exit(0)
print("  FAIL org file: the body changed — %r vs %r" % (ba, bb))
sys.exit(1)
