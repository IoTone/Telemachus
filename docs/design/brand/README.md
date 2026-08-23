# Telemachus — brand

The mark is **Mentor** — direction **02** of the nine-direction identity study,
adopted as drawn there.

> Athena came to Telemachus disguised as Mentor — an intelligence wearing a familiar
> form, telling a young man to go and find out who he is. The word *mentor* comes
> from that disguise. It is the closest thing in literature to an honest description
> of an assistant, and it is the reason this project has this name.

An arched helm. Its two **diamond eyes** are an owl's. Its nasal guard runs the full
drop of the face, and the **gold brow bar** laid across the top of that guard
completes a **T**. Helm, owl, letter — three readings of one drawing.

The eyes **cross** the guard rather than sitting beside it, so the three holes are a
single continuous void: two diamonds threaded on a line.

## Files

| File | Use |
|---|---|
| `mentor-mark.svg` | primary — aegean helm, gold brow. Light grounds |
| `mentor-mark-reversed.svg` | bone helm, gold brow, for aegean/dark grounds. **The study's own presentation** |
| `mentor-mark-mono.svg` | one path, `currentColor`, no brow bar. **Default for anything in-product** |
| `mentor-mark-32.svg` | 24–40 px |
| `mentor-mark-16.svg` | **≤ 20 px.** A different drawing, not a smaller one |
| `favicon.svg` | browser tabs — the 16 drawing, carrying its own ground |
| `mentor-lockup.svg` | horizontal, mark + wordmark |
| `mentor-lockup-stacked.svg` | vertical, with the descriptor line |
| `can-submark.svg` | optional technical sub-mark — direction 04 (see below) |

## Two things about this mark that are easy to get wrong

**The brow bar is the crossbar of the T, and it is the only part that needs a second
colour.** Drop the gold and you keep the helm and the owl but lose the letter. That
is why the study itself omits the bar at 32 and 16, and why `mentor-mark-mono.svg`
omits it too: below a certain size a 3.4-unit gold rule is mud, and one honest
reading beats three muddy ones. Where a second colour is available and the mark is
large enough to carry it — a title slide, a README header, the top of a page — use a
file **with** the bar. It is the whole double-read.

The bar also overhangs the dome slightly at each end. That is drawn, not a bug: it
reads as a crest band crossing the helm rather than a chord inside it.

**The nasal guard runs to the base, and splits it.** The two shapes it leaves are the
cheek pieces, and they are meant to be there. Do not shorten the guard to close the
base — that is a different mark.

## The fill rule is `nonzero`, and the holes are wound counter-clockwise

Not decoration — the mark does not work without it. The study painted the eyes and
the nasal bar as opaque `#132c46` shapes sitting *on* the helm, which works on the
study's own aegean field and nowhere else, so here they are real holes instead. Every
eye crosses the guard, and under `evenodd` two overlapping holes **cancel**: each
crossing would fill back in and weld the face shut. With `nonzero` and counter-wound
holes they union, which is the drawing.

**How far the eye crosses the bar is load-bearing.** A diamond that merely reaches the
bar's edge meets it at a knife point and renders as a pinch, not a connection. Each
eye's inner vertex therefore lands past the far edge; measured at the near edge the
join is about 5.5 units tall at 64, and wider at the smaller sizes.

If you edit these paths, re-render them and look. A broken fill rule is invisible in
the markup and obvious on screen — and so is an illegal `--` inside an SVG comment,
which makes the file silently fail to parse as an image.

## Why there are three drawings

The same path scaled down is not the same mark. Going small, the diamonds open
(half-diagonal 6 → 6.5 → 7.5) and the nasal widens (5 → 6 → 7) and drops below the
brow. Use the file that matches the size you are rendering at; do not scale one to
cover the range.

| | eyes (cx · half-diagonal) | nasal | brow |
|---|---|---|---|
| **64** | 26.5 / 37.5 · 6 | 5 wide, from y 26 | gold, in the primary |
| **32** | 26.5 / 37.5 · 6.5 | 6 wide, from y 26 | dropped |
| **16** | 26 / 38 · 7.5 | 7 wide, from y 30 | dropped |

## Palette

| Token | Hex | Role |
|---|---|---|
| `--tmx-aegean` | `#132c46` | primary. The mark, headers, the favicon ground |
| `--tmx-gold` | `#c9a227` | accent — and the brow bar. One other thing per view, at most |
| `--tmx-olive` | `#7d8c4a` | secondary, for supporting states |
| `--tmx-bone` | `#f2ede1` | light ground and knockout |
| `--tmx-deep` | `#0b1a2b` | dark ground, below aegean |

Gold is a *punctuation* colour. On a page that shows the mark with its brow bar, the
bar is the gold.

## Type

- **Display — Fraunces.** An old-style with deliberate wonk: classical bones without
  the costume. Headings and the wordmark only.
- **Text — Archivo.** Quiet, good small, not Inter.
- **Code — IBM Plex Mono**, matching the rest of the docs.

The wordmark in the lockup SVGs is live text with a serif fallback stack. **For print
or anywhere font loading is not guaranteed, outline it first.**

## Clear space and minimums

The mark is 38 units wide in a 64-unit viewBox. Clear space on every side is **half
that width — 19 units**. Minimum sizes: 16 px on screen using the 16 file, 8 mm in
print.

## Do not

- Re-proportion the mark, or scale one drawing across the whole size range
- Shorten the nasal guard so the base closes, or pull the eyes back so they only
  touch the guard instead of crossing it
- Drop the brow bar where colour is available and the size allows it
- Rotate it, outline it, add a gradient, or put it on a busy photograph
- Recolour the helm in gold — gold is the brow bar and the accent
- Place the sub-mark inside a lockup with the primary; they are alternates, not a pair

## The sub-mark

`can-submark.svg` is direction **04** of the same study, kept as an alternate: three
arrows, one gate, one arrow out — the console, the API and the S3 endpoint all
passing through `can?`. It says the one true thing about the architecture, to the
people who will check whether it is true.

Use it on README badges, the architecture page and CLI output. It never appears
beside the primary mark in the same lockup.

## In the product

The console carries the mark inline in `static/index.html` (`markSVG()`, which picks
the drawing by pixel size), and the favicon is an inline `data:` URI so it costs no
extra request and no build step. If you change the geometry here, change it there —
they are duplicated on purpose, so the console has no asset dependency, which means
they can drift.

## Provenance

Drawn for this project; no third-party assets, no licensed typefaces embedded.
Fraunces and Archivo are SIL Open Font License. Consistent with the clean-MIT
commitment: everything in this directory ships under the repository's licence.
