# Porting Odysseus off Python — Racket vs. Common Lisp vs. Guile

**Status:** exploratory / opinionated. This is a software-maintenance and
enjoyment exercise, not a cost-justified roadmap. The goal is a codebase that is
a pleasure to maintain and that runs cleanly on **Windows, FreeBSD, macOS, and
Linux**.

**Constraint stack (in priority order):**

1. Runs natively on **all four** of Windows / FreeBSD / macOS / Linux.
2. Enjoyable to maintain over years; opinionated about long-term ergonomics.
3. Desktop apps in Lisp/Racket; mobile (if ever) in Flutter — orthogonal to this
   doc, talks to the same HTTP API regardless of backend language.

---

## 1. What we are actually porting

Odysseus today is ~136k LOC of Python (677 files) behind a ~140k LOC vanilla-ESM
JavaScript frontend (no framework, no build step). The frontend is **not** in
scope here — migrating the backend touches none of it.

| Layer | LOC | What it does | Portable? | Joy to move |
|---|---|---|---|---|
| `src/` | 40k | agent loop, LLM core, tool schemas/policy/parsing, RAG, email/caldav parsing, research | logic | ★★★★★ |
| `routes/` | 34k | FastAPI HTTP endpoints + Pydantic models | framework | ★★★ |
| `services/` | 8.6k | STT, TTS, faces, hwfit | **ML/native** | ☆ |
| `core/` | 3.9k | SQLAlchemy DB, auth, middleware, sessions | framework | ★★★ |
| `scripts/` | 4k | git-style CLI dispatch + ~30 subcommands | none | ★★★★★ |
| `mcp_servers/` | 2.2k | MCP server implementations | protocol | ★★★★ |
| `app.py` | 1.1k | orchestrator | framework | ★★★ |

The backend is heavily async (69 files use `async def`), which is the single
biggest cross-cutting concern for any rewrite (see §5).

### The Python gravity well (stays Python, on every option)

A hard core exists only because the ML/document ecosystem is Python. Import
counts across the tree: `fastembed` ×162, `torch` ×78, `diffusers` ×60,
`fitz`/`PyMuPDF` ×58, `chromadb` ×13, `transformers` ×12, plus `cv2`,
`onnxruntime`, `faster_whisper`. **None of Racket, CL, or Guile has an
equivalent.** Do not port this — wall it behind small Python HTTP services with
stable JSON contracts. The repo already does exactly this in
`scripts/diffusion_server.py` (a standalone OpenAI-compatible image API). That
pattern is the precondition for *any* of the three options below and should be
done first, in Python, regardless of which language wins.

So the real question is: for the ~80k LOC of orchestration / protocol / schema /
glue that *can* move — which Lisp makes the four-platform target most enjoyable?

---

## 2. The deciding axis: native support on all four OSes

This is where the three diverge most, and it maps directly onto our #1
constraint.

