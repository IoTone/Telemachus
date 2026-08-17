# Telemachus Migration — what can be brought over from Odysseus

**Purpose.** Decide, file by file, what may move from this repo (Odysseus) into
the clean **MIT/X** successor **Telemachus**, and under what conditions. Companion
to `Features.md` (what Odysseus *does*) and Telemachus's `docs/FeatureRequirements.md`
(what Telemachus *requires*).

**The rule (restated).** Telemachus carries over only material the maintainer
authored: the **Racket implementation** under `racket/` and **owner-authored
documentation**. No Python source, no third-party/borrowed code. Concepts are
free to reuse everywhere; *code and copyrightable text* are gated by provenance.

> **Not legal advice.** This is engineering guidance to make provenance
> decisions cheaply and safely. The one genuinely judgment-dependent call (the
> byte-faithful ported *text* in §3) is flagged for the maintainer to confirm.

---

## 1. The provenance model (read this first)

There are **two different things** bundled in the Racket tree, and they have
different provenance:

1. **Expression the maintainer wrote** — the Racket macros, functions, module
   structure, the pure agent-loop spine, the three generic packages. Copyright in
   this expression is the maintainer's; it can be relicensed MIT/X freely. ✅
2. **Content ported *faithfully* from the Python** — tool-schema descriptions and
   parameter text ("byte-faithful to `src/tool_schemas.py`"), system-prompt text,
   the untrusted-context header strings, deny-lists. The Racket *files* say so
   themselves ("Port of…", "byte-identical", "byte-faithful"). This text is a
   **derivative of the Python**, and the Python is **not the maintainer's** — it
   descends from an upstream project and, per `ACKNOWLEDGMENTS.md`, adapts:
   - **opencode** (MIT) — agent-loop / tool-execution patterns → touches
     `domain/agent/{loop,exec}.rkt`, `domain/tools/convert.rkt`.
   - **Tongyi DeepResearch** (Apache-2.0) — research pipeline → the research
     surface (the Racket research CLI is only JSON CRUD over blobs, so exposure is
     small, but confirm).
   - **llmfit** (MIT) — hardware-fit Cookbook → Python-only (`services/hwfit/`),
     **not in `racket/`**, so it does not affect the Racket migration; relevant
     only if Telemachus reuses the *approach*.

**Consequence — two clean-MIT obligations:**

- **(A) Preserve attribution.** MIT and Apache-2.0 are permissive and
  MIT-compatible, but both require keeping the original copyright + license
  notice wherever their adapted portions are reproduced. If Telemachus carries
  agent-loop/tool-exec patterns descended from opencode, ship an
  `ACKNOWLEDGMENTS`/`NOTICE` crediting opencode (MIT); likewise DeepResearch
  (Apache-2.0) if any substantive research logic is reproduced.
- **(B) Prefer rewriting the copied *text*.** The byte-faithful schema
  descriptions and ported prompt strings are the only place raw upstream *text*
  is reproduced. Rewriting them from scratch for Telemachus removes the
  derivative-text question entirely — and it aligns with a Telemachus goal anyway
  (slimmer prompts / smaller default tool sets; cf. Odysseus `ROADMAP.md`).

The **macros, the spine, the packages** — the parts that make the port "better" —
are the maintainer's expression and move cleanly. It is only the **ported strings**
that warrant a rewrite.

---

## 2. What is NOT in scope (stays behind)

- **All Python** (`src/`, `routes/`, `core/`, `services/`, `app.py`, `scripts/`,
  `mcp_servers/`, `companion/`, `integrations/`) — not the maintainer's to
  relicense. Reuse **concepts only**; see `Features.md` for the concept catalog.
