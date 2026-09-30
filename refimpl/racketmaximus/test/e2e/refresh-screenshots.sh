#!/usr/bin/env bash
# test/e2e/refresh-screenshots.sh — refresh the README feature tour.
#
# The tours in this directory already produce every screenshot the project needs;
# their output lives in catalog/ which is a BUILD ARTIFACT (gitignored, rebuilt by
# CI on every run). This script promotes that output to the committed set the
# top-level README links to:
#
#   1. runs both tours   (run.sh — feature walkthrough + beta funnel)
#   2. optimizes the PNGs into docs/screenshots/   (~50% smaller, same resolution)
#   3. rewrites the README tour section from the tours' own manifest.json captions
#
# Step 3 is why the captions in the README are never hand-copied: they are
# generated between the <!-- BEGIN/END FEATURE-TOUR --> markers, so a caption
# edited in run-tour.mjs / beta-tour.mjs reaches the README by re-running this.
#
#   bash test/e2e/refresh-screenshots.sh            # full: run tours, then promote
#   SKIP_TOURS=1 bash test/e2e/refresh-screenshots.sh   # promote an existing catalog/
#   README_ONLY=1 bash test/e2e/refresh-screenshots.sh  # rebuild both READMEs only
#
# README_ONLY is the mode a TRANSLATOR uses: it re-renders the tour sections from
# the already-committed manifests and caption catalogs, with no browser and no
# image work, so editing docs/screenshots/captions.ja.json and seeing the result
# does not cost a Playwright run.
#
# Screenshots are nicest with a local ollama running (run.sh points at it
# automatically); without one the server's deterministic fallback still produces a
# complete, if less interesting, tour.
set -euo pipefail
cd "$(dirname "$0")"                                  # refimpl/racketmaximus/test/e2e
E2E="$(pwd)"
ROOT="$(cd ../../../.. && pwd)"                       # repo root
DEST="$ROOT/docs/screenshots"

README_ONLY="${README_ONLY:-0}"

if [ "$README_ONLY" != "1" ]; then
  if [ "${SKIP_TOURS:-0}" != "1" ]; then
    echo "== running the tours =========================================="
    bash run.sh
  fi
  [ -f "$E2E/catalog/manifest.json" ] || { echo "no catalog/ — run without SKIP_TOURS=1" >&2; exit 1; }
fi

