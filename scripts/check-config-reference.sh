#!/usr/bin/env bash
# scripts/check-config-reference.sh — every TELEMACHUS_* the code reads must be
# in docs/ops/configuration.md (issue #89).
#
# A container is configured entirely by its environment, so that page is the
# interface. A variable the code reads and the page does not mention is invisible
# to the person deploying it; a variable the page documents and the code no
# longer reads sends them to set something with no effect. Both are build
# failures here, which is the same bargain the generated reference under
# docs/reference/ already makes.
#
#   bash scripts/check-config-reference.sh
set -uo pipefail
cd "$(dirname "$0")/.."

DOC=docs/ops/configuration.md
[ -f "$DOC" ] || { echo "missing $DOC"; exit 1; }

# Names that are built at runtime rather than written out, so a literal grep
# cannot see the whole thing. Each needs a reason, not just an entry.
#
#   TELEMACHUS_MODEL_   `(string-append "TELEMACHUS_MODEL_" (string-upcase role))`
#                       in domain/ai/roles.rkt — the prefix of a per-role name.
#                       Documented as TELEMACHUS_MODEL_<ROLE>.
# A plain space-separated list, not an associative array: macOS ships bash 3.2,
# where `declare -A` silently becomes an indexed array and the subscript is
# evaluated as arithmetic — which under `set -u` fails with "unbound variable"
# on the key itself. This gate has to run on a developer's Mac as well as CI.
RUNTIME_PREFIXES="TELEMACHUS_MODEL_"

# What the code reads. Scanned over every source kind that can read the
# environment, including the shell harnesses and the Nix files — a variable only
# a smoke script sets is still one an operator can meet.
in_code=$(grep -rhoE 'TELEMACHUS_[A-Z0-9_]+' \
            --include='*.rkt' --include='*.sh' --include='*.nix' \
            --include='*.mjs' --include='*.js' --include='*.yaml' --include='*.yml' \
            refimpl nix scripts flake.nix .github 2>/dev/null \
          | sort -u)

# What the page documents. Table cells are `| `NAME` | …`, and the per-role entry
# is written with a placeholder, so strip the angle-bracket suffix to compare.
in_doc=$(grep -oE '`TELEMACHUS_[A-Z0-9_]+(<ROLE>)?`' "$DOC" \
         | tr -d '`' | sed 's/<ROLE>//' | sort -u)

runtime_built(){ case " $RUNTIME_PREFIXES " in *" $1 "*) return 0;; *) return 1;; esac; }

missing=""
for v in $in_code; do
  printf '%s\n' "$in_doc" | grep -qx "$v" && continue
  # a runtime-built prefix is satisfied by its documented placeholder
  runtime_built "$v" && continue
  missing="$missing $v"
done

# The other direction: documented but no longer read anywhere.
stale=""
for v in $in_doc; do
  printf '%s\n' "$in_code" | grep -qx "$v" && continue
  runtime_built "$v" && continue
  stale="$stale $v"
done

rc=0
if [ -n "$missing" ]; then
  echo "FAIL: read by the code but not in $DOC:"
  for v in $missing; do echo "  $v"; done
  rc=1
fi
if [ -n "$stale" ]; then
  echo "FAIL: documented in $DOC but read nowhere:"
  for v in $stale; do echo "  $v"; done
  echo "  (If it was removed, remove its row. If it is built at runtime, add it to"
  echo "   RUNTIME_PREFIXES in this script with the reason.)"
  rc=1
fi

if [ $rc = 0 ]; then
  echo "config reference: OK ($(printf '%s\n' "$in_code" | grep -c . ) variable(s) documented)"
fi
exit $rc
