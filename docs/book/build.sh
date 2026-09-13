#!/usr/bin/env bash
# Build the developer e-book two ways from one LaTeX source (run inside `nix develop`):
#   telemachus-for-developers.pdf   — tectonic (fetches TeX packages on first run, then cached)
#   telemachus-for-developers.html  — pandoc, one self-contained page with a table of contents
set -eu
cd "$(dirname "$0")"
SRC=telemachus-for-developers.tex
tectonic --keep-logs -o . "$SRC" >/dev/null
# the HTML edition: the same source with the PDF-only switch off (no titlepage,
# no titlesec); the sketches are embedded as data URIs by --embed-resources
sed 's/\\pdfonlytrue/\\pdfonlyfalse/' "$SRC" > .html-source.tex
pandoc .html-source.tex --from latex --to html5 --standalone --toc --toc-depth=2 \
  --number-sections --css book.css --embed-resources --resource-path=. \
  --metadata title="Telemachus for Developers" \
  -o telemachus-for-developers.html
rm -f telemachus-for-developers.log .html-source.tex
echo "built: $(du -h telemachus-for-developers.pdf | cut -f1) PDF, $(du -h telemachus-for-developers.html | cut -f1) HTML"