| | Linux | macOS (incl. Apple Silicon) | FreeBSD | Windows |
|---|---|---|---|---|
| **Racket (CS)** | ✅ official installer | ✅ official installer | ⚠️ ports (`lang/racket`); Racket-CS boot-file friction historically | ✅ official installer |
| **SBCL / CL** | ✅ official binary | ✅ official binary (M-series stable) | ✅ supported BSD, port `lang/sbcl` | ✅ official binary (incl. arm64) |
| **Guile** | ✅ first-class (GNU's own) | ⚠️ Homebrew/MacPorts, second-class | ✅ port `lang/guile3` | ❌ **no native port** — MSYS2/Cygwin only; can't link MSYS2 libguile with native MinGW |

**The headline:** *Windows is Guile's hard wall, and FreeBSD is Racket's soft
spot.* SBCL is the only one of the three with genuinely first-class native
coverage of **all four** targets simultaneously.

This reorders the recommendation from what a Linux-only or
Windows+Mac+Linux-only analysis would conclude. With FreeBSD *and* Windows both
mandatory:

- **Guile** is close to disqualified for any **Windows desktop binary** we'd ship
  to users. It can serve as a Linux/BSD/Mac server, but "MSYS2 build" is not a
  Windows desktop story we want to own.
- **Racket** keeps Windows/Mac/Linux as first-class but its FreeBSD path is
  ports-only with documented Racket-CS boot-file challenges — workable, needs
  verification before committing.
- **SBCL** is the safest raw-portability bet across the exact four.

Sources: [Guile on MSYS2/MinGW (not a native port)](https://www.mail-archive.com/guile-user@gnu.org/msg12180.html),
[MSYS2 news](https://www.msys2.org/news/),
[Racket download/installers](https://racket-lang.org/download/),
[Racket-CS on FreeBSD boot-file issue #2344](https://github.com/racket/racket/issues/2344),
[FreshPorts lang/racket](https://www.freshports.org/lang/racket/),
[SBCL platform table](https://www.sbcl.org/platform-table.html).

---

## 3. Per-runtime deep dive

### 3.1 Racket (CS)

**The pitch:** the most *product-shaped* Lisp. Batteries-included, one canonical
implementation, exceptional tooling.

**Strengths for Odysseus**
- **`racket/gui`** — mature, native-widget, cross-platform GUI **in the box**.
  This is the direct answer to "why not Lisp for desktop?" A Racket desktop
  client could replace the web frontend for desktop users, sharing the agent
  core as a library rather than over HTTP.
- **`raco exe` + `raco distribute`** — standalone, dependency-free binaries.
  Compare to the four platform shell scripts the repo maintains today
  (`build-macos-app.sh`, `launch-windows.ps1`, `update_windows.bat`,
  `install-service.sh`). This is a real maintenance win.
- **Contracts** — a more expressive replacement for Pydantic's boundary
  validation, composable in ways Pydantic isn't.
- **`#lang`** — build a true DSL for tool/agent definitions instead of
  hand-maintained JSON-schema dicts. The single most enjoyable upgrade available.
- HTTP server (`web-server`), JSON, SQLite (`db`), crypto, all first-party.

**Weaknesses**
- **FreeBSD is ports-only** with historical Racket-CS boot-file friction — the
  one place it doesn't match SBCL. Must verify the current FreeBSD CS build
  before betting on it.
- Concurrency is green-threads + synchronizable events (`sync`) + `places` for
  parallelism — fine, but less elegant for this async-heavy app than Guile
  fibers (see §5).
- Single-vendor ecosystem: smaller than CL's Quicklisp for niche protocol libs.

### 3.2 Common Lisp (SBCL)

**The pitch:** the most *powerful and portable* option. True multicore threads,
the legendary image-based REPL, broadest native OS coverage.

**Strengths for Odysseus**
- **Best four-platform coverage** — official binaries on Win/Mac/Linux including
  arm64, genuine FreeBSD support. Directly serves constraint #1.
- **Real OS threads, no GIL** — true parallelism. Less critical here (heavy
  compute is offloaded to Python ML services) but a free win.
- **Image-based, live-redefinition REPL** — unmatched for long-running
  interactive development of a stateful agent server. Redefine the agent loop
  while it runs.
- **Quicklisp** — large ecosystem: Hunchentoot/Clack/Woo (HTTP), `cl-json`/`jzon`,
  `cl-dbi`/`sqlite`, `ironclad` (crypto), `cl+ssl`, IMAP/SMTP libs of varying
  quality.
- SBCL's compiler is excellent — fastest of the three.

**Weaknesses**
- **GUI is the weak point** — McCLIM is clunky; Qt via `qtools` or GTK bindings
  exist but none is the batteries-included, portable experience `racket/gui` is.
  For our desktop-app ambition this matters.
- **Distribution is DIY** — `save-lisp-and-die` (or Roswell) produces large
  images; no polished `raco exe`/`distribute` equivalent. Cross-platform packaging
  is more hand-rolled.
- Standard library is older/lower-level; more "assemble from Quicklisp" than
  "it's in the box."
- Implementation choice (SBCL vs CCL/ECL) is a decision you don't have to make
  with Racket or Guile.

### 3.3 Guile

**The pitch:** the most *elegant embedder*, with the best async story — but the
worst Windows story.

**Strengths for Odysseus**
- **Fibers** — lightweight CSP/Go-style concurrency. For an app that is async in
  69 files, this is arguably the **most enjoyable** concurrency model of the
  three: structured, composable, no callback soup, no event-loop ceremony.
- **Designed to be embedded** — if we ever wanted Python-host-embeds-Scheme (keep
  the FastAPI shell, script the agent core in Guile), Guile is purpose-built for
  exactly that. Unique among the three.
- **Dynamic FFI** — bind C libraries with no C glue. Elegant for talking to
  native protocol/crypto libs.
- Clean R6/R7RS-ish Scheme, `syntax-case` macros, GOOPS object system.
- First-class on Linux and fine on FreeBSD (`lang/guile3`).

**Weaknesses**
- **Windows is a hard wall** (constraint #1 violation): no native port, only
  MSYS2/Cygwin-style builds that can't link with native MinGW. Shipping a Windows
  desktop `.exe` is not a road we want to own.
- **macOS is second-class** (Homebrew/MacPorts), more friction than Racket/SBCL.
- **No standalone-binary story** comparable to `raco exe` — you ship the runtime
  plus compiled `.go` bytecode; painful exactly where it's already weakest
  (Windows/Mac).
- **Weak GUI** — GTK via g-golf/GObject-introspection exists, but GTK packaging
  on Windows/Mac is its own adventure on top of an already-shaky runtime story
  there.
- Smaller library ecosystem for our specific protocol needs (IMAP, CalDAV).

---

## 4. Fit against the concrete subsystems we need

| Need | Racket | SBCL / CL | Guile |
|---|---|---|---|
| HTTP server | `web-server` (built-in) | Hunchentoot / Clack / Woo | `(web server)` / Fibers-based |
| JSON | built-in | `jzon` / `cl-json` | `(json)` / guile-json |
| SQLite | `db` (built-in) | `sqlite` / `cl-dbi` | `guile-sqlite3` |
| Crypto / TLS | built-in + `crypto` | `ironclad` + `cl+ssl` | GnuTLS bindings |
| IMAP/SMTP | some pkgs; may hand-roll | mixed Quicklisp quality | thin; likely hand-roll |
| CalDAV | hand-roll on HTTP+ical | hand-roll | hand-roll |
| Desktop GUI | **`racket/gui` ✅** | McCLIM / Qt ⚠️ | GTK/g-golf ⚠️ |
| Standalone binary | **`raco exe` ✅** | save-image ⚠️ | weak ⚠️ |
| Tool/agent DSL | **`#lang` ✅** | reader macros ✅ | `syntax-case` ✅ |

Note: IMAP/SMTP/CalDAV are thin or hand-rolled on **all three** — today these
lean on Python's batteries (`email` stdlib, `caldav`, `icalendar`). This is real
migration cost regardless of choice, and an argument for keeping the email/calendar
sync subsystems Python behind HTTP (like the ML moat) at least initially.

---

## 5. The cross-cutting concern: async

FastAPI's `async def` model (69 files) does not transcribe 1:1.

- **Guile + Fibers** — the cleanest target. CSP channels map naturally onto the
  request/agent-step/tool-call pipeline. If Windows weren't a requirement, this
  would pull Guile up sharply.
- **Racket** — green threads + `sync` events + `places`. Idiomatic and capable;
  reads differently from async/await but is pleasant.
- **SBCL** — real threads + `bordeaux-threads` + `cl-async`/`woo`. Most powerful
  (true parallelism) but the most manual of the three for structured concurrency.

In all cases: budget for a genuine concurrency re-think, not a mechanical
translation.

---

## 6. Recommendation

**Primary: Racket (CS).** It best serves the *combined* goal — enjoyable
maintenance **and** a shippable cross-platform **desktop app** — because it
uniquely brings batteries-included native GUI (`racket/gui`) and standalone
packaging (`raco exe`/`distribute`) that directly retire the per-OS shell-script
pain the repo carries today. The `#lang`/contracts story makes the symbolic core
(tool schemas, agent loop, MCP) genuinely *better*, not just different.

**The one gate:** verify the **FreeBSD Racket-CS** build is healthy for our use
before committing (it's the only target where Racket trails SBCL). If FreeBSD CS
proves fragile, that single fact flips the recommendation to **SBCL**, which has
the broadest, safest native coverage of all four OSes and only really concedes
GUI polish.

**Guile** is the most elegant language of the three for this async workload, and
the natural pick *if Windows were dropped* or if we wanted Python-embeds-Scheme.
But with a Windows desktop binary as a hard requirement, its missing native
Windows story rules it out as the primary backend. Keep it in mind for a future
embedded-scripting layer, not as the platform.

**Ranking for our constraints:** Racket ≳ SBCL ≫ Guile
*(SBCL first if FreeBSD/Windows raw-portability outweighs GUI + packaging.)*

---

## 7. Sequencing (applies to whichever wins)

1. **Fence the moat.** Move *all* ML/PDF/STT/TTS (`services/`, fastembed,
   diffusers, PyMuPDF) behind Python HTTP microservices with JSON contracts. Good
   architecture regardless; precondition for everything else. Consider doing the
   same for email/CalDAV sync given thin library support in all three Lisps.
2. **Port the CLI (`scripts/`).** Self-contained; proves the toolchain and
   cross-platform packaging (`raco exe` / `save-lisp-and-die`) end to end on all
   four OSes — including the FreeBSD/Windows gates above.
3. **Port the symbolic core** — tool schemas/policy/parsing, action intents,
   agent loop, MCP — as a library with a tool-definition DSL. This is the part
   that gets *better*.
4. **Stand up the HTTP server** alongside FastAPI; migrate `routes/`
   incrementally behind a reverse proxy (strangler-fig). ML/email services
   unchanged throughout.
5. **Build the desktop client** on the shared core — the payoff for the whole
   exercise (Racket: `racket/gui`).

**Net:** ~80k of 136k Python lines are a pleasure to move; ~25k (ML/native) stay
Python forever behind HTTP; ~30k (routes/core) is a neutral rewrite done only as
the means to the desktop end. Racket is the recommended target, with SBCL as the
portability-first fallback and Guile as a future embedded-scripting option.

---

## 8. Open questions to verify before committing

- [ ] Is the **FreeBSD Racket-CS** build currently healthy (boot files, `raco
  exe` output)? This gates the primary recommendation.
- [ ] Confirm **SBCL on FreeBSD arm64** if BSD-on-ARM is a target.
- [ ] Decide whether **email/CalDAV** stay Python services or get hand-rolled in
  the chosen Lisp (recommend: stay Python initially).
- [ ] Concurrency model spike: port one async route end-to-end in the chosen
  runtime to feel the ergonomics before scaling.
