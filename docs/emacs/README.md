# Emacs: Geiser and racket-mode

Editing TMach from Emacs with a live Racket REPL. Two packages can do it —
**Geiser** (one workflow across every Scheme) and **racket-mode** (Racket only,
and better at it) — and this page covers both, plus the two things that bite on
this repo specifically: the Racket version and the collection path.

Everything below was read from the packages' own keymaps rather than from
tutorials, so it matches what is installed rather than what the manuals describe.

---

## 1. The setup that actually matters

### Geiser needs its Racket backend as a separate package

Since Geiser 0.17 each Scheme ships separately. Installing `geiser` alone gives
you the framework and nothing that can start a Racket: `geiser-racket-binary`
becomes a variable nobody reads, `geiser-active-implementations '(racket)` names
a backend that does not exist, and starting the REPL fails with some flavour of
*racket not found* — whatever your `PATH` says, and even with an absolute binary
configured.

```
M-x package-install RET geiser-racket RET
```

Add it to `package-selected-packages` as well, or `M-x package-autoremove` will
take it away again later.

### Point it at the Racket this repo uses

The toolchain is **Nix**, and the flake pins the Racket version the project
builds against (9.3 at the time of writing). A Racket from Homebrew or
`/Applications` is a *different* version, and two things then go wrong:

- **Compiled bytecode is version-stamped.** The `compiled/*.zo` files in the tree
  are built by the Nix Racket; another version refuses them with
  `version mismatch, expected "9.3", found "9.2"`.
- **`PLTCOLLECTS` is not set**, so `(require db-kit/portable)` — and `web-kit`,
  `cli-kit`, `sha2-kit` — fail with `collection not found`.

`scripts/racket-nix` in this repo is a wrapper that solves both: it runs the
flake's Racket with `PLTCOLLECTS` pointed at `refimpl/racketmaximus/pkgs`, and
leaves your working directory alone.

```sh
scripts/racket-nix --version      # Welcome to Racket v9.3 [cs].
```

Then point your editor at it, per project, with a `.dir-locals.el` at the repo
root:

```elisp
((nil . ((geiser-racket-binary . "/path/to/Telemachus/scripts/racket-nix")
         (racket-program      . "/path/to/Telemachus/scripts/racket-nix"))))
```

The first REPL start costs a few seconds while Nix evaluates the flake; after
that it is cached. A global Racket stays whatever you had — this only changes
what Emacs launches inside this tree.

---

## 2. Geiser keys

`geiser-mode` rides along in a Scheme buffer once `geiser-racket` is loaded;
`M-x geiser-mode` turns it on by hand. Start a REPL with `M-x run-geiser` (pick
`racket`) or `M-x geiser`.

| Key | What it does |
|---|---|
| `C-x C-e` | eval the sexp **before point** |
| `C-M-x`, `C-c C-c` | eval the **definition** point is inside |
| `C-c C-r` | eval the **region** |
| `C-c C-b` | eval the **buffer** |
| `C-c C-l` | load a file (prompts) |
| `C-c C-k` | compile the current buffer |
| `C-c C-z` | switch to the REPL — and back again from it |
| **`C-c C-a`** | switch to the REPL **and enter this file's module** |
| `C-c C-i` | interrupt a running evaluation |
| `C-c C-q` | exit the REPL or the debugger |
| `M-.` / `M-,` | jump to a definition / jump back |
| `C-c C-d C-d` | documentation for the symbol at point |
| `C-c C-d C-m` | documentation for the module |
| `C-c C-m C-e` | macroexpand the last sexp (`C-c C-m C-x` a definition) |
| `C-c <` / `C-c >` | callers / callees |
| `C-c C-s` | switch Scheme implementation |

The `-and-go` variants follow the result into the REPL: `C-c M-e` (definition),
`C-c M-r` (region), `C-c M-b` (buffer).

### `C-c C-a` is the one to remember

Racket modules are closed. After `C-c C-b` on a file its *internal* definitions
are still not visible at the `racket@>` prompt, because the prompt is in another
namespace — which reads like the evaluation silently failed. `C-c C-a` puts the
REPL inside the module and the prompt says so:

```
racket@> ⟶ racket@peer.rkt>
```

Unexported bindings are then callable directly, which is the fastest way to poke
at a predicate with no server running:

```racket
racket@peer.rkt> (loopback-address? "127.0.0.53")   ; → #t
racket@peer.rkt> (peer-trusted? "10.0.0.5" '())     ; → #f
```

`domain/authz/peer.rkt`, `domain/branding/branding.rkt` (`theme-problem`,
`contrast-ratio`) and `domain/ai/content.rkt` (`content->text`) are all pleasant
this way. After editing a module, `C-c C-k` or `C-c C-a` again to re-enter it;
`C-x C-e` on one definition updates just that one.

---

## 3. racket-mode keys

racket-mode brings its own major mode for `.rkt`, its own REPL, and
`racket-xp-mode` — DrRacket's check-syntax, which gives binding arrows, renaming
and documentation without a running program.

| Key | What it does |
|---|---|
| `<f5>` | **run** the file and switch to the REPL |
| `C-<f5>`, `C-c C-t` | run the file's **`test` submodule** |
| `C-x C-e` | send the last sexp |
| `C-c C-r` | send the region |
| `C-c C-z` | switch to the REPL |
| `C-c C-l` | the **logger** (`racket-logger`) |
| `C-c C-o` | the **profiler** (`racket-profile`) |
| `C-c C-d` | documentation (`racket-xp-documentation` under `racket-xp-mode`) |
| `C-c C-s` | search the docs (`racket-describe-search`) |
| `C-c C-.` | describe the identifier at point (xp-mode) |
| `C-c C-p` | cycle `()` `[]` `{}` |
| `C-c C-f` / `C-c C-u` | fold / unfold all tests |
| `C-c C-c` | **break** a running evaluation (in the REPL) |

`M-x racket-run-with-errortrace` and `racket-run-with-debugging` are the same run
with better stack traces and the step debugger.

`C-c C-t` matters here: every suite in `test/` is a plain `rackunit` module, so
running a single test file from its buffer is one keystroke rather than a shell
round-trip — though the full gate is still `raco test test/*-tests.rkt` inside
`nix develop`.

---

## 4. Which one

| | Geiser | racket-mode |
|---|---|---|
| Completion, docs and `M-.` from the **running** image | ✅ | ✅ |
| Enter a module's namespace in the REPL | ✅ `C-c C-a` | ✅ (a run enters the file) |
| check-syntax: binding arrows, rename, hover docs, no run needed | — | ✅ `racket-xp-mode` |
| `#lang`-aware indentation and fonts for *any* language | — | ✅ `racket-hash-lang` |
| Run a file's `test` submodule | — | ✅ `C-c C-t` |
| Profiler / logger / step debugger | macroexpand only | ✅ `racket-profile`, `racket-logger`, `racket-debug` |
| Docs inside Emacs | external browser | ✅ `racket-describe-search` |
| Guile, Chez, Chicken, MIT, Gambit, Gauche, Chibi… | ✅ | — |
| Release cadence | the Racket backend has been stable since 2021 | actively released |

**For this repo, racket-mode is the better daily driver** — check-syntax over
`can?`, and `C-c C-t` on a test file, are both things Geiser has no answer for.
**Geiser earns its place when the day spans several Schemes**: one set of keys
for Racket and MIT Scheme and Guile beats three.

They coexist happily. racket-mode owns `.rkt` through its own major mode and
Geiser attaches to `scheme-mode`, so they do not normally collide — but enabling
`geiser-mode` inside a `racket-mode` buffer puts two commands on `C-c C-c` and
whichever loaded last wins.

---

## 5. Troubleshooting

| Symptom | Cause |
|---|---|
| *racket not found* on startup, with a correct `geiser-racket-binary` | `geiser-racket` is not installed (§1) |
| `version mismatch, expected "9.3", found "9.2"` | the REPL's Racket is not the flake's — use `scripts/racket-nix` |
| `collection not found: db-kit` | `PLTCOLLECTS` is unset; same fix |
| A definition evaluates but the REPL cannot see it | you are not in the module — `C-c C-a` (Geiser) or `<f5>` (racket-mode) |
| Emacs cannot find anything a terminal can | GUI Emacs does not inherit a shell `PATH`; `exec-path-from-shell`, or set absolute paths as above |
| A plugin's module will not load after a Racket upgrade | stale bytecode: `rm -rf refimpl/racketmaximus/plugins/*/compiled` |