if [ "$README_ONLY" != "1" ]; then
echo "== promoting screenshots to docs/screenshots =================="
mkdir -p "$DEST/beta"
rm -f "$DEST"/*.png "$DEST"/beta/*.png

# Quantize to a 256-colour palette: these are flat UI screenshots, so it is
# visually lossless here and roughly halves the byte count. Do NOT downscale —
# resampling *increases* PNG size (more distinct colours) and blurs the text.
have(){ command -v "$1" >/dev/null 2>&1; }
promote(){ # <src-dir> <dst-dir>
  for f in "$1"/*.png; do
    local out="$2/$(basename "$f")"
    if have convert; then convert "$f" -strip -colors 256 "$out"; else cp "$f" "$out"; fi
    if have optipng; then optipng -quiet -o2 "$out"; fi
  done
}
promote "$E2E/catalog"      "$DEST"
promote "$E2E/catalog/beta" "$DEST/beta"
have convert  || echo "  note: ImageMagick not found — copied unoptimized"
have optipng  || echo "  note: optipng not found — skipped final pass"

# the manifests travel with the images: they are the caption source of truth
cp "$E2E/catalog/manifest.json"      "$DEST/manifest.json"
cp "$E2E/catalog/beta/manifest.json" "$DEST/beta/manifest.json"
fi

echo "== regenerating the README tour sections (en + ja) ============"
python3 - "$ROOT" <<'PY'
import hashlib, json, sys, pathlib

root = pathlib.Path(sys.argv[1])
shots = root / "docs" / "screenshots"
stale = []

# The English manifest is the source of truth for WHICH shots exist and in what
# order. A localized README is that same list with its title and caption swapped
# for a translation whose hash still matches the English it was made against —
# the rule locales/ja.json already lives by. Anything missing or stale falls back
# to English and is reported, because a half-translated page that looks finished
# is worse than an obviously untranslated one.
def load_captions(path):
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8")).get("captions", {})

def entry_for(e, captions, lang):
    if not captions:
        return e["title"], e["caption"]
    t = captions.get(e["file"])
    src = e["title"] + "\n" + e["caption"]
    if not t:
        stale.append(f"{lang}: {e['file']} has no translation")
        return e["title"], e["caption"]
    if t.get("hash") != hashlib.sha1(src.encode("utf-8")).hexdigest():
        stale.append(f"{lang}: {e['file']} is STALE (the English changed)")
        return e["title"], e["caption"]
    return t["title"], t["caption"]

def section(manifest, prefix, captions, lang, level="###"):
    out = []
    for e in json.load(open(manifest)):
        title, caption = entry_for(e, captions, lang)
        out.append(f"{level} {title}\n")
        out.append(f"![{title}]({prefix}{e['file']})\n")
        out.append(f"{caption}\n")
    return "\n".join(out)

LANGS = {
    "en": {
        "readme": "README.md",
        "captions": None,
        "intro": [
            "Every screenshot below is produced by the Playwright tours in",
            "[`refimpl/racketmaximus/test/e2e/`](refimpl/racketmaximus/test/e2e/), which drive a real",
            "server on a throwaway database — nothing here is a mockup. CI runs those same tours on",
            "every push, so the flows stay exercised; the images committed here are refreshed by",
            "re-running the script noted below.",
        ],
        "beta_head": "### Beta onboarding funnel",
        "beta_blurb": [
            "A pre-sales lead funnel that a deployer skins and owns — three render tiers, all through",
            "one anti-abuse gate. See [docs/design/beta-onboarding-experience.md](docs/design/beta-onboarding-experience.md).",
        ],
        "summary": "10 more screenshots — the public funnel, the LLM judge, and all three render tiers",
    },
    "ja": {
        "readme": "README.ja.md",
        "captions": "captions.ja.json",
        "intro": [
            "以下のスクリーンショットはすべて、",
            "[`refimpl/racketmaximus/test/e2e/`](refimpl/racketmaximus/test/e2e/) の Playwright ツアーが",
            "使い捨てのデータベース上で実際のサーバーを操作して生成したものである — モックアップは一枚もない。",
            "CI は push ごとに同じツアーを実行するので、これらの流れは常に検証されている。ここにコミットされて",
            "いる画像は、下に記したスクリプトを再実行して更新する。",
        ],
        "beta_head": "### ベータ用オンボーディングファネル",
        "beta_blurb": [
            "導入者が外観を変えて自ら所有する、商談前のリード獲得ファネル — 3 つの描画ティアがあり、",
            "いずれも同じ不正利用対策のゲートを通る。",
            "[docs/design/beta-onboarding-experience.md](docs/design/beta-onboarding-experience.md) を参照。",
        ],
        "summary": "さらに 10 枚 — 公開ファネル、LLM による判定、3 つの描画ティアすべて",
    },
}

BEGIN, END = "<!-- BEGIN FEATURE-TOUR -->", "<!-- END FEATURE-TOUR -->"

for lang, cfg in LANGS.items():
    readme = root / cfg["readme"]
    if not readme.exists():
        print(f"  skipped {cfg['readme']} (not present)")
        continue
    caps_main = load_captions(shots / cfg["captions"]) if cfg["captions"] else None
    caps_beta = load_captions(shots / "beta" / cfg["captions"]) if cfg["captions"] else None
    body = [
        "<!-- Generated by refimpl/racketmaximus/test/e2e/refresh-screenshots.sh — do not edit by hand. -->",
        "",
        *cfg["intro"],
        "",
        section(shots / "manifest.json", "docs/screenshots/", caps_main, lang),
        "",
        cfg["beta_head"],
        "",
        *cfg["beta_blurb"],
        "",
        "<details>",
        f"<summary><b>{cfg['summary']}</b></summary>",
        "",
        section(shots / "beta" / "manifest.json", "docs/screenshots/beta/", caps_beta, lang, level="####"),
        "</details>",
    ]
    text = readme.read_text(encoding="utf-8")
    if BEGIN not in text or END not in text:
        sys.exit(f"markers {BEGIN} / {END} not found in {cfg['readme']}")
    head, rest = text.split(BEGIN, 1)
    _, tail = rest.split(END, 1)
    readme.write_text(f"{head}{BEGIN}\n\n" + "\n".join(body).rstrip() + f"\n\n{END}{tail}",
                      encoding="utf-8")
    print(f"  {cfg['readme']} tour section rewritten")

if stale:
    print()
    print("  %d caption(s) fell back to English:" % len(stale))
    for m in stale:
        print("    " + m)
    print("  fix them in docs/screenshots/captions.<lang>.json, then re-run with README_ONLY=1")
PY

echo
if [ "$README_ONLY" = "1" ]; then
  echo "done — READMEs rebuilt from the committed manifests (no tours, no images)"
else
  echo "done — $(ls "$DEST"/*.png "$DEST"/beta/*.png | wc -l) screenshots, $(du -sh "$DEST" | cut -f1)"
fi
