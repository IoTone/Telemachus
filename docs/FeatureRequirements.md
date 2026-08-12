# Telemachus — Feature Requirements

> **Skeleton — to be authored by the maintainer.** This document is filled in by
> reviewing the predecessor's feature inventory (`Features.md` in the Odysseus
> repo) and deciding what Telemachus requires. Sections below are an agenda, not
> decisions. Delete/rewrite freely.

## Inputs
- Odysseus feature inventory: `../../odysseus/Features.md` (what the predecessor does).
- Design tenets: see the project `README.md`.

## Platform requirements (to specify)
- [ ] **RBAC & teams** — roles, groups, capability/data/management gating.
- [ ] **Quotas** — per-user / per-team limits; what is metered and enforced.
- [ ] **AI concurrency control** — queuing of AI use and multi-step flows;
      rate/concurrency limits to prevent accidental self-DDOS or host/upstream
      max-out.
- [ ] **Management interface** — per-feature admin surface; activate/deactivate
      contract every feature must satisfy.
- [ ] **Security model** — auth, session, secret handling, plugin isolation,
      prompt-injection posture, multi-tenant data isolation.
- [ ] **SDK contract** — how third parties add tools, integrations, datasets,
      localizations; declaration vs execution; consent/scope enforcement.
- [ ] **Backend APIs & protocols** — the stable surface between swappable
      frontends and backends.
- [ ] **Persistence** — SQLite for prototyping, PostgreSQL as the target; schema
      abstraction so no SQLite-only assumptions leak in.
- [ ] **Queuing** of resources to enable workload distribution, enforcement of
      any custom policy  for system use
- [ ] **Localization (i18n), top to bottom** — every user-facing surface
      localizable; English at launch; then Japanese, Dutch, Latin American Spanish
      produced *by the localization tool*. (Design: `design/localization.md`.)
- [ ] **Documentation** — generated, localizable project docs (SDK contracts,
      APIs, tool & permission catalogs).


## Generic applications (to specify)
- [ ] **Chat**
- [ ] **Research**
- [ ] **Document translation**
- [ ] **Document Search**
- [ ] **Knowledge Graph**
- [ ] **Localization Manager** — extract unlocalized strings, team-managed
      translation completion, AI-assisted drafts, CI gate on commits. Flagship
      that proves the platform can build tools. (Design: `design/localization.md`.)

## Out of scope / non-goals (to specify)
- [ ] (e.g., open-core tiers — explicitly a non-goal.)
