# Nix Packaging (Reproducible Build, Run & Deploy)

**Purpose.** Make `build` and `run` one command on any machine, with a pinned
toolchain and no per-host setup script — and retire the current local-dev ritual
(linuxbrew minimal-racket on `PATH`, a hand-exported `PLTCOLLECTS`, "don't use apt
Racket, it's 8.2"). A contributor should get a working Telemachus from a checkout
plus `nix develop`, and a deployer should get a running server from `nix run`.

This is the **deterministic-deps tenet** applied to the toolchain itself: one
pinned input set, no mutable package scope, no "spice kitchen" of per-language
installers. It is also how we stop testing portability by hand across Ubuntu,
macOS, and NixOS.

Related: [deploy-tailnet.md](../deploy-tailnet.md) (how a running instance is
shared), [decisions.md](decisions.md).

## Why this is cheap for us

Almost everything is already Nix-shaped, by accident of earlier decisions:

- **No `raco pkg install`.** The local kits (`cli-kit`, `db-kit`, `web-kit`)
  resolve via `PLTCOLLECTS`, not a mutable user package scope. That is exactly
  what a pure build needs — and we just removed the last global `raco pkg` links,
  so there is nothing left to un-teach.
- **No build step for the frontend.** `static/index.html` is vanilla HTML/CSS/JS.
- **Minimal Python.** Tenet 6 means there is no Python environment to reproduce.
- **`nixpkgs` has Racket 9.2** — verified against the pinned registry, matching
  the version we develop on today. The full `racket` attribute bundles
  `web-server`, `db`, `rackunit`, `net`, and `json`, so the dependency closure is
  one package.

**Prior art:** Odysseus already ships a working root `flake.nix` doing exactly
this shape (nixpkgs full Racket + `PLTCOLLECTS` + `makeWrapper` per entrypoint +
`doCheck` running the suite). It is owner-authored, so it carries over cleanly
under the project's provenance rule. Telemachus is a simpler build — one server
entrypoint plus one CLI, where Odysseus wrapped eleven.

## What Nix unlocks that we cannot do today

Worth stating, because it changes more than convenience:

- **Live PostgreSQL testing on this box.** The Postgres path (slice 32) is
  currently asserted by unit-testing the placeholder rewriter and URL parser,
  because this host has no root, no Docker, and a glibc too old for the brew
  bottle. Nix installs `postgresql` per-user with none of that. The dialect-neutral
  work finally gets a live gate instead of a manual one.
- **A CI lane that matches local exactly** — same closure, same Racket, so "green
  on CI, broken on my box" stops being possible.
- **Deploy without a setup script.** `nix profile install` or a NixOS module,
  against a binary cache.

## Constraints this project imposes

Four things in the current code will not survive a naive packaging. Each is small,
but each is a hard failure, not a degradation — so they are the real content of
this plan.

### 1. Subprocess plugins spawn `racket` by bare name, with relative paths

`mcp.json` and `oop.json` both say:

```json
{ "command": "racket", "args": ["test/mock-mcp.rkt"] }
{ "command": "racket", "args": ["oop-plugins/notes-helper/main.rkt"] }
```

`domain/mcp/client.rkt` and `domain/oop/host.rkt` resolve **`command`** via
`find-executable-path`, but pass **`args` through untouched** — so the script path
is resolved against the *current working directory*, not the install root. This is
already latent breakage (running the server from another directory fails today);
Nix just makes it certain, since the CWD is arbitrary and the code lives in the
store.

Two fixes, both wanted:

- The wrapper must put the *same* `racket` on `PATH` (`--prefix PATH`), so
  `find-executable-path "racket"` cannot pick up a stray system Racket.
- Relative `args` should resolve against `impl-root`, not CWD. A few lines in the
  two spawn sites, and it fixes the non-Nix bug at the same time.

### 2. The data directory defaults into the store

`config.rkt` computes `data-dir` as `impl-root/data` unless `TELEMACHUS_DATA_DIR`
is set, and `impl-root` is where `config.rkt` lives — the read-only store. The
SQLite DB, the auto-generated TLS cert, and uploaded brand assets all land there.

The escape hatch already exists, so the wrapper sets a sane writable default
(`$XDG_STATE_HOME/telemachus`, or `/var/lib/telemachus` for the service), and the
packaged server never writes to its own prefix.

### 3. TLS shells out to `openssl`

`server/main.rkt` calls `(system* (find-executable-path "openssl") …)` to generate
the self-signed cert on first run. Unfound, it errors — but only when
`TELEMACHUS_TLS=1`, so this is a runtime input, not a build input. The wrapper adds
`openssl` to `PATH`.

### 4. argon2id is an optional, absent-by-default upgrade

Password hashing prefers argon2id when Racket's `crypto` package is present and
self-tests, else hardened PBKDF2 — `GET /health` reports which. nixpkgs' full
`racket` bundling `crypto` (and its native `libargon2`/`libcrypto` backing) is
**unverified**; step 1 of slice 45 is to check. If absent, the packaged server
simply reports `pbkdf2_sha1` as it does today, and closing that gap is its own
slice rather than a blocker.

## Design

A root `flake.nix` — the implementation lives under `refimpl/racketmaximus/`, but
the flake belongs at the repo root so a second reference implementation can add its
own package output later without a second flake.

```
outputs:
  packages.<system>.telemachus        # the server + localize CLI (default)
  devShells.<system>.default          # racket, sqlite, postgresql, node, openssl
  apps.<system>.telemachus            # nix run
  nixosModules.telemachus             # optional: systemd service (slice 48)
  checks.<system>.{unit,smoke}        # nix flake check
```

**Package.** Copy source + bytecode into `$out/share/telemachus`, then
`makeWrapper` the nixpkgs `racket` per entrypoint — not `raco exe`, which is
fragile against a read-only store. Odysseus proved this shape:

```nix
makeWrapper ${pkgs.racket}/bin/racket $out/bin/telemachus-server \
  --add-flags "$out/share/telemachus/server/main.rkt" \
  --set     PLTCOLLECTS "$out/share/telemachus/pkgs:" \
  --prefix  PATH : ${lib.makeBinPath [ pkgs.racket pkgs.openssl ]} \
  --set-default TELEMACHUS_DATA_DIR '${"$"}{XDG_STATE_HOME:-$HOME/.local/state}/telemachus'
```

Entrypoints: `telemachus-server` (`server/main.rkt`) and `telemachus-localize`
(`cli/telemachus-localize.rkt`).

**`doCheck` runs the real suite** — `raco test test/*-tests.rkt` plus the
localization gate — so a green build *is* a passing test run. Both are hermetic
(no network, no model: the LLM path falls back to a deterministic reply when
`TELEMACHUS_MODEL_URL` is unset). `test/server-smoke.sh` binds a port, so it goes in
`checks` rather than the build sandbox, with `PORT` set to something unused — which
the port work already made possible.

**devShell** carries what the build does not: `postgresql` (live dialect testing),
`nodejs_24` + Playwright's chromium (the e2e tour), `sqlite` CLI, `curl`, `jq`. It
exports `PLTCOLLECTS` on entry, which retires the single most-repeated line in
`CLAUDE.md`.

**What stays out of the package:** the e2e tour and its browser. Playwright's
chromium under Nix is its own project, and the tour is a dev/CI tool, not a
deliverable. It lives in the devShell only.

## Slice plan

Same cadence as the rest of the port — each slice ships, tests, and demos alone.

> **Built (2026‑08‑19).** The first two slices below shipped as **48** and **49** —
> 45/46/47 were taken by multi-tenancy and the workflow engine while this doc sat
> unimplemented. Root `flake.nix` + `nix/telemachus.nix`, verified end to end on
> x86_64-linux: `nix build` (unit suite + l10n gate in the sandbox), `nix flake
> check` (adds the HTTP smoke), `nix develop`, and the packaged server run from
> `/tmp` with plugins, MCP and the OOP host all loading from the store. What the
> plan got right, wrong, and missed is recorded at the end of this document.

| Slice | Title | Contents |
|---|---|---|
| **48** *(was 45)* ✅ | Flake skeleton + devShell | Root `flake.nix` pinned to nixpkgs; `devShells.default` with racket 9.2, sqlite, openssl, node, `PLTCOLLECTS` preset. Verify `crypto`/argon2id availability. Docs: `nix develop` replaces the brew/PATH ritual. |
| **49** *(was 46)* ✅ | The package | `packages.telemachus`: `raco make`, `doCheck` (unit suite + l10n gate), `makeWrapper` entrypoints, PATH/data-dir wiring. Fix the two subprocess-arg resolutions (#1) and confirm plugins/MCP/OOP load from the store. |
| **50** *(was 47)* | Live Postgres gate | Use the devShell's postgresql to run `server-smoke.sh` against a real PG in `checks`, closing the slice-32 gap. Wire as a CI lane beside the SQLite one. |
| **51** *(was 48)* | Deploy | `nixosModule` with a systemd unit (state dir, `DynamicUser`, env for model/home/port), and a runbook update so the tailnet deploy uses it instead of a hand-run process. |

## Decisions to confirm

- 🔑 **Does the flake replace linuxbrew for local dev, or sit beside it?**
  Replacing it is the point — one toolchain, and `CLAUDE.md`'s Racket/`PLTCOLLECTS`
  preamble collapses to `nix develop`. **Recommendation: replace, but keep the brew
  path documented for one release** so a mid-flight checkout doesn't break.
- **Pin to `nixos-unstable` or a stable release?** Racket 9.2 is recent; a stable
  channel may lag. **Recommendation: `nixos-unstable` with a committed
  `flake.lock`** — the lock is the reproducibility, not the channel.
- **Does CI move to Nix?** A Nix lane guarantees local/CI parity but is slower to
  cold-start than `setup-racket`. **Recommendation: add a Nix lane for the Postgres
  check (slice 47), keep `setup-racket` for the fast unit lane** — parity where it
  pays, speed where it doesn't.
- **Container image?** `dockerTools.buildLayeredImage` is nearly free once the
  package exists. **Recommendation: defer** — not needed for the tailnet deploy,
  and a distraction until someone asks for it.

*Nothing here changes the platform's contracts — only how it is built and run.*

## What the plan got right, wrong, and missed

Recorded after building it, because the differences are the useful part.

**Right.** nixpkgs does carry Racket **9.2** — the version we develop against, now
verified rather than assumed. `makeWrapper` over the interpreter (not `raco exe`)
was the correct call: plugins, MCP servers and the OOP host all load by
`dynamic-require` from the store with no changes. The absence of `raco pkg install`
really did make the build trivial. And `doCheck` running the real suite works — the
sandbox ran all 137 unit tests plus the localization gate.

**Wrong — constraint #2 was misdiagnosed.** The doc blamed `data-dir` defaulting to
`impl-root/data`. The actual failure was the default **`DATABASE_URL`**, which was
the *relative* URL `sqlite:///./data/telemachus.db`, resolved against `impl-root`.
`TELEMACHUS_DATA_DIR` never moved the database at all — it moved the TLS cert and
nothing else, so the variable was a half-truth long before Nix existed. Nobody
noticed because every demo script sets both. Fixed in `config.rkt`: the default
database URL now derives from `data-dir`, so one variable names one writable state
directory. That is a bug fix for checkouts too.

**Missed entirely — Nix only sees git-tracked files.** The first `nix build` failed
with `cannot open module file: domain/flow/run.rkt` because the whole workflow
engine was still untracked. This is a *feature* (the flake refuses to build from
files that would not reach a clone) but it is a surprising first failure, and it is
now in the runbook's failure table.

**Confirmed as predicted.** Constraint #1 (subprocess `args` resolved against CWD)
was real: fixed in `domain/mcp/client.rkt` and `domain/oop/host.rkt` by resolving a
relative `.rkt` argument against `impl-root`, which also fixes running the server
from another directory in a checkout. Constraint #4 held: the packaged server
reports `pbkdf2_sha1`, exactly as a checkout does — argon2id remains an unclaimed
upgrade, not a regression.

**Unlocked immediately.** `nix develop` ships **PostgreSQL 18.6**, so the live
dialect gate (slice 50) is now blocked on nothing but the work itself — no root, no
Docker, no glibc problem.
