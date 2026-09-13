#!/usr/bin/env python3
"""Generate one Telemachus sketch per chapter of the developer e-book.

Every vignette is the same character — the curls, the gold fillet, the chiton
pinned at one shoulder, Mentor's owl — in a pose and with a prop that belongs to
its chapter, drawn from one parts library so the sixteen read as one hand. The
parts live in the full figure's coordinate space (600 x 820, the master sketch in
telemachus-sketch.svg) and each scene places them with a transform.

    python3 docs/book/art/vignettes.py        # writes art/ch-*.svg and art/chapters.json
    node docs/book/art/render.mjs             # renders every SVG in art/ to PNG

Style: ink #132c46, one gold accent #c9a227, a periwinkle wash on cloth, a
feTurbulence wobble on every stroke, faint construction marks.
"""
import json, os

HERE = os.path.dirname(os.path.abspath(__file__))
INK, GOLD, WASH, PAPER = "#132c46", "#c9a227", "#c7d3e6", "#f2ecd8"

# ---- parts, in the master figure's coordinates ----------------------------------------
HEAD_OUTLINE = '''
<path d="M236 175 Q222 235 258 262 Q300 292 342 262 Q378 235 364 175"/>
<path d="M236 175 Q236 140 262 122 Q300 104 338 122 Q364 140 364 175" stroke-width="2.4"/>
<path d="M238 172 a10 10 0 1 1 14 -12 a11 11 0 1 1 16 -10 a12 12 0 1 1 18 -6 a12 12 0 1 1 18 0 a12 12 0 1 1 16 6 a11 11 0 1 1 14 10 a10 10 0 1 1 12 12" stroke-width="2.6"/>
<path d="M232 190 a9 9 0 1 1 -6 14 M368 190 a9 9 0 1 1 6 14 M226 212 a8 8 0 1 0 -2 12 M374 212 a8 8 0 1 0 2 12" stroke-width="2.2"/>
<path d="M270 128 a9 9 0 1 0 10 -10 M296 118 a9 9 0 1 0 10 -6 M322 124 a9 9 0 1 0 10 -2" stroke-width="2.2"/>
<path d="M238 170 Q300 150 362 170" stroke-width="2.6"/>
<path d="M238 182 Q300 164 362 182" stroke-width="2.6"/>
<path d="M362 176 q14 -6 22 4 q-10 4 -14 12" stroke-width="2.2"/>
<path d="M236 200 q-10 -4 -10 8 q0 12 10 10 M364 200 q10 -4 10 8 q0 12 -10 10" stroke-width="2.2"/>
<path d="M300 208 q-8 14 2 20 q6 2 8 -2" stroke-width="2.2"/>
'''
FILLET_WASH = '<path d="M236 168 Q300 150 364 168 L360 182 Q300 166 240 182 Z" fill="%s" fill-opacity="0.75"/>' % GOLD

# expressions: brows, eyes, mouth
FACES = {
    "smile": '''
<path d="M262 190 q14 -10 30 -2 M310 188 q16 -8 30 2" stroke-width="2.6"/>
<ellipse cx="278" cy="203" rx="8" ry="6" stroke-width="2.2"/><ellipse cx="324" cy="203" rx="8" ry="6" stroke-width="2.2"/>
<circle cx="280" cy="204" r="2.6" fill="INK"/><circle cx="326" cy="204" r="2.6" fill="INK"/>
<path d="M282 240 q18 12 38 -2" stroke-width="2.6"/><path d="M284 244 q4 6 10 6" stroke-width="1.6"/>''',
    "focus": '''
<path d="M262 186 q14 -6 30 2 M310 190 q16 -6 30 -2" stroke-width="2.6"/>
<path d="M270 205 q8 -8 16 0 M316 205 q8 -8 16 0" stroke-width="2.4"/>
<circle cx="279" cy="204" r="2.4" fill="INK"/><circle cx="325" cy="204" r="2.4" fill="INK"/>
<path d="M286 240 q14 4 28 0" stroke-width="2.6"/>''',
    "grin": '''
<path d="M262 188 q14 -12 30 -4 M310 186 q16 -10 30 0" stroke-width="2.6"/>
<path d="M270 204 q8 -9 16 0 M316 204 q8 -9 16 0" stroke-width="2.4"/>
<path d="M278 238 q22 20 44 -2 q-22 8 -44 2 z" stroke-width="2.4" fill="INK" fill-opacity="0.15"/>''',
    "surprise": '''
<path d="M262 184 q14 -12 30 -4 M310 182 q16 -10 30 0" stroke-width="2.6"/>
<circle cx="278" cy="204" r="8" stroke-width="2.2"/><circle cx="324" cy="204" r="8" stroke-width="2.2"/>
<circle cx="279" cy="205" r="3" fill="INK"/><circle cx="325" cy="205" r="3" fill="INK"/>
<ellipse cx="300" cy="242" rx="7" ry="9" stroke-width="2.4"/>''',
    "wink": '''
<path d="M262 190 q14 -10 30 -2 M310 188 q16 -8 30 2" stroke-width="2.6"/>
<ellipse cx="278" cy="203" rx="8" ry="6" stroke-width="2.2"/><circle cx="280" cy="204" r="2.6" fill="INK"/>
<path d="M314 204 q10 6 20 0" stroke-width="2.4"/>
<path d="M282 240 q18 12 38 -2" stroke-width="2.6"/>''',
}

