#!/usr/bin/env bash
# Build the developer e-book two ways from one LaTeX source (run inside `nix develop`):
#   telemachus-for-developers.pdf   — tectonic (fetches TeX packages on first run, then cached)
#   telemachus-for-developers.html  — pandoc, one self-contained page with a table of contents
set -eu
cd "$(dirname "$0")"
SRC=telemachus-for-developers.tex
tectonic --keep-logs -o . "$SRC" >/dev/null
pandoc "$SRC" --from latex --to html5 --standalone --toc --toc-depth=2 \
  --number-sections --css book.css --embed-resources \
  --metadata title="Telemachus for Developers" \
  -o telemachus-for-developers.html
rm -f telemachus-for-developers.log
echo "built: $(du -h telemachus-for-developers.pdf | cut -f1) PDF, $(du -h telemachus-for-developers.html | cut -f1) HTML"
