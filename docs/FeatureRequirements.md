# Telemachus — Feature Requirements

> **Status record, not an agenda.** This began (Aug 2026) as a skeleton to be filled
> in from the predecessor's inventory. It is now a record of what the platform
> requires and where each requirement stands. Every line links to its design doc
> and, where it exists, its implementation. Checked means **built and tested**, not
> "decided".

Legend: `[x]` built · `[~]` partial, see note · `[ ]` not started

## Inputs
- Odysseus feature inventory: `../../odysseus/Features.md` (what the predecessor does).
- Design tenets: see the project `README.md`.
- Subsystem index + how they interlock: [`design/README.md`](design/README.md).
- Decision log: [`design/decisions.md`](design/decisions.md).

## Platform requirements

- [x] **RBAC & teams** — roles, groups, capability/data/management gating.
      One contract (`can?`) governs every resource. Design:
      [`design/rbac-and-teams.md`](design/rbac-and-teams.md) · impl `domain/authz/`.
- [x] **Quotas** — per-user / per-team limits; metered and enforced at admission.
      v1 dimensions are AI-first (tokens / requests / concurrency / rate) plus
      `storage.bytes` as a gauge. Design: [`design/quotas.md`](design/quotas.md) ·
      impl `domain/quota/`.
- [x] **AI concurrency control** — queuing of AI use and multi-step flows;
      rate/concurrency limits to prevent accidental self-DDOS or host/upstream
      max-out. Design: [`design/ai-queue-and-concurrency.md`](design/ai-queue-and-concurrency.md)
      · impl `domain/sched/`.
- [x] **Queuing** of resources to enable workload distribution, enforcement of any
      custom policy for system use. Same scheduler; a *workload* queue, not a
      message bus. Remote transport deliberately deferred (SCHED‑3).
- [x] **Persistence** — SQLite for prototyping, PostgreSQL as the target; schema
      abstraction so no SQLite-only assumptions leak in. `pkgs/db-kit/portable.rkt`
      rewrites `?`→`$n`; the unit suite and both smoke suites run on either dialect.
- [~] **Management interface** — per-feature admin surface; activate/deactivate
      contract every feature must satisfy.
      *Built in practice* (`features` registry, per-feature Admin surfaces, shared
      `audit_log`). The uniform **contract** is still unwritten — see the follow-up
      note in [`design/README.md`](design/README.md).
- [~] **Security model** — auth, session, secret handling, plugin isolation,
      prompt-injection posture, multi-tenant data isolation.
      *Built in practice*: password+2FA, token scopes (RBAC‑4), sandboxed
      out-of-process plugins, org gate at step 0 of `can?`, SigV4 for S3, secrets
      handled at a stated trust boundary. **No consolidated design doc yet** — the
      posture is currently spread across the subsystem docs and `CLAUDE.md`.
- [~] **SDK contract** — how third parties add tools, integrations, datasets,
      localizations; declaration vs execution; consent/scope enforcement.
      *Partially built*: `define-tool` and `define-workflow` emit validated specs,
      plugin seams exist for tools/workflows/blob stores/onboarding, and the beta
      funnel ships a browser SDK. **Not yet published as a contract document.**
- [~] **Backend APIs & protocols** — the stable surface between swappable frontends
      and backends. The surface exists and is exercised by the smoke suites; it has
      **no generated reference**. Blocked on the documentation item below.
- [x] **Localization (i18n), top to bottom** — every user-facing surface
      localizable; English at launch; then Japanese, Dutch, Latin American Spanish
      produced *by the localization tool*.
      Runtime: catalogs + ICU + fallback chain, instance default locale and off
      switch, localized server refusals, localized funnel copy. **The console's
      own chrome is in the same catalogs** (`ui.` namespace; English source in
      `static/ui-strings.json`, folded into `en.json` by the extractor; served
      pre-auth by `GET /api/i18n/catalog`, chain-resolved server-side) — so one
      `extract`, one Manager and one CI gate cover the server and the UI alike.
      **English, Japanese, Dutch and Latin American Spanish ship, 190/190 each.**
      `nl` and `es-419` were produced *by the Localization Manager*: AI-drafted
      through the scheduler under the team's AI quota, every string
      human-reviewed (169 of 340 UI drafts corrected), exported, and passing the
      tool's own gate. That is the proof the flagship exists for.
      Design: [`design/localization.md`](design/localization.md) · impl `domain/i18n/`.
- [ ] **Documentation** — generated, localizable project docs (SDK contracts, APIs,
      tool & permission catalogs). Not started. Feeds the localization pipeline, so
      it wants to land after the Localization Manager. Design doc not yet drafted.

## Generic applications

- [x] **Chat** — console tab; real model via `TELEMACHUS_MODEL_URL`, deterministic
      fallback otherwise.
- [x] **Research** — realized as the **documents / repository** app rather than a
      separate surface: binary documents of any format, team access control with
      creator-set visibility, content search across extracted text.
      Design: [`design/document-repository.md`](design/document-repository.md).
- [x] **Document translation** — console tab with team history and a per-language
      glossary; meters AI spend through the usual quotas. Impl `domain/apps/translate.rkt`.
- [x] **Document Search** — notes + repo objects by key, filename and **extracted
      content**, each row filtered by `can?`. Impl `domain/apps/search.rkt`;
      extraction via the `index-documents` workflow.
- [x] **Document sharing with permissions** — view / edit / manage capabilities
      over the grants table; a user or a **team in the same org** as principal;
      optional expiry; only `manage` re-shares; derived documents inherit at
      creation. Design: [`design/document-sharing.md`](design/document-sharing.md).
      *Open:* the dialog's capability/principal/expiry pickers and a "Shared with
      me" filter (DSH step 3).
- [x] **Localization Manager** — extract unlocalized strings, team-managed
      translation completion, AI-assisted drafts, CI gate on commits. Flagship that
      proves the platform can build tools.
      The extractor/lint, the `telemachus-localize` CLI, the **CI gate**, and
      (migration 0024) the **team workflow**: per-string status lifecycle with
      derived `missing`/`stale`, coverage dashboard, review gating that refuses
      self-approval, the **Localize** console tab, and **AI drafting** as scheduler
      jobs metered against the team's AI quota, with a structural guard that
      refuses drafts that lose or invent placeholders. Import/export keeps
      `locales/*.json` the shipping artifact; `discard` throws away a bad machine
      run without touching human work, and a queued draft reports the team's AI
      budget so an over-budget queue does not look like a hang. **Used to produce
      `nl` and `es-419`, server and console** (see the localization line above).
- [ ] **Knowledge Graph** — not started; no design doc yet. The largest unknown
      remaining in this list.

## Out of scope / non-goals

- [x] **Open-core tiers** — explicitly a non-goal (pure OSS, no held-back tier).

### Reversed

- **Cross-legal-entity multitenancy** was listed here as out of scope (decision
  **TEN**: a deployment serves one organization, many teams OK). **That is no longer
  true.** Decision **TEN‑2** supersedes it: an **org** layer sits above teams and
  `TELEMACHUS_MULTITENANT=1` lets several companies share one instance, isolated by
  an org gate that runs *before* every permission, grant and token-scope check, with
  a superadmin plane and a per-company org-admin plane.
  Design: [`design/multi-tenancy.md`](design/multi-tenancy.md) ·
  operators: [`ops/multi-tenancy-runbook.md`](ops/multi-tenancy-runbook.md).
  The hosted offering can now serve separate legal entities either way — one
  isolated instance per tenant, or several orgs on one instance.
