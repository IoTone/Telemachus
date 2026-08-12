# Localization (i18n) & the Localization Manager

**Purpose.** Make Telemachus localizable **top to bottom**, ship **English out of
the gate**, and build a **Localization Manager** — a feature *of the platform* that
finds unlocalized strings, lets a team complete translations, and gates commits in
CI. Additional languages (**Japanese, then Dutch, then Latin American Spanish**)
are produced **by using the tool**. That is the point: the system builds the tool,
and the tool builds the locales — proof the platform can build real things.

This is both **infrastructure** (everything is localizable) and a **flagship
application** (the manager) that dogfoods RBAC, the scheduler, quotas, AI, and the
SDK.

## Two layers

1. **i18n runtime** — every user-facing string resolves through a **message
   catalog** keyed by a **message id**, never a hardcoded literal. Locale is
   resolved per request; missing translations fall back down a chain to English.
2. **Localization Manager** — the tool built on the platform: **extract** strings →
   detect **unlocalized** literals + **missing/stale** translations → a team
   **workflow** to draft (optionally AI-assisted), review, and approve per locale →
   a **CI gate** that flags violations on commit.

## Localization scope (top to bottom)

Everything user-facing goes through the catalog, not just the UI:

- UI labels, empty states, errors, tooltips, onboarding.
- API/response messages and validation errors.
- Emails, notifications, reminders.
- **Agent tool descriptions and schemas** (the model-facing text) — so a localized
  deployment can present tools in the operator's language.
- **Documentation** (see *Documentation* below).
- **Plugin-contributed catalogs** — the SDK already lists *localizations* as an
  extension type; a plugin ships its own namespaced catalog and target-locale files.

## Message model

- **Message id**: namespaced, stable, human-readable — `namespace.area.key`
  (e.g. `documents.editor.save`, `sched.error.quota_exceeded`). Plugins namespace
  under their id (`plugin:<id>.…`).
- **Source-of-truth = the `en` catalog.** English is authored inline as the
  *default value* and extracted into the base catalog; every other locale must
  cover the base keys.
- **Format: ICU MessageFormat** (plurals, gender/select, number/date, interpolation)
  — per-locale plural categories are handled by ICU (en: one/other; ja: other; es:
  one/many/other). Catalogs stored as JSON keyed by id. *(Decision 1: ICU-JSON vs
  Fluent vs gettext PO.)*
- **Staleness via source hash.** Each message carries a `source_hash` of its English
  text; a translation records the hash it was made against. When English changes,
  the hash diverges and the translation is flagged **stale** (needs re-review) —
  not silently wrong.

## Locale resolution & roadmap

Resolution order: request/user preference → team default → deployment default.
**Fallback chain** ends at English: e.g. `es-419 → es → en`, `ja → en`. English is
always complete, so a missing string degrades gracefully, never blanks.

| Order | Locale | Code | Notes |
|---|---|---|---|
| 1 (baseline) | English | `en` | Authored inline, 100% by definition — the release gate |
| 2 | Japanese | `ja` | CJK; ICU plural = other; first tool-produced locale |
| 3 | Dutch | `nl` | LTR |
| 4 | Latin American Spanish | `es-419` | region code; falls back `es-419 → es → en` |

## Detecting unlocalized strings

Two independent checks, both surfaced by the CI tool:

1. **Bare-literal scan (static).** Convention: every user-facing string is wrapped
   by the localizer call (`t 'id …` in code, a catalog ref in templates). A
   per-language **extractor** flags user-facing string literals in **surface code**
   (response builders, templates, tool descriptions, notification text) that are
   *not* wrapped. Extractors are pluggable by file type (Racket, JS, …) since
   frontends/backends are swappable — the same idea as `xgettext` /
   `eslint-plugin-i18next`. *(Decision 2: which surfaces are in-scope for v1.)*
2. **Catalog diff.** Compare each target catalog to the `en` base: **missing** keys
   (in `en`, absent in target), **stale** keys (`source_hash` diverged), **unused**
   keys (in target, gone from `en`). Coverage = approved / base-count.

## Team workflow (the management interface)

A team manages completion per locale. Per-string **status** lifecycle:

```
missing → drafted (human) | machine (AI) → needs_review → approved
                                    └────── stale (source changed) ──────┘
```

- Coverage dashboard per locale × namespace; claim/assign strings; inline editor
  with source text, description/context, and a glossary for term consistency.
- **RBAC**: new permissions `localization:read | translate | review | manage`;
  per-locale scoping via `resource_grants` (a reviewer approved only for `ja`). A
  built-in `localizer` role. Only `review`+`approve` can move a string to
  `approved`; drafters can't approve their own. All actions **audited**.
- Honors `features` activation and is **team-scoped** like every other feature.

## AI-assisted drafting (dogfoods the platform)

The manager can draft missing strings with the platform's own models — but never
auto-approves; humans review. This is where the platform builds the locales:

