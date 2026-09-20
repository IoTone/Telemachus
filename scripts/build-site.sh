#!/usr/bin/env bash
# scripts/build-site.sh — assemble the published site into build/site/.
#
# What gets published: the developer e-book (both editions, already built and
# committed by docs/book/build.sh), the integrator's guide, the GENERATED
# reference, the operator runbooks and the design documents. Everything is
# rendered from what is already in the repository, so the site cannot disagree
# with the source it describes — and nothing here needs a toolchain beyond
# pandoc, which is why CI can publish without Nix or LaTeX.
#
#   bash scripts/build-site.sh          # -> build/site
#   SITE_OUT=/tmp/site bash scripts/build-site.sh
#
# Links are rewritten by scripts/site/links.lua: a link to another published
# page stays local, and a link to a source file goes to GitHub.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
OUT="${SITE_OUT:-$ROOT/build/site}"
FILTER="$ROOT/scripts/site/links.lua"

command -v pandoc >/dev/null || { echo "build-site: pandoc is required"; exit 2; }

rm -rf "$OUT"; mkdir -p "$OUT"
cp "$ROOT/scripts/site/site.css" "$OUT/site.css"

# ---- one markdown page -------------------------------------------------------
# $1 source, $2 destination (relative to $OUT), $3 title
page() {
  local src="$1" dst="$2" title="$3"
  local dir depth up
  dir="$(dirname "$dst")"
  depth=0; [ "$dir" != "." ] && depth=$(awk -F/ '{print NF}' <<<"$dir")
  up=""; for ((i=0;i<depth;i++)); do up="../$up"; done
  mkdir -p "$OUT/$(dirname "$dst")"
  # SITE_PAGE_DIR tells the filter where this page sits, so a ../ link resolves
  # to the right place in the repository
  SITE_PAGE_DIR="$(dirname "${src#$ROOT/}")" \
  pandoc "$src" --from gfm --to html5 --standalone --lua-filter "$FILTER" \
    --metadata title="$title" \
    --css "${up}site.css" \
    --include-before-body=<(printf '<a class="backlink" href="%sindex.html">&larr; Telemachus</a>\n' "$up") \
    --include-after-body=<(printf '<footer class="site">Telemachus &middot; MIT &middot; <a href="https://github.com/IoTone/Telemachus">source on GitHub</a></footer>\n') \
    -o "$OUT/$dst"
}

# ---- the book ----------------------------------------------------------------
# The site mirrors the REPOSITORY's layout, .md becoming .html, so every relative
# link between documents resolves on the site exactly as it does in a checkout.
# Flattening the paths broke four links the first time this ran.
mkdir -p "$OUT/docs/book"
cp "$ROOT/docs/book/telemachus-for-developers.html" "$OUT/docs/book/index.html"
cp "$ROOT/docs/book/telemachus-for-developers.pdf"  "$OUT/docs/book/telemachus-for-developers.pdf"

# ---- the prose pages ---------------------------------------------------------
page "$ROOT/README.md"        "readme.html"      "Telemachus"
page "$ROOT/CONTRIBUTING.md"  "contributing.html" "Contributing"

for f in "$ROOT"/docs/*.md; do
  b="$(basename "$f" .md)"
  t="$(sed -n 's/^# //p' "$f" | head -1)"; [ -n "$t" ] || t="$b"
  page "$f" "docs/$b.html" "$t"
done
for f in "$ROOT"/docs/reference/*.md; do
  b="$(basename "$f" .md)"; page "$f" "docs/reference/$b.html" "Reference — $b"
done
for f in "$ROOT"/docs/reference/ja/*.md; do
  [ -e "$f" ] || continue
  b="$(basename "$f" .md)"; page "$f" "docs/reference/ja/$b.html" "リファレンス — $b"
done
for f in "$ROOT"/docs/ops/*.md; do
  b="$(basename "$f" .md)"; page "$f" "docs/ops/$b.html" "Runbook — $b"
done
for f in "$ROOT"/docs/design/*.md; do
  b="$(basename "$f" .md)"; page "$f" "docs/design/$b.html" "Design — $b"
done

# ---- the landing page --------------------------------------------------------
# Written here rather than kept as a file so the design-document list cannot go
# stale: it is generated from what is on disk.
design_items=""
for f in "$ROOT"/docs/design/*.md; do
  b="$(basename "$f" .md)"
  t="$(sed -n 's/^# //p' "$f" | head -1)"; [ -n "$t" ] || t="$b"
  design_items="$design_items      <li><a href=\"docs/design/$b.html\">$t</a></li>\n"
done
ops_items=""
for f in "$ROOT"/docs/ops/*.md; do
  b="$(basename "$f" .md)"
  t="$(sed -n 's/^# //p' "$f" | head -1)"; [ -n "$t" ] || t="$b"
  ops_items="$ops_items      <li><a href=\"docs/ops/$b.html\">$t</a></li>\n"
done

cat > "$OUT/index.html" <<HTML
<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Telemachus — a self-hosted platform for a team's AI tools</title>
<meta name="description" content="Telemachus is a clean-MIT, team-oriented, self-hosted, privacy-first, Racket-first platform for hosting AI tools and applications. Documentation, the developer e-book and the generated API reference.">
<meta property="og:title" content="Telemachus">
<meta property="og:description" content="A self-hosted, privacy-first platform for a team's AI tools and applications. Racket-first, clean MIT.">
<meta property="og:type" content="website">
<link rel="stylesheet" href="site.css">
</head><body>
<header class="site">
  <div class="mark"><h1>Telemachus<span class="dot">.</span></h1></div>
  <p>A self-hosted, privacy-first platform for a team's AI tools and applications. Racket-first, clean MIT — no open core, no held-back tier.</p>
</header>
<main>
  <p class="lede">A team uploads its documents, talks to a model about them, runs workflows over them, shares the results with exactly the people who should see them, and does all of it on a machine the team controls.</p>

  <h2>Start here</h2>
  <ul class="cards">
    <li><h3><a href="docs/book/index.html">Telemachus for Developers</a></h3><p>The book: how the platform is built, and the decisions that were expensive to learn. Also as a <a href="docs/book/telemachus-for-developers.pdf">PDF</a>.</p></li>
    <li><h3><a href="docs/integrators-guide.html">Integrator's guide</a></h3><p>Putting your own product on the platform: theme the console, ship tools, serve your own screens and API.</p></li>
    <li><h3><a href="readme.html">Read me first</a></h3><p>What it is, what runs today, and how to get it running.</p></li>
    <li><h3><a href="docs/reference/README.html">Reference</a></h3><p>Generated from the source: every route, tool, workflow, permission and plugin seam.</p></li>
  </ul>

  <h2>Reference</h2>
  <p class="meta">Generated by <code>telemachus-docs</code> from the route table, the tool registry, the plugin loader, the workflow specs and the permission catalog — and gated in CI, so it cannot drift from the code.</p>
  <ul>
    <li><a href="docs/reference/api.html">HTTP API</a> — every route with its authentication, permission and feature flag</li>
    <li><a href="docs/reference/tools.html">Tools</a> — schema, permission and source for each</li>
    <li><a href="docs/reference/workflows.html">Workflows</a> — the shipped specs, step by step</li>
    <li><a href="docs/reference/permissions.html">Permissions</a> — the catalog and the role matrix</li>
    <li><a href="docs/reference/plugins.html">Plugins</a> — loaded plugins and the seams a plugin may fill</li>
    <li><a href="docs/reference/sdk.html">SDK</a> — the authoring surfaces</li>
    <li><a href="docs/reference/ja/README.html">日本語版</a></li>
  </ul>

  <h2>Operating</h2>
  <ul>
$(printf "$ops_items")  </ul>

  <h2>Design</h2>
  <p class="meta">Why each subsystem is shaped as it is, with the data shapes and the decisions.</p>
  <ul>
$(printf "$design_items")  </ul>

  <h2>The code</h2>
  <p>The reference implementation is Racket 9.2 under <code>refimpl/racketmaximus/</code>; Nix is the toolchain. The durable product is the contract — the SDK, the APIs, the security model, the protocols — so a second implementation can target the same specs.</p>
  <p><a href="https://github.com/IoTone/Telemachus">github.com/IoTone/Telemachus</a> &middot; <a href="contributing.html">Contributing</a></p>
</main>
<footer class="site">© 2026 IoTone, Inc. &middot; MIT &middot; built from the repository by <code>scripts/build-site.sh</code></footer>
</body></html>
HTML

# Pages serves this as-is; no Jekyll processing, which would eat files whose
# names begin with an underscore.
touch "$OUT/.nojekyll"

echo "build-site: $(find "$OUT" -name '*.html' | wc -l | tr -d ' ') pages -> $OUT"