NECK = '<path d="M282 266 q-2 20 -10 36 M318 266 q2 20 10 36" stroke-width="2.4"/>'

TUNIC_WASH = '''
<path d="M222 318 Q300 300 378 318 L392 555 Q300 585 208 555 Z" fill="WASH" fill-opacity="0.45"/>
<path d="M330 320 L378 318 L392 555 Q360 570 335 566 Z" fill="INK" fill-opacity="0.10"/>
<circle cx="372" cy="308" r="9" fill="GOLD" fill-opacity="0.85"/>'''
TUNIC = '''
<path d="M272 302 q-40 6 -56 24 M328 302 q40 4 58 20" stroke-width="2.6"/>
<path d="M222 318 q40 -10 78 -4 q42 -4 78 4" stroke-width="2.4"/>
<path d="M222 318 l-14 240 M378 318 l14 240" stroke-width="2.8"/>
<path d="M208 558 q46 22 92 8 q46 -14 92 -10" stroke-width="2.8"/>
<circle cx="372" cy="308" r="9" stroke-width="2.4"/><path d="M366 302 l12 12 M378 302 l-12 12" stroke-width="1.6"/>
<path d="M216 404 q84 18 168 0 M218 412 q82 18 164 0" stroke-width="2.2"/>
<path d="M248 420 q-6 60 -14 130 M282 424 q-4 60 -6 132 M322 424 q6 56 10 130 M352 418 q10 52 20 128" stroke-width="1.7" stroke-opacity="0.8"/>
<path d="M344 440 l24 -12 M348 466 l26 -12 M352 492 l26 -12 M356 518 l26 -12" stroke-width="1.4" stroke-opacity="0.6"/>'''
# a bust: the tunic's top only, cut at the chest
BUST_WASH = '<path d="M222 318 Q300 300 378 318 L384 420 Q300 440 216 420 Z" fill="WASH" fill-opacity="0.45"/><circle cx="372" cy="308" r="9" fill="GOLD" fill-opacity="0.85"/>'
BUST = '''
<path d="M272 302 q-40 6 -56 24 M328 302 q40 4 58 20" stroke-width="2.6"/>
<path d="M222 318 q40 -10 78 -4 q42 -4 78 4" stroke-width="2.4"/>
<path d="M222 318 l-6 104 M378 318 l6 104" stroke-width="2.8"/>
<circle cx="372" cy="308" r="9" stroke-width="2.4"/><path d="M366 302 l12 12 M378 302 l-12 12" stroke-width="1.6"/>
<path d="M256 330 q-2 30 -6 66 M340 334 q4 30 8 60" stroke-width="1.5" stroke-opacity="0.7"/>'''

LEGS = '''
<path d="M262 570 q-2 60 0 122 M330 570 q4 60 2 122" stroke-width="2.8"/>
<path d="M288 574 q-6 58 -6 116 M306 574 q4 58 4 116" stroke-width="2.4"/>
<path d="M250 692 q10 10 46 6 q4 -2 -4 -12 M286 690 q10 10 50 6 q4 -2 -6 -12" stroke-width="2.6"/>
<path d="M258 672 l28 8 M262 660 l24 8 M300 670 l30 8 M304 658 l28 8" stroke-width="1.6"/>
<path d="M266 702 q14 10 30 4 M312 700 q14 10 30 4" stroke-width="2.2"/>'''
LEGS_WALKING = '''
<path d="M262 570 q-30 60 -50 116 M330 570 q30 50 46 110" stroke-width="2.8"/>
<path d="M288 574 q-24 56 -34 110 M306 574 q26 50 40 106" stroke-width="2.4"/>
<path d="M196 690 q10 10 46 4 q4 -2 -6 -12 M362 680 q10 12 46 8 q4 -2 -6 -12" stroke-width="2.6"/>
<path d="M214 674 l26 4 M362 664 l26 6" stroke-width="1.6"/>'''

