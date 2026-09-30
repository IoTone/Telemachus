#!/usr/bin/env bash
# Build the developer e-book from MARKDOWN (run inside `nix develop`):
#
#   bash docs/book/build.sh          # the English edition
#   bash docs/book/build.sh ja       # a translated edition, from ja/
#   bash docs/book/build.sh ja --record   # stamp ja/*.md with the English hashes
#
# The source is one Markdown file per chapter under <lang>/, because a translator
# must never have to edit LaTeX. The chapter ORDER, each chapter's ART and the
# unnumbered flag live in chapters.json, so a translated title cannot reorder the
# book or lose its sketch. Per-language metadata (title, author, date) is
# <lang>/book.yaml. The LaTeX preamble is template/book.latex.
#
# Two outputs per language, from the same Markdown:
#   telemachus-for-developers[.<lang>].pdf    — tectonic
#   telemachus-for-developers[.<lang>].html   — pandoc, one self-contained page
set -eu
cd "$(dirname "$0")"
LANG_DIR="${1:-en}"
[ -d "$LANG_DIR" ] || { echo "no such language directory: $LANG_DIR" >&2; exit 1; }
[ -f "$LANG_DIR/book.yaml" ] || { echo "missing $LANG_DIR/book.yaml" >&2; exit 1; }
RECORD=""; if [ "${2:-}" = "--record" ]; then RECORD="record"; fi
SUFFIX=""; [ "$LANG_DIR" = "en" ] || SUFFIX=".$LANG_DIR"
OUT="telemachus-for-developers$SUFFIX"

# ---- assemble ----------------------------------------------------------------
# Each chapter gets, injected here rather than kept in the translator's file:
#   * a raw-LaTeX \chapterart{...}, which the HTML writer ignores by construction
#   * an explicit heading id taken from the chapter's art stem, so the HTML's
#     art CSS (h1#<stem>::before) keys on the FILE and survives translation. The
#     ids pandoc derives from a title would change in every language.
# The intermediate lives HERE, not in /tmp: the art is referenced as art/*.png,
# relative to this directory, and tectonic resolves those against the .tex it is
# handed. A temp-dir build fails with "Unable to load picture".
ASSEMBLED=".book.$LANG_DIR.md"
TEXFILE=".book.$LANG_DIR.tex"
# KEEP=1 leaves the assembled Markdown, the generated .tex and the TeX log in
# place. A LaTeX error names a line in the GENERATED file, so without this there is
# nothing left to look at by the time you read the message.
[ "${KEEP:-0}" = "1" ] || trap 'rm -f "$ASSEMBLED" "$TEXFILE" ".book.$LANG_DIR.log"' EXIT
python3 - "$LANG_DIR" "$ASSEMBLED" $RECORD <<'PY'
import hashlib, json, pathlib, re, sys
lang, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
record = len(sys.argv) > 3 and sys.argv[3] == "record"

# A translated chapter carries the sha1 of the ENGLISH chapter it was made
# against, on its first line, exactly as locales/ja.json carries a source hash
# beside each translated string. Editing the English therefore makes the
# translation stale with nothing rewriting a status. The stamp is injected and
# stripped here, so a translator never has to maintain it: whoever integrates a
# finished translation runs `bash build.sh <lang> --record`.
STAMP = re.compile(r"\A<!--\s*source-sha1:\s*([0-9a-f]{40})\s*-->[ \t]*\n")
def english_sha1(stem):
    f = pathlib.Path("en") / (stem + ".md")
    return hashlib.sha1(f.read_bytes()).hexdigest() if f.exists() else None
chapters = json.loads(pathlib.Path("chapters.json").read_text(encoding="utf-8"))
missing, parts, offenders, warnings, stamped = [], [], [], [], []
seen_art = {}
for c in chapters:
    if c["art"] in seen_art:
        sys.exit("chapters.json: %s and %s share art %s; the art stem is the chapter's "
                 "heading id, so two chapters cannot share one" % (seen_art[c["art"]], c["file"], c["art"]))
    seen_art[c["art"]] = c["file"]
