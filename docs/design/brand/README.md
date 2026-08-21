# Telemachus — brand

The mark is **Mentor**, chosen from nine directions in the identity study.

> Athena came to Telemachus disguised as Mentor — an intelligence wearing a familiar
> form, telling a young man to go and find out who he is. The word *mentor* comes
> from that disguise. It is the closest thing in literature to an honest description
> of an assistant, and it is the reason this project has this name.

A Corinthian helm's face opening is already a **T**. So one aperture does three jobs
at once: the silhouette is a helm, the rounded terminals read as an owl's eyes, and
the void is the letter. One shape, three readings, no explanation required.

## Files

| File | Use |
|---|---|
| `mentor-mark.svg` | primary, aegean fill. Presentations, README, anywhere on a light ground |
| `mentor-mark-mono.svg` | one path, `currentColor`. **Default for anything in-product** |
| `mentor-mark-32.svg` | 24–40 px |
| `mentor-mark-16.svg` | **≤ 20 px.** A different drawing, not a smaller one |
| `favicon.svg` | browser tabs — carries its own ground |
| `mentor-lockup.svg` | horizontal, mark + wordmark |
| `mentor-lockup-stacked.svg` | vertical, with the descriptor line |
| `can-submark.svg` | optional technical sub-mark (see below) |

## Why there are three drawings

The same path scaled down is not the same mark. Below about 20 px the aperture silts
up and the T stops reading, so `mentor-mark-16.svg` widens the dome and thickens both
the slot and the stem. Use the file that matches the size you are rendering at; do
not scale one to cover the range.

Two geometric rules keep the silhouette clean, and both were violated in the first
draft:

- the aperture sits entirely **below the arc springline** (`y = 29`) and **inside the
  straight sides** (`x = 16…48`). Its round caps otherwise poke through the outline,
  and with `fill-rule="evenodd"` they render as filled nubs on the edge;
- the stem **stops short of the base**. Running it to the bottom splits the helm into
  two legs and the mark reads as a small creature instead.

## Palette

| Token | Hex | Role |
|---|---|---|
| `--tmx-aegean` | `#132c46` | primary. The mark, headers, the favicon ground |
| `--tmx-gold` | `#c9a227` | accent. One thing per view — never a second |
| `--tmx-olive` | `#7d8c4a` | secondary, for supporting states |
| `--tmx-bone` | `#f2ede1` | light ground and knockout |
| `--tmx-deep` | `#0b1a2b` | dark ground, below aegean |

Gold is a *punctuation* colour. If two things on a screen are gold, one of them is
wrong.

## Type

- **Display — Fraunces.** An old-style with deliberate wonk: classical bones without
  the costume. Headings and the wordmark only.
- **Text — Archivo.** Quiet, good small, not Inter.
- **Code — IBM Plex Mono**, matching the rest of the docs.

The wordmark in the lockup SVGs is live text with a serif fallback stack. **For print
or anywhere font loading is not guaranteed, outline it first.**

## Clear space and minimums

Clear space on every side is **half the mark's width** (16 units in the 64-unit
viewBox). Minimum sizes: 16 px on screen using the 16 file, 8 mm in print.

## Do not

- Re-proportion the mark, or scale one drawing across the whole size range
- Rotate it, outline it, add a gradient, or put it on a busy photograph
- Recolour the mark in gold — gold is the accent, the mark is aegean or a knockout
- Place the sub-mark inside a lockup with the primary; they are alternates, not a pair

## The sub-mark

`can-submark.svg` is the other half of the recommendation from the study: three
arrows, one gate, one arrow out — the console, the API and the S3 endpoint all
passing through `can?`. It says the one true thing about the architecture, to the
people who will check whether it is true.

Use it on README badges, the architecture page and CLI output. It never appears
beside the primary mark in the same lockup.

## In the product

The console carries the mark inline in `static/index.html` (`markSVG()`), and the
favicon is an inline `data:` URI so it costs no extra request and no build step. If
you change the geometry here, change it there — they are duplicated on purpose, so
the console has no asset dependency, which means they can drift.

## Provenance

Drawn for this project; no third-party assets, no licensed typefaces embedded.
Fraunces and Archivo are SIL Open Font License. Consistent with the clean-MIT
commitment: everything in this directory ships under the repository's licence.