# arms: R = the viewer's left arm, L = the viewer's right arm
ARMS = {
    "R_scroll": '''
<path d="M218 324 q-30 40 -26 84 q2 14 16 12 q14 -4 26 -30 q10 -22 24 -26" stroke-width="2.8"/>
<path d="M212 330 q-16 34 -14 70" stroke-width="1.7" stroke-opacity="0.7"/>
<path d="M250 372 q8 10 20 6 q8 -2 10 -10 M256 380 q10 6 20 0" stroke-width="2"/>''',
    "R_down": '''
<path d="M218 324 q-26 46 -22 100 q0 18 12 20 q12 0 14 -16 q4 -30 22 -56" stroke-width="2.8"/>
<path d="M206 446 q-8 14 -4 24 M214 446 q-8 14 -4 26 M222 442 q-8 12 -6 24" stroke-width="1.9"/>''',
    "R_up": '''
<path d="M218 324 q-46 -10 -62 -60 q-6 -18 4 -26 q10 -6 18 6 q12 20 34 40" stroke-width="2.8"/>
<path d="M160 244 q-4 -16 4 -24 M170 240 q-4 -14 6 -22" stroke-width="1.9"/>''',
    "R_point": '''
<path d="M218 324 q-40 20 -80 6 q-14 -6 -22 -18 M158 320 q-16 -4 -24 -10 l-8 6" stroke-width="2.8"/>
<path d="M140 328 l-30 -6" stroke-width="2.6"/>''',
    "R_hold_side": '''
<path d="M218 324 q-40 30 -50 70 q-4 14 8 20 q12 4 18 -10" stroke-width="2.8"/>
<path d="M186 402 q-6 12 0 20 M196 404 q-6 12 0 20" stroke-width="1.9"/>''',
    "L_hang": '''
<path d="M386 326 q26 44 24 96 q-2 20 -14 24 q-12 2 -14 -14 q-4 -30 -22 -60" stroke-width="2.8"/>
<path d="M394 446 q8 14 4 24 M402 444 q10 12 6 26 M410 440 q10 10 8 24" stroke-width="1.9"/>''',
    "L_point": '''
<path d="M386 326 q46 16 88 0 q14 -6 24 -18 M488 316 q16 -6 26 -12 l6 8" stroke-width="2.8"/>
<path d="M512 306 l30 -8" stroke-width="2.6"/>''',
    "L_up": '''
<path d="M386 326 q46 -12 62 -60 q6 -18 -4 -26 q-10 -6 -18 6 q-12 20 -34 40" stroke-width="2.8"/>
<path d="M438 244 q4 -16 -4 -24 M428 240 q4 -14 -6 -22" stroke-width="1.9"/>''',
    "L_hold_front": '''
<path d="M386 326 q30 36 22 80 q-4 16 -18 14 q-12 -2 -14 -18 q-2 -26 -20 -50" stroke-width="2.8"/>
<path d="M370 410 q8 10 18 6 M374 420 q8 6 16 2" stroke-width="2"/>''',
    "L_wave": '''
<path d="M386 326 q40 -30 60 -80 q4 -14 -6 -20 q-10 -4 -16 8 q-10 26 -34 52" stroke-width="2.8"/>
<path d="M430 222 l6 -20 M440 226 l10 -16 M446 236 l14 -8" stroke-width="2.2"/>''',
}

SCROLL_HELD = '''
<path d="M244 352 h84 v22 h-84 z" fill="PAPER"/>
<path d="M244 352 h84 M244 374 h84" stroke-width="2.6"/>
<ellipse cx="244" cy="363" rx="7" ry="12" stroke-width="2.4"/><ellipse cx="328" cy="363" rx="7" ry="12" stroke-width="2.4"/>
<path d="M258 359 h44 M258 366 h30" stroke-width="1.4" stroke-opacity="0.7"/>'''

def owl(cx=416, cy=286, s=1.0, pose="perched"):
    body = f'''
<g transform="translate({cx} {cy}) scale({s}) translate(-416 -286)">
<ellipse cx="416" cy="286" rx="24" ry="30" stroke-width="2.6"/>
<circle cx="416" cy="250" r="18" stroke-width="2.6"/>
<path d="M402 236 l-8 -16 l16 8 M430 236 l8 -16 l-16 8" stroke-width="2.2"/>
<circle cx="409" cy="250" r="5.5" stroke-width="2"/><circle cx="423" cy="250" r="5.5" stroke-width="2"/>
<circle cx="410" cy="251" r="1.8" fill="INK"/><circle cx="424" cy="251" r="1.8" fill="INK"/>
<path d="M416 256 l-4 6 l8 0 z" stroke-width="1.6" fill="GOLD"/>
<path d="M400 276 q16 10 32 0 M400 290 q16 10 32 0 M402 304 q14 10 28 0" stroke-width="1.5" stroke-opacity="0.75"/>
<path d="M404 316 l-4 8 M412 318 l0 8 M424 318 l4 8" stroke-width="1.8"/>
{'<path d="M394 268 q-8 20 2 38" stroke-width="1.8" stroke-opacity="0.8"/>' if pose=="perched" else ''}
{'<path d="M392 270 q-40 -20 -60 8 M440 270 q40 -20 60 8" stroke-width="2.4"/><path d="M372 274 q-14 6 -22 16 M460 274 q14 6 22 16" stroke-width="1.6"/>' if pose=="flying" else ''}
{'<path d="M392 270 q-14 10 -12 28 M440 270 q14 10 12 28" stroke-width="2.2"/>' if pose=="wings-down" else ''}
</g>'''
    return body