- **The ML/native moat** — fastembed, torch, diffusers, PyMuPDF, chromadb,
  faster-whisper. Stays Python-behind-HTTP by design in *both* projects (porting
  rule #1). Telemachus should reach these through small JSON-contract services,
  not port them. (Note PyMuPDF is AGPL — keep it optional/isolated as Odysseus
  already does.)
- **Bundled third-party** — SearXNG, ChromaDB, ntfy images; vendored JS
  (highlight.js, SheetJS, docx, mammoth, html2pdf, qrcode); fonts. These are
  other people's, already credited in `ACKNOWLEDGMENTS.md`; Telemachus makes its
  own bundling choices.
- **`ACKNOWLEDGMENTS.md`, `licenses/`** — do not copy as-is; Telemachus needs its
  own, reflecting only what it actually bundles (plus obligation A above).
- **No third-party source lives *inside* `racket/`** — verified: no LICENSE/
  vendored files in the tree. Good; the Racket migration has no embedded foreign
  code to excise.

---

## 3. Tier 1 — Migratable Racket (owner-authored), with verdicts

Legend: **CLEAN** = original expression, move freely (rename namespace/brand).
**PORT-LOGIC** = faithful behavior port; logic is functional (low expressive-copyright
risk) but re-verify. **REWRITE-TEXT** = reproduces upstream *text*; rewrite the
strings for Telemachus (obligation B) even though the surrounding Racket is yours.

### 3.1 Generic packages — the SDK/library seed (highest-value, cleanest)
| Path | Verdict | Notes |
|---|---|---|
| `racket/pkgs/cli-kit/` | **CLEAN** | Explicitly app-agnostic ("nothing here knows about Odysseus"). JSON-CLI harness. Publishable as-is; just rename the package. |
| `racket/pkgs/db-kit/` | **CLEAN** | sqlite `DATABASE_URL` → `db` connection + coercers. sqlite-only *by design*; matching Python's `datetime.isoformat()` is functional interop, not copied text. **Postgres note:** this is where the SQLite→Postgres story lives — extend the package with a pg backend rather than the app (see §5). |
| `racket/pkgs/web-kit/` | **CLEAN** | Thin JSON wrapper over `web-server`. Intentionally minimal; may or may not be worth keeping vs. adopting a batteries framework (koyo) in Telemachus. |

### 3.2 The tool SDK — the nucleus
| Path | Verdict | Notes |
|---|---|---|
| `racket/domain/tools/dsl.rkt` | **CLEAN** | The `define-tool` macro — original invention, the "gets better" core. Move it. The *schemas it emits* are the concern, not the macro. |
| `racket/domain/tools/core-tools.rkt` | **REWRITE-TEXT** | The 20 tool declarations. Structure is yours; **descriptions/params are "byte-faithful to `src/tool_schemas.py`"** → rewrite the description/enum text fresh for Telemachus's tool catalog. |
| `racket/domain/tools/convert.rkt` (+`convert-cli.rkt`) | **PORT-LOGIC** | `function_call→tool_block`, alias map, tool-tags, MCP passthrough. Logic port of opencode-descended Python → carry opencode attribution (A); alias maps are functional. |
| `racket/domain/tools/result.rkt` | **PORT-LOGIC** | Tool-result → model-facing text; caps. Functional. |

### 3.3 The agent runtime
| Path | Verdict | Notes |
|---|---|---|
| `racket/domain/agent/loop.rkt` | **CLEAN** (spine) | The pure `run-agent` state machine with injected `#:llm`/`#:exec`. Your abstraction; the loop *pattern* descends from opencode → attribution (A). Keystone for the swappable-backend goal — move it. |
| `racket/domain/agent/llm.rkt` | **PORT-LOGIC** | OpenAI-compatible adapter (blocking + SSE, tool-call fragment reassembly, wire-key sanitize). Mostly protocol mechanics; functional. |
| `racket/domain/agent/exec.rkt` | **PORT-LOGIC** + attribution | Tool dispatcher + deny-list/confinement ("port of the deny-list … from `src/tool_execution.py`", opencode-descended). Rebuild the *security model* for Telemachus anyway (§4); carry opencode attribution. |
| `racket/domain/agent/prompt.rkt` | **REWRITE-TEXT** | System-prompt assembly (port of `agent_loop.py`). Prompt strings are copied → rewrite for Telemachus (also wanted: slimmer prompts). |
| `racket/domain/agent/prompt-security.rkt` | **REWRITE-TEXT** | Untrusted-context wrapper — the *mechanism* (user-role, fenced, escaped) is a must-keep concept; the **header/policy text** is copied → rewrite the wording. |

### 3.4 Ported tool implementations (CRUD/domain logic)
`notes.rkt`, `tasks.rkt`, `calendar-tool.rkt`, `nl-datetime.rkt`, `sessions.rkt`,
`documents.rkt`, `integrations.rkt`, `settings-tool.rkt`, `skills.rkt`,
`skill-format.rkt`, `util.rkt` — all **PORT-LOGIC**. These are faithful ports of
`do_*` handlers: table CRUD, formatting, an NL-datetime engine, the SKILL.md
parser. Low expressive-copyright risk (behavior/schema logic), but each will need
**adaptation** for Telemachus's data layer and RBAC (§4), so treat them as
"port + adapt," not drop-in. `skill-format.rkt` reproduces the Hermes-inspired
SKILL.md shape — a format, reusable; keep any prompt-ish text fresh.

### 3.5 CLIs, server, tests, tooling
| Path | Verdict | Notes |
|---|---|---|
| `racket/cli/odysseus-*.rkt` (×10) | **PORT-LOGIC** + rebrand | Faithful CLI ports. Rename `odysseus-*`→`telemachus-*`; useful as an SDK/ops surface and toolchain proof. |
| `racket/server/main.rkt` | **CONCEPT + rewrite** | HTTP surface, but auth is a **trusted `X-Odysseus-User` header** (no real auth). Telemachus needs real RBAC → treat routing as concept, replace the identity model. |
| `racket/server/proxy.rkt` | **CONTEXT-ONLY** | The strangler proxy exists to sit in front of *Odysseus's Python*. Telemachus is greenfield — no Python to strangle — so this is reference, not migration. |
| `racket/server/concurrency-demo.rkt` | **CLEAN** (reference) | Proof that Racket's evented scheduler handles concurrent I/O without FFI. Informs the AI-queuing/concurrency design (§4). |
| `racket/test/*` (`run-tests.rkt`, `mock-llm.rkt`, `seed-db.rkt`, `bench.sh`, `integration.*`) | **CLEAN** | Portable rackunit + scripted mock-LLM (test without a model). Move the harness; drop the Python-fidelity diffs (nothing to diff against). |
| `racket/config.rkt` | **REWRITE (trivial)** | Odysseus-branded paths/version/DB. Rewrite for Telemachus (new name, paths, and a db abstraction per §5). |
| `racket/install-racket.sh`, `info.rkt`, `VALIDATION.md`, `PERFORMANCE.md`, `test-plan-manual.html`, `validate-windows.bat` | **CLEAN** + rebrand | Toolchain/validation scaffolding; rebrand strings. |

---

## 4. Adaptation deltas — even migrated Racket must change

Migration is not lift-and-shift; the Telemachus tenets impose changes on *every*
migrated unit:

- **RBAC replaces binary admin.** Odysseus (and the Racket server's trusted-header
  identity) has admin/non-admin + `owner`-or-NULL sharing. Telemachus needs
  teams/groups/roles gating capabilities, data, and management actions. Every
  ported `do_*`/tool that today checks an owner string must be reworked against
  the new authz model. **New build**, informed by `Features.md` §6.3.
- **Quotas.** No metering exists to port. New subsystem: per-user/team limits on
  AI calls, tokens, storage, concurrency.
- **AI-use queuing / concurrency control.** No queue exists in Odysseus (it relies
  on per-IP rate limits + a dead-host circuit breaker). Telemachus needs a real
  **work queue + concurrency governor** in front of model calls and multi-step
  flows so agents/flows can't self-DDOS. `concurrency-demo.rkt` shows the
  runtime can do it; the governor itself is new.
- **Management interface + activate/deactivate per feature.** Odysseus has
  scattered `manage_*` tools and settings toggles; Telemachus wants a *uniform*
  management contract every feature satisfies. Design new; the `manage_settings`
  per-tool enable/disable pattern is a seed, not the shape.
- **Persistence abstraction (SQLite→Postgres).** `db-kit` is sqlite-only. Start on
  SQLite, but put a backend seam in `db-kit` (or a successor) so Postgres is a
  config swap, and keep migrated CRUD free of sqlite-only SQL.
- **Rebrand & decouple.** `config.rkt`, CLI names, the `X-Odysseus-User` header,
  data-dir layout, collection names (`odysseus_rag`/`odysseus_memories`) all carry
  the old brand — rename on the way in.
- **Rewrite ported prompt/schema text** (§3, obligation B) — do this as part of
  re-authoring the tool catalog and system prompts for Telemachus.

---

## 5. Concept-only carries (rebuild fresh in Racket/Telemachus)

Valuable Odysseus ideas whose *code* stays behind but whose *design* should be
re-implemented (all detailed in `Features.md`):

- **Two-tier MCP-then-native tool dispatch** — the third-party extension seam.
- **Role-based model routing with ordered fallbacks**; OpenAI-compatible lingua
  franca with per-provider dialect adapters.
- **Endpoint = row with a `kind`** driving cache/context-trust; static vs
  OAuth-session credentials.
- **Embedding lanes** (never mix embedding models in one collection);
  **hybrid RAG** (vector + keyword); **owner-scoped vector ids** → generalize to
  team-scoped.
- **Hardware-aware Cookbook** with fit-math shared between "recommend" and
  "serve" — if reused, credit **llmfit** (MIT) and likely wall it behind a Python
  service.
- **Deep Research** loop — credit **DeepResearch** (Apache-2.0) if the pipeline is
  reproduced substantively.
- **Scoped-token consent for external agents** (`/api/*/capabilities`, 403 until
  toggled) — a strong base for the Telemachus SDK's third-party security.
- **SKILL.md progressive-disclosure** capability packaging (the format is
  reusable; re-author any bundled prompt text).
- **Context budget + auto-compaction**, **detached streaming runs** (replay buffer
  + subscriber fan-out).

---

## 6. Documentation migration

Owner-authored docs may move (rebranded); anything crediting/borrowing does not.

| Doc | Verdict |
|---|---|
| `porting.md`, `PORTING_PLAN.md` | **Migrate (rebrand/trim).** Owner-authored language-selection + phased strategy; still the rationale for Racket-first. Trim Odysseus-strangler specifics. |
| `racket/README.md`, `racket/PERFORMANCE.md`, `racket/VALIDATION.md` | **Migrate (rebrand).** Owner-authored; describe the Racket layout/dev-loop/validation. Drop Python-fidelity sections. |
| `docs/small-host.md`, `docs/local-mac.md` | **Migrate (rebrand).** Owner-authored deployment/sizing guidance ("the model dominates," ARM/Pi profile) — reusable. |
| `Features.md` | **Reference input.** Feeds Telemachus `FeatureRequirements.md`; not a Telemachus doc itself. |
| `SECURITY.md`, `THREAT_MODEL.md` | **Rewrite, don't copy.** The *threat-modeling discipline* is worth carrying, but Telemachus's model (teams/RBAC/plugin isolation/quotas) is materially different — author fresh. |
| `README.md`, `ROADMAP.md`, `CONTRIBUTING.md` | **Author fresh** for Telemachus (README already drafted). ROADMAP items are Odysseus-specific. |
| `NIX_DEPLOYMENT.md`, `apple-ml-containers.md` | **Migrate facts (rebrand).** Owner-authored; deployment/portability findings reusable. |
| `ACKNOWLEDGMENTS.md`, `docs/security-ci.md`, `docs/pr-blocker-audit.md`, `docs/agent-migration.md`, `docs/backup-restore.md`, `docs/email-outlook.md` | **Do not copy / rebuild if needed.** Acknowledgments must be Telemachus-specific; the rest are Odysseus-tooling/feature-specific. |
| `docs/*.webm`, images, wordmark | **Do not copy.** Odysseus-branded media. |

---

## 7. Suggested sequencing (SDK-first)

1. **Stand up the clean repo skeleton** (done: `../telemachus`, MIT, README).
2. **Move the CLEAN library seed** — `cli-kit`, `db-kit` (+ Postgres seam),
   `web-kit`; rename namespaces; add the Telemachus `config` module. Cheapest,
   highest-leverage, zero provenance risk.
3. **Move the SDK nucleus** — `dsl.rkt` (the macro) + the pure `loop.rkt` spine +
   `llm.rkt` adapter + the test harness/mock-LLM. Add an `ACKNOWLEDGMENTS`/`NOTICE`
   crediting opencode (MIT). This is the swappable-backend contract taking shape.
4. **Re-author the tool catalog** — regenerate schema/prompt text fresh (don't
   port the byte-faithful strings); port the CRUD *logic* per tool as you go.
5. **Build the new-in-Telemachus subsystems** — RBAC/teams, quotas, the AI-use
   queue/concurrency governor, and the uniform per-feature management/activate
   contract. These have no Odysseus code to port; design from
   `FeatureRequirements.md`.
6. **HTTP surface + real auth** — replace the trusted-header identity with the
   RBAC model; keep the ML/native moat behind JSON services.
7. **Generic apps** — chat, research (credit DeepResearch if reproduced), and the
   **new** document-translation app (no Odysseus analogue).

---

## 8. One-line provenance checklist

- [ ] Ship a Telemachus `NOTICE`/`ACKNOWLEDGMENTS` crediting **opencode (MIT)**
      wherever agent-loop/tool-exec patterns descend from it.
- [ ] Credit **DeepResearch (Apache-2.0)** / **llmfit (MIT)** only if their
      logic is reproduced substantively (research pipeline / hardware-fit).
- [ ] **Rewrite** the byte-faithful tool-schema descriptions and ported prompt
      strings (`core-tools.rkt`, `prompt.rkt`, `prompt-security.rkt`) rather than
      copy them.
- [ ] Confirm no vendored third-party source rides along (verified none in
      `racket/` today — re-check at copy time).
- [ ] Author Telemachus's own `LICENSE` (done), `SECURITY`/`THREAT_MODEL`, and
      `ACKNOWLEDGMENTS` fresh.

*This document is Odysseus-side; it stays in this repo. Telemachus's own
requirements live in `../telemachus/docs/FeatureRequirements.md`.*