- `draft --locale ja` enqueues one **scheduler job per batch** of missing strings
  (workload queue, §ai-queue), so a 5,000-string draft doesn't DDOS the local model.
- Consumes **AI quota** (`ai.tokens`) attributed to the team (§quotas).
- Uses the **glossary** + message `description` as context for consistent terms.
- Output lands as `status = machine`, routed to `needs_review`.

"The tool doesn't have to do all the translation" — AI drafts, humans complete and
approve. English → Japanese/Dutch/es-419 is then an *exercise for the tool*.

## CI gate

A `telemachus-localize` CLI (fits the `cli/` pattern) usable in CI and a git
pre-commit hook:

```
telemachus-localize extract         # scan surfaces + docs → update the en base catalog
telemachus-localize check [--staged --required en --warn ja,nl,es-419 --min 0.9]
telemachus-localize report          # coverage per locale × namespace
telemachus-localize draft --locale ja [--namespace documents]   # queue AI drafts
```

**Default policy** (configurable): **fail** on bare user-facing literals; **fail**
on missing `en` base keys; **warn / threshold** on target-locale coverage (release
builds can require e.g. `ja ≥ 90%`). Wired as a pre-commit hook (`--staged`) and a
CI step. This is the "flag unlocalized strings on commits" requirement.

## Documentation

Documentation is in-scope for "localized top to bottom":

- Doc pages are **content with a source locale (`en`)** and localized variants,
  tracked with the same source-hash staleness so a changed English page flags its
  translations.
- **Documentation generation** (a related project need): generate reference docs
  (SDK contracts, API, tool catalog, permission catalog) from the source of truth,
  emit localizable Markdown, and feed doc strings into the same catalog pipeline.
  *(Flagged as its own follow-up design item — see index.)*

## Data shapes (backend-neutral)

```
locales(code pk, name, native_name, fallback_code, status, rtl bool)   -- en, ja, nl, es-419

messages(id pk, namespace, key, source_text, description,              -- the en base catalog (extracted)
         source_hash, surface, first_seen_at, deprecated bool)         -- surface: ui|api|email|tool|doc|plugin

translations(id pk, message_id fk, locale_code fk, text, status,       -- status: missing|drafted|machine|needs_review|approved|stale
             translated_by, reviewed_by, source_hash_at, updated_at,
             uniq(message_id, locale_code))

glossary(id pk, term, locale_code, translation, notes, uniq(term, locale_code))
```

Coverage is derived (`approved / base-count`). Bulk AI drafts reuse the `jobs`
table (§ai-queue, `type=tool`); usage meters into the ledger (§quotas); permissions
live in the RBAC catalog. No new infra — this feature is *composed from* the
platform, which is the proof.

## Contract (any backend implements)

```
Localizer:                       # the i18n runtime
  t(id, args?, locale?) -> string          # resolve + ICU-format, with fallback chain
  has(id, locale) -> bool
  locale_for(principal, request) -> code

LocalizationService:             # the manager
  extract(paths) -> {added, changed, removed}
  coverage(locale) -> {approved, total, pct, by_namespace}
  list(locale, status) -> [message…]
  submit(message_id, locale, text, by) -> translation
  review(translation_id, decision, by)
  draft(locale, ids|namespace) -> job_handle            # queues scheduler jobs
  ci_check(paths, policy) -> {violations, coverage, exit_code}
```

`refimpl/racketmaximus` implements the `Localizer` (catalog load + ICU format +
fallback) and the `telemachus-localize` CLI; the manager UI/API compose RBAC +
scheduler + quotas.

## Bootstrapping plan (the proof)

1. **Externalize to `en`.** Route all surfaces through `t(...)`; `extract` builds
   the base catalog; CI turns on bare-literal failure. Platform ships **100% `en`**.
2. **Build the manager** on the platform (RBAC-gated workflow + scheduler drafts +
   quota metering + coverage dashboard + CLI/CI gate).
3. **Produce `ja`** with the tool (AI draft → team review → approve), then **`nl`**,
   then **`es-419`** — each a repeat of the same workflow, proving the tool scales
   to new languages without new engineering.

## Decisions to confirm

1. **Catalog format** — ICU-MessageFormat-in-JSON (default), Mozilla **Fluent**, or
   gettext **PO**? (ICU balances power + ubiquity; Fluent is strongest for complex
   localization; PO has the deepest tooling.)
2. **v1 surfaces** — which surfaces enforce bare-literal failure first (UI + API +
   tool descriptions), with emails/docs/plugins phased in?
3. **Message ids** — named namespaced keys (default) vs source-hash keys.
4. **Release gate** — is a target-locale coverage threshold release-blocking (e.g.
   `ja ≥ 90%`), or advisory-only in v1?
5. **AI drafting default** — on (opt-out) or off (opt-in) per locale? Which model
   role drives it (`utility` vs a dedicated `translation` role)?
6. **Documentation generation** — spin its pipeline into a separate design doc now,
   or fold doc strings into this one for v1?