# ---- scene helpers ---------------------------------------------------------------------
def figure(kind="full", face="smile", armR="R_down", armL="L_hang", legs=LEGS, extra_wash="", extra_ink=""):
    """the character in master coordinates; kind = full | bust"""
    wash = FILLET_WASH + (TUNIC_WASH if kind == "full" else BUST_WASH) + extra_wash
    ink = HEAD_OUTLINE + FACES[face] + NECK + (TUNIC if kind == "full" else BUST) + ARMS[armR] + ARMS[armL] + (legs if kind == "full" else "") + extra_ink
    return wash, ink

def svg(scene, w=360, h=300):
    wash, ink, marks, transform = scene
    def fill(s):
        return s.replace('fill="INK"', f'fill="{INK}"').replace('fill="GOLD"', f'fill="{GOLD}"').replace('fill="WASH"', f'fill="{WASH}"').replace('fill="PAPER"', f'fill="{PAPER}"')
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}">
  <defs>
    <filter id="wobble" x="-5%" y="-5%" width="110%" height="110%">
      <feTurbulence type="fractalNoise" baseFrequency="0.035" numOctaves="2" seed="7" result="n"/>
      <feDisplacementMap in="SourceGraphic" in2="n" scale="2.4" xChannelSelector="R" yChannelSelector="G"/>
    </filter>
  </defs>
  <g fill="none" stroke="{INK}" stroke-opacity="0.18" stroke-width="1.2" stroke-dasharray="4 5" filter="url(#wobble)">{marks}</g>
  <g transform="{transform}">
    <g filter="url(#wobble)">{fill(wash)}</g>
    <g fill="none" stroke="{INK}" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" filter="url(#wobble)">{fill(ink)}</g>
  </g>
</svg>
'''

# transforms that put the master figure into a 360x300 scene
BUST_LEFT  = "translate(-30 -34) scale(0.62)"       # head+shoulders at the left, big
FULL_LEFT  = "translate(-52 8) scale(0.36)"         # a small full figure at the left
FULL_MID   = "translate(20 8) scale(0.36)"

# ---- the chapters ------------------------------------------------------------------------
def ch_read():      # How to read this: reading an open scroll, absorbed
    w, i = figure("bust", "focus", "R_hold_side", "L_hold_front")
    prop_w = '<path d="M150 380 h150 v70 h-150 z" fill="PAPER"/>'
    prop_i = '''<path d="M150 380 h150 M150 450 h150" stroke-width="2.6"/>
<ellipse cx="150" cy="415" rx="8" ry="35" stroke-width="2.4"/><ellipse cx="300" cy="415" rx="8" ry="35" stroke-width="2.4"/>
<path d="M170 396 h110 M170 410 h94 M170 424 h116 M170 438 h70" stroke-width="1.6" stroke-opacity="0.75"/>'''
    return (w + prop_w, i + prop_i + owl(430, 270, 0.9), '<circle cx="176" cy="76" r="50"/><path d="M240 40 h100"/>', "translate(-10 -40) scale(0.62)")

def scene_with_prop(kind, face, armR, armL, prop_wash, prop_ink, marks, transform, legs=LEGS, owl_pose=None):
    w, i = figure(kind, face, armR, armL, legs=legs)
    return (w + prop_wash, i + prop_ink + (owl(*owl_pose) if owl_pose else ""), marks, transform)

def build():
    scenes = {}

    # 0 How to read this — reading an open scroll
    scenes["ch-00-read"] = ch_read()

    # 1 What Telemachus is — on the shore, waving at a sail on the horizon
    scenes["ch-01-what"] = scene_with_prop("full", "grin", "R_down", "L_wave",
        '<path d="M560 190 q60 20 64 120 l-64 8 z" fill="PAPER"/>',
        '''<path d="M560 180 l0 150 M560 190 q60 20 64 120 l-64 8" stroke-width="2.4"/><path d="M540 340 h50 l-8 12 h-36 z" stroke-width="2.2"/>
<path d="M420 700 q40 -20 80 0 q40 20 80 0 q40 -20 80 0" stroke-width="2.2"/><path d="M470 730 q30 -14 60 0 q30 14 60 0" stroke-width="1.8" stroke-opacity="0.7"/>''',
        '<path d="M10 262 h340"/>', "translate(-50 8) scale(0.36)", owl_pose=(560, 90, 0.85, "flying"))

    # 2 Getting it running — pushing a small boat into the water
    scenes["ch-02-running"] = scene_with_prop("full", "focus", "R_point", "L_point",
        '<path d="M520 470 q70 30 180 -10 l-20 60 q-70 26 -160 -6 z" fill="WASH" fill-opacity="0.5"/>',
        '''<path d="M520 470 q70 30 180 -10 M500 520 q90 40 220 -10 M520 470 l-20 50 M700 460 l20 50" stroke-width="2.6"/>
<path d="M610 400 l0 70 M610 400 l50 30 l-50 10" stroke-width="2.2"/>
<path d="M480 560 q60 -16 120 0 q60 16 120 0 q40 -14 80 0" stroke-width="2"/>''',
        '<path d="M20 240 h330"/>', "translate(-56 6) scale(0.36)", legs=LEGS_WALKING, owl_pose=(430, 300, 0.85, "perched"))

    # 3 A map of the code — pointing at a map on a stand
    scenes["ch-03-map"] = scene_with_prop("bust", "smile", "R_hold_side", "L_point",
        '<path d="M540 250 h180 v130 h-180 z" fill="PAPER"/>',
        '''<path d="M540 250 h180 v130 h-180 z" stroke-width="2.6"/>
<path d="M560 290 q30 -20 60 10 t60 0 M570 330 q40 -10 60 20 M600 262 l0 40 M660 300 l0 60" stroke-width="1.8" stroke-opacity="0.8"/>
<circle cx="600" cy="300" r="5" fill="GOLD"/><circle cx="660" cy="300" r="5" fill="GOLD"/><circle cx="640" cy="350" r="5" fill="GOLD"/>
<path d="M560 380 l0 30 M700 380 l0 30" stroke-width="2.4"/>''',
        '<path d="M330 280 h30"/>', "translate(-30 -40) scale(0.55)", owl_pose=(416, 286, 1.0, "perched"))

    # 4 The authorization model — a gate with a lock, a key in hand
    scenes["ch-04-authz"] = scene_with_prop("bust", "focus", "R_hold_side", "L_hold_front",
        '<circle cx="372" cy="420" r="16" fill="GOLD" fill-opacity="0.85"/>',
        '''<circle cx="372" cy="420" r="16" stroke-width="2.6"/><circle cx="372" cy="420" r="6" stroke-width="2"/>
<path d="M386 430 l40 26 l-8 12 l-10 -6 l-6 10 l-10 -6" stroke-width="2.6"/>
<path d="M540 250 h150 v150 h-150 z M560 250 v150 M580 250 v150 M600 250 v150 M620 250 v150 M640 250 v150 M660 250 v150" stroke-width="2.4"/>
<path d="M540 300 h150 M540 360 h150" stroke-width="2.4"/>
<path d="M600 330 a14 14 0 0 1 28 0 v18 h-28 z" stroke-width="2.4" fill="PAPER"/><circle cx="614" cy="342" r="3" fill="INK"/>''',
        '<path d="M300 260 h40"/>', "translate(-30 -40) scale(0.55)", owl_pose=(416, 286, 1.0, "perched"))

    # 5 Data and migrations — moving an amphora from one shelf to another
    scenes["ch-05-data"] = scene_with_prop("full", "focus", "R_down", "L_up",
        '<path d="M436 120 q60 -14 60 40 q0 60 -30 90 q-30 -30 -30 -90 z" fill="WASH" fill-opacity="0.5"/>',
        '''<path d="M430 118 h72 M436 120 q60 -14 60 40 q0 60 -30 90 q-30 -30 -30 -90 z M440 140 q-20 6 -14 30 M492 140 q20 6 14 30" stroke-width="2.4"/>
<path d="M450 160 q16 40 20 80" stroke-width="1.5" stroke-opacity="0.6"/>
<path d="M470 440 h200 M470 560 h200 M480 440 l0 -80 q14 -8 26 0 l0 80 M520 440 l0 -60 q14 -8 26 0 l0 60 M600 440 l0 -70 q14 -8 26 0 l0 70" stroke-width="2.4"/>
<path d="M480 560 l0 -70 q14 -8 26 0 l0 70 M560 560 l0 -60 q14 -8 26 0 l0 60" stroke-width="2.4"/>
<path d="M600 500 l30 0 l-8 -8 M630 500 l-8 8" stroke-width="2"/>''',
        '<path d="M20 262 h330"/>', "translate(-50 8) scale(0.36)", owl_pose=(700, 300, 0.8, "wings-down"))

    # 6 The document repository — shelves of scrolls, one under the arm
    scenes["ch-06-repo"] = scene_with_prop("bust", "smile", "R_hold_side", "L_hold_front",
        '<path d="M520 200 h190 v220 h-190 z" fill="PAPER" fill-opacity="0.6"/>',
        '''<path d="M520 200 h190 v220 h-190 z M520 255 h190 M520 310 h190 M520 365 h190" stroke-width="2.6"/>
<g stroke-width="2"><circle cx="545" cy="228" r="14"/><circle cx="580" cy="228" r="14"/><circle cx="615" cy="228" r="14"/><circle cx="650" cy="228" r="14"/><circle cx="685" cy="228" r="14"/>
<circle cx="545" cy="283" r="14"/><circle cx="580" cy="283" r="14"/><circle cx="650" cy="283" r="14"/>
<circle cx="545" cy="338" r="14"/><circle cx="615" cy="338" r="14"/><circle cx="650" cy="338" r="14"/><circle cx="685" cy="338" r="14"/>
<circle cx="580" cy="393" r="14"/><circle cx="615" cy="393" r="14"/></g>
<g stroke-width="1.4" stroke-opacity="0.6"><circle cx="545" cy="228" r="5"/><circle cx="580" cy="228" r="5"/><circle cx="615" cy="228" r="5"/><circle cx="650" cy="228" r="5"/><circle cx="685" cy="228" r="5"/><circle cx="545" cy="283" r="5"/><circle cx="580" cy="283" r="5"/><circle cx="650" cy="283" r="5"/></g>
<path d="M364 400 h70 v22 h-70 z" fill="PAPER"/><path d="M364 400 h70 M364 422 h70" stroke-width="2.4"/><ellipse cx="364" cy="411" rx="6" ry="11" stroke-width="2.2"/><ellipse cx="434" cy="411" rx="6" ry="11" stroke-width="2.2"/>''',
        '<path d="M300 40 h40"/>', "translate(-30 -40) scale(0.55)", owl_pose=(416, 286, 1.0, "perched"))

    # 7 Tools and the agent — a mallet raised, the owl bringing a chisel
    scenes["ch-07-tools"] = scene_with_prop("bust", "grin", "R_up", "L_hold_front",
        '<path d="M120 150 h70 v40 h-70 z" fill="WASH" fill-opacity="0.6"/>',
        '''<path d="M120 150 h70 v40 h-70 z M155 190 l10 52" stroke-width="2.6"/>
<path d="M360 420 l60 -20 M420 400 l10 -4 l4 10 l-10 4 z" stroke-width="2.4"/>
<path d="M470 240 l40 -10 l4 12 l-40 10 z" stroke-width="2.2" fill="PAPER"/>''',
        '<path d="M260 60 h60"/>', "translate(-30 -40) scale(0.55)", owl_pose=(440, 200, 0.9, "flying"))

    # 8 Workflows — walking a path of stepping stones, arrows between them
    scenes["ch-08-workflows"] = scene_with_prop("full", "smile", "R_down", "L_point",
        '<g fill="WASH" fill-opacity="0.55"><ellipse cx="420" cy="700" rx="40" ry="14"/><ellipse cx="530" cy="660" rx="40" ry="14"/><ellipse cx="640" cy="700" rx="40" ry="14"/><ellipse cx="740" cy="650" rx="40" ry="14"/></g>',
        '''<g stroke-width="2.4"><ellipse cx="420" cy="700" rx="40" ry="14"/><ellipse cx="530" cy="660" rx="40" ry="14"/><ellipse cx="640" cy="700" rx="40" ry="14"/><ellipse cx="740" cy="650" rx="40" ry="14"/></g>
<path d="M462 690 q20 -30 46 -34 M474 664 l-12 -8 M462 656 l6 12 M572 664 q30 8 46 30 M606 676 l4 14 M610 690 l-14 -2 M682 690 q20 -30 46 -34 M722 662 l-2 -14 M720 648 l-12 8" stroke-width="2"/>
<path d="M418 692 l-8 12 M528 652 l-8 12 M640 692 l6 12" stroke-width="1.6" stroke-opacity="0.6"/>''',
        '<path d="M20 262 h330"/>', "translate(-50 8) scale(0.36)", legs=LEGS_WALKING, owl_pose=(430, 300, 0.85, "perched"))

    # 9 The document pipeline — a scroll goes into a funnel, a form and a stamped page come out
    scenes["ch-09-pipeline"] = scene_with_prop("bust", "focus", "R_hold_side", "L_hold_front",
        '<path d="M520 200 l180 0 l-60 90 l0 60 l-60 0 l0 -60 z" fill="WASH" fill-opacity="0.45"/>',
        '''<path d="M520 200 l180 0 l-60 90 l0 60 l-60 0 l0 -60 z" stroke-width="2.6"/>
<path d="M364 400 h70 v22 h-70 z" fill="PAPER"/><path d="M364 400 h70 M364 422 h70" stroke-width="2.4"/><ellipse cx="364" cy="411" rx="6" ry="11" stroke-width="2.2"/><ellipse cx="434" cy="411" rx="6" ry="11" stroke-width="2.2"/>
<path d="M450 380 l50 -140 M494 250 l6 -10 M500 240 l4 12" stroke-width="2"/>
<path d="M560 380 h100 v80 h-100 z" fill="PAPER"/><path d="M560 380 h100 v80 h-100 z M575 400 h70 M575 416 h50 M575 432 h64" stroke-width="2.2"/>
<circle cx="640" cy="440" r="12" stroke-width="2.2" fill="GOLD"/><path d="M634 440 l4 4 l8 -8" stroke-width="2"/>
<path d="M610 480 q0 30 40 30 q40 0 40 -30" stroke-width="1.8" stroke-opacity="0.7"/>''',
        '<path d="M300 60 h40"/>', "translate(-30 -40) scale(0.55)", owl_pose=(416, 286, 1.0, "perched"))

    # 10 Localization — speech bubbles in three scripts
    scenes["ch-10-l10n"] = scene_with_prop("bust", "smile", "R_hold_side", "L_hang",
        '<g fill="PAPER"><path d="M120 90 h150 v70 h-110 l-20 24 l0 -24 h-20 z"/><path d="M480 80 h150 v70 h-20 l0 24 l-20 -24 h-110 z"/><path d="M520 300 h130 v60 h-90 l-14 18 l0 -18 h-26 z"/></g>',
        '''<path d="M120 90 h150 v70 h-110 l-20 24 l0 -24 h-20 z M480 80 h150 v70 h-20 l0 24 l-20 -24 h-110 z M520 300 h130 v60 h-90 l-14 18 l0 -18 h-26 z" stroke-width="2.4"/>
<text x="195" y="140" font-family="Georgia,serif" font-size="40" text-anchor="middle" fill="INK" stroke="none">Ω</text>
<text x="555" y="132" font-family="serif" font-size="40" text-anchor="middle" fill="INK" stroke="none">日本</text>
<text x="585" y="345" font-family="Georgia,serif" font-size="34" text-anchor="middle" fill="INK" stroke="none">ñ ü</text>''',
        '<path d="M290 40 h40"/>', "translate(-30 -40) scale(0.55)", owl_pose=(416, 286, 1.0, "perched"))

    # 11 The knowledge graph — drawing a constellation of connected points on a wall
    scenes["ch-11-kg"] = scene_with_prop("bust", "focus", "R_hold_side", "L_point",
        '<g fill="GOLD" fill-opacity="0.9"><circle cx="560" cy="200" r="7"/><circle cx="640" cy="240" r="7"/><circle cx="600" cy="320" r="7"/><circle cx="690" cy="330" r="7"/><circle cx="660" cy="410" r="7"/><circle cx="560" cy="400" r="7"/></g>',
        '''<path d="M560 200 l80 40 l-40 80 l90 10 l-30 80 l-100 -10 l40 -80 l-40 -120" stroke-width="2"/>
<path d="M640 240 l50 90" stroke-width="1.6" stroke-opacity="0.7"/>
<g stroke-width="2.2"><circle cx="560" cy="200" r="7"/><circle cx="640" cy="240" r="7"/><circle cx="600" cy="320" r="7"/><circle cx="690" cy="330" r="7"/><circle cx="660" cy="410" r="7"/><circle cx="560" cy="400" r="7"/></g>
<path d="M515 296 l32 6 l-6 -8 M547 302 l-8 4" stroke-width="2"/>''',
        '<path d="M300 40 h40"/>', "translate(-30 -40) scale(0.55)", owl_pose=(416, 286, 1.0, "perched"))

    # 12 The route table and the generated reference — a signpost, the owl copying a scroll
    scenes["ch-12-routes"] = scene_with_prop("full", "smile", "R_down", "L_point",
        '<g fill="PAPER"><path d="M560 260 h140 l20 16 l-20 16 h-140 z"/><path d="M560 320 h120 l20 16 l-20 16 h-120 z"/><path d="M560 380 h100 l20 16 l-20 16 h-100 z"/></g>',
        '''<path d="M600 200 l0 480" stroke-width="3"/>
<path d="M560 260 h140 l20 16 l-20 16 h-140 z M560 320 h120 l20 16 l-20 16 h-120 z M560 380 h100 l20 16 l-20 16 h-100 z" stroke-width="2.4"/>
<path d="M576 276 h90 M576 336 h70 M576 396 h50" stroke-width="1.6" stroke-opacity="0.7"/>
<path d="M660 560 h90 v50 h-90 z" fill="PAPER"/><path d="M660 560 h90 v50 h-90 z M672 576 h60 M672 592 h40" stroke-width="2"/>''',
        '<path d="M20 262 h330"/>', "translate(-50 8) scale(0.36)", owl_pose=(640, 640, 0.8, "wings-down"))

    # 13 How the project tests — stringing the bow (the test of the suitors)
    scenes["ch-13-tests"] = scene_with_prop("full", "focus", "R_up", "L_hold_front",
        "",
        '''<path d="M150 140 q-90 200 0 400" stroke-width="4"/>
<path d="M150 140 q-60 200 0 400" stroke-width="1.5" stroke-opacity="0.5"/>
<path d="M150 140 l0 400" stroke-width="1.8" stroke-opacity="0.85"/>
<path d="M140 130 q10 -14 22 0 M140 552 q10 14 22 0" stroke-width="2.2"/>
<path d="M340 420 l180 0 M520 420 l-14 -8 M520 420 l-14 8" stroke-width="2.2"/>''',
        '<path d="M20 262 h330"/>', "translate(-40 8) scale(0.36)", owl_pose=(560, 300, 0.85, "perched"))

    # 14 Operating notes — at the tiller, steering
    scenes["ch-14-operating"] = scene_with_prop("bust", "focus", "R_hold_side", "L_hold_front",
        '<circle cx="470" cy="420" r="70" fill="WASH" fill-opacity="0.35"/>',
        '''<circle cx="470" cy="420" r="70" stroke-width="3"/><circle cx="470" cy="420" r="14" stroke-width="2.4" fill="GOLD"/>
<path d="M470 350 v140 M400 420 h140 M420 370 l100 100 M520 370 l-100 100" stroke-width="2.4"/>
<g stroke-width="2.2"><circle cx="470" cy="340" r="6"/><circle cx="470" cy="500" r="6"/><circle cx="390" cy="420" r="6"/><circle cx="550" cy="420" r="6"/><circle cx="413" cy="363" r="6"/><circle cx="527" cy="363" r="6"/><circle cx="413" cy="477" r="6"/><circle cx="527" cy="477" r="6"/></g>
<path d="M560 520 q30 -14 60 0 q30 14 60 0" stroke-width="2" stroke-opacity="0.8"/>''',
        '<path d="M300 40 h40"/>', "translate(-30 -40) scale(0.55)", owl_pose=(416, 286, 1.0, "perched"))

    # 15 Contributing — handing the owl a new scroll for the shelf
    scenes["ch-15-contributing"] = scene_with_prop("bust", "grin", "R_hold_side", "L_up",
        '<path d="M430 180 h60 v18 h-60 z" fill="PAPER"/>',
        '''<path d="M430 180 h60 M430 198 h60" stroke-width="2.4"/><ellipse cx="430" cy="189" rx="5" ry="9" stroke-width="2.2"/><ellipse cx="490" cy="189" rx="5" ry="9" stroke-width="2.2"/>
<path d="M560 300 h150 v120 h-150 z M560 360 h150" stroke-width="2.4"/>
<g stroke-width="2"><circle cx="585" cy="330" r="12"/><circle cx="620" cy="330" r="12"/><circle cx="655" cy="330" r="12"/><circle cx="585" cy="390" r="12"/><circle cx="620" cy="390" r="12"/></g>
<path d="M690 390 a12 12 0 1 1 0.1 0" stroke-width="2" stroke-dasharray="3 3"/>''',
        '<path d="M300 40 h40"/>', "translate(-30 -40) scale(0.55)", owl_pose=(540, 150, 0.9, "flying"))

    return scenes

CHAPTERS = [  # (file stem, chapter title as written in the .tex)
    ("ch-00-read", "How to read this"),
    ("ch-01-what", "What Telemachus is"),
    ("ch-02-running", "Getting it running"),
    ("ch-03-map", "A map of the code"),
    ("ch-04-authz", "The authorization model"),
    ("ch-05-data", "Data and migrations"),
    ("ch-06-repo", "The document repository"),
    ("ch-07-tools", "Tools and the agent"),
    ("ch-08-workflows", "Workflows"),
    ("ch-09-pipeline", "The document pipeline"),
    ("ch-10-l10n", "Localization"),
    ("ch-11-kg", "The knowledge graph"),
    ("ch-12-routes", "The route table and the generated reference"),
    ("ch-13-tests", "How the project tests"),
    ("ch-14-operating", "Operating notes"),
    ("ch-15-contributing", "Contributing"),
]

if __name__ == "__main__":
    scenes = build()
    for stem, title in CHAPTERS:
        with open(os.path.join(HERE, stem + ".svg"), "w") as f:
            f.write(svg(scenes[stem]))
    with open(os.path.join(HERE, "chapters.json"), "w") as f:
        json.dump([{"file": s, "title": t} for s, t in CHAPTERS], f, indent=1)
    # the HTML edition: one rule per chapter heading, keyed by pandoc's heading id
    import re, urllib.parse
    def slug(t):
        t = re.sub(r"[^a-z0-9 _.-]", "", t.lower()).strip()
        return re.sub(r"\s+", "-", t)
    rules = []
    for stem, title in CHAPTERS:
        raw = open(os.path.join(HERE, stem + ".svg")).read()
        raw = re.sub(r"<!--.*?-->", "", raw, flags=re.S); raw = re.sub(r"\s+", " ", raw).strip()
        uri = "data:image/svg+xml;charset=utf-8," + urllib.parse.quote(raw, safe="/:=,;()' ")
        rules.append('h1#%s::before { background-image: url("%s"); }' % (slug(title), uri))
    with open(os.path.join(HERE, "chapter-art.css"), "w") as f:
        f.write("/* GENERATED by vignettes.py — one Telemachus per chapter, keyed by pandoc heading id */\n" + "\n".join(rules) + "\n")
    print(f"wrote {len(CHAPTERS)} vignettes")