for ch in chapters:
    f = lang / (ch["file"] + ".md")
    if not f.exists():
        missing.append(ch["file"]); continue
    text = f.read_text(encoding="utf-8")
    stamp = STAMP.match(text)
    if stamp: text = text[stamp.end():]
    if lang.name != "en":
        want = english_sha1(ch["file"])
        if record:
            body_now = text
            f.write_text("<!-- source-sha1: %s -->\n%s" % (want, body_now), encoding="utf-8")
            stamped.append(ch["file"]); continue
        if want is None:
            warnings.append("%s: no English chapter en/%s.md to check against" % (f, ch["file"]))
        elif not stamp:
            warnings.append("%s: UNSTAMPED — run `bash build.sh %s --record` once it is "
                            "checked against the English" % (f, lang.name))
        elif stamp.group(1) != want:
            warnings.append("%s: STALE — the English chapter changed since this was "
                            "translated" % f)
    m = re.match(r"[ \t]*#[ \t]+(.+?)[ \t]*\n", text)
    if not m:
        sys.exit(f"{f}: must begin with a single '# Title' line")
    # .unlisted as well as .unnumbered: pandoc's .unnumbered alone still writes an
    # \addcontentsline, so the chapter would appear in the table of contents that
    # \chapter* deliberately kept it out of.
    attrs = "#" + ch["art"] + (" .unnumbered .unlisted" if ch.get("unnumbered") else "")
    body = text[m.end():].rstrip()
    # Scripts that belong in no edition of this book. A machine-assisted or hurried
    # translation leaks them: the project's own Japanese catalog came back with
    # French, Spanish and Chinese fragments, and the first hand-written sample
    # chapter here shipped a Russian word. A warning, not a refusal — script
    # detection is a heuristic and a quotation could be legitimate.
    for name, lo, hi in (("Cyrillic",0x0400,0x04FF), ("Hangul",0xAC00,0xD7AF),
                         ("Arabic",0x0600,0x06FF), ("Hebrew",0x0590,0x05FF),
                         ("Thai",0x0E00,0x0E7F), ("Devanagari",0x0900,0x097F)):
        found = sorted({c for c in text if lo <= ord(c) <= hi})
        if found:
            warnings.append("%s: %s characters in the prose: %s"
                            % (f, name, "".join(found)[:24]))
    # A code span must be ASCII. It names an identifier, a path or a command, so a
    # typographic quote or a full-width character in one is always a mistake — and
    # an easy one to make with a Japanese input method. Refuse by name here: left
    # alone it surfaces as `Undefined control sequence` pointing at a line in a
    # generated file that build.sh has already deleted.
    for cm in re.finditer(r"`([^`\n]+)`", text):
        bad = [c for c in cm.group(1) if ord(c) > 127]
        if bad:
            offenders.append("%s: code span %s contains %s"
                             % (f, cm.group(0), " ".join("U+%04X" % ord(c) for c in dict.fromkeys(bad))))
    # `toc_after` reproduces the original book's order: the front matter chapter
    # comes BEFORE the table of contents. A template cannot express that, because
    # it sees the chapters as one $body$.
    toc = "\n```{=latex}\n\\tableofcontents\n```\n" if ch.get("toc_after") else ""
    parts.append("```{=latex}\n\\chapterart{art/%s.png}\n```\n\n# %s {%s}\n\n%s\n%s"
                 % (ch["art"], m.group(1).strip(), attrs, body, toc))
for w in warnings: print("  WARNING " + w)
if offenders:
    for o in offenders: print("  " + o)
    sys.exit("refusing to build: a code span must be ASCII (%d offender(s))" % len(offenders))
# The HTML edition opens with the title block and the cover sketch, as it did when
# both editions came from one .tex. A raw-HTML block is the mirror of the
# raw-LaTeX \chapterart above: the LaTeX writer drops it, and --embed-resources
# turns the src into a data URI so the page stays one file.
cover = ('```{=html}\n<div class="cover">'
         '<img src="art/telemachus-sketch.png" alt="Telemachus, a concept sketch">'
         '</div>\n```\n')
if record:
    for x in stamped: print("  stamped %s" % x)
    print("recorded %d chapter(s) against the current English; nothing built" % len(stamped))
    sys.exit(0)
out.write_text(cover + "\n" + "\n".join(parts), encoding="utf-8")
if missing:
    print("  %d chapter(s) NOT TRANSLATED, omitted from this edition:" % len(missing))
    for x in missing: print("    " + x)
PY

# A --record run rewrites the translated chapters and builds nothing.
if [ -n "$RECORD" ]; then exit 0; fi

# ---- the PDF -----------------------------------------------------------------
pandoc "$ASSEMBLED" --metadata-file="$LANG_DIR/book.yaml" \
  --from markdown --to latex --template=template/book.latex \
  --top-level-division=chapter --listings --resource-path=. \
  -o "$TEXFILE"
tectonic --keep-logs -o . "$TEXFILE" >/dev/null
mv ".book.$LANG_DIR.pdf" "$OUT.pdf"

# ---- the HTML ----------------------------------------------------------------
# The sketches ride in as data URIs via --embed-resources, so the page is one file.
pandoc "$ASSEMBLED" --metadata-file="$LANG_DIR/book.yaml" \
  --from markdown --to html5 --standalone --toc --toc-depth=2 \
  --number-sections --css book.css --css art/chapter-art.css \
  --embed-resources --resource-path=. -o "$OUT.html"

echo "built: $(du -h "$OUT.pdf" | cut -f1) PDF, $(du -h "$OUT.html" | cut -f1) HTML  [$LANG_DIR]"
