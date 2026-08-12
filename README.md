# Telemachus

A **team-oriented, self-hosted, privacy-first platform for hosting AI tools and
applications.** Local-first, driven primarily by `llama-cpp` / `llama-server`,
with minimal Python exposure. Open from day one.

The generic application set is **chat**, **research**, and **document
translation**. Beyond that, Telemachus is an **SDK and platform**: deployers
extend the system with plugins — new **tools & integrations**, **datasets**, and
**localizations** — through a stable, documented contract.

The first prototype is written in **Racket**. Frontend and backend are intended
to be **swappable** — someone can supply a different frontend or a different
backend — so the durable surface is the **SDK contract, the backend APIs, the
security model, and the protocols**, not any one implementation. A second
engineer is expected to provide an alternative reference implementation on the
same contracts later.

## Lineage & licensing

Telemachus succeeds an earlier self-hosted AI workspace ("Odysseus") and reuses
its **concepts** — data-model ideas, the tool/agent contract shape, provider
abstraction, hardware-aware local-model serving — but is a **clean MIT/X-licensed
project**. Only code and documentation the author wrote themselves (the Racket
implementation and owner-authored docs) are carried over; no third-party or
borrowed source is imported. Provenance is vetted per file.

This is **pure OSS**. There is no open-core model and no plan for an "open core
rug pull" — no held-back proprietary tier, no feature paywall. Every capability
ships under the same MIT/X terms.

## Design tenets

1. **Team-first, RBAC at the core.** A real notion of teams/groups and
   **role-based access control** — not a binary admin flag. Roles gate
   capabilities, data, and management actions.
2. **Quotas & fair use.** Per-user / per-team **quotas** are part of the team
   design, not an afterthought.
3. **Controlled AI concurrency — no accidental self-DDOS.** AI use and
   multi-step application flows are **queued and rate/concurrency-limited** so a
   runaway agent or a burst of flows cannot unintentionally DDOS or max out the
   host or upstream model servers.
4. **Every feature is manageable.** Each feature ships with a **strong management
   interface** and a clear way to **activate / deactivate** it.
5. **Local-first & privacy-first.** Runs offline against local models; user data
   stays on the deployer's infrastructure.
6. **Minimal Python.** Most things are driven from `llama-cpp` / `llama-server`.
   The ML/document/native moat (embeddings, diffusion, PDF, STT/TTS) — where it
   is needed at all — is walled behind small services with stable JSON contracts,
   not woven through the core.
7. **Swappable frontend/backend, contract-keyed.** The SDK contract, backend
   APIs, security model, and protocols are the product; implementations are
   replaceable.
8. **Documentation is central.** As an open project, docs are a first-class
   deliverable alongside code.

## Data layer

Start on **SQLite** for prototyping; design the persistence layer to **move to
PostgreSQL** as the scale/team story requires. The data model should not assume
SQLite-only semantics.

## Repository layout

Design docs live at the repo **root**; each backend / reference implementation
lives under `refimpl/<name>/`.

- `README.md`, `ACKNOWLEDGMENTS.md`, `docs/` — project design docs & attribution.
- `docs/FeatureRequirements.md` — the requirements (authored from the predecessor review).
- `refimpl/racketmaximus/` — the first reference implementation (Racket); has its own README.

Additional reference implementations (a different backend, or another engineer's
design) slot in as sibling `refimpl/<name>/` directories against the same
contracts — nothing about the platform is tied to any one of them.

## Status

Prototyping. Requirements are being derived from a feature review of the
predecessor system; the Racket reference implementation is underway under
`refimpl/racketmaximus/` (library seed + agent-engine nucleus landed).

- `docs/FeatureRequirements.md` — the requirements for Telemachus (authored from
  a review of the predecessor's feature inventory).

## License

[MIT](LICENSE) © 2026 IoTone, Inc.
