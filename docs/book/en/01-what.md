# What Telemachus is


## The one-paragraph version

A team uploads its documents, talks to a model about them, runs workflows over them, shares the results with exactly the people who should see them, and does all of it on a machine the team controls. The platform is a single Racket program with an HTTP API, a browser console, an S3-compatible endpoint, a workflow engine, a scheduler, a quota ledger, and a plugin system. Every feature above the substrate — localization, the document pipeline, the knowledge graph — is built out of the substrate’s own primitives, which is both the architecture and the proof that the architecture works.

## Tenets

These are not slogans; each one has changed a design at least once.

- **Clean MIT, pure open source.** No open core, no held-back tier. Concepts may be reused from the earlier Python system, but only owner-authored Racket and owner-authored documents were carried over.

- **Racket first.** The reference implementation is Racket 9.3 CS. Non-Racket plugin authoring is explicitly not a requirement; where a data format is the contract (workflow specs, tool schemas), it is because the format earns its place, not because Racket is a barrier.

- **Deterministic dependencies.** Nix is the toolchain, and there is no second one. No Homebrew, no conda, no “python spice kitchen” on the deploy host. A PDF renderer is a dependency; so is a graph-visualization library; both were declined until someone needs them.

- **Contract first, backends swappable.** The durable product is the SDK contract, the HTTP API, the security model and the protocols. A second implementation would target those, not the Racket code. The generated reference exists so that the contract is written down by the code itself.

- **Self-hosted and privacy-first.** Bytes never leave the instance unless the operator points the model URL at something external. The blob store is content-addressed inside an org’s namespace precisely so that two tenants can never learn about each other’s files.

- **Refuse rather than flag.** A wrong result that looks finished is worse than a failed step. The localization drafter, the field extractor and the knowledge-graph extractor all refuse a model reply that does not validate. This shows up so often that it has its own chapter section.

## What is where

    docs/design/        design documents and the decision log
    docs/reference/     GENERATED: tools, workflows, permissions, API, plugins, SDK
    docs/ops/           operator runbooks
    docs/integrators-guide.md  putting your own product on the platform
    docs/book/          this book
    refimpl/racketmaximus/
      server/main.rkt   the HTTP server: handlers, boot, plugin loading
      server/routes.rkt the declared route table
      domain/           the model: authz, repo, flow, sched, quota, i18n, kg, ...
      pkgs/             db-kit, web-kit, cli-kit, sha2-kit: libraries with no platform knowledge
      plugins/          shipped plugins: doc-indexer, doc-pipeline, knowledge-graph, rs3, ...
      cli/              telemachus-localize, telemachus-docs, telemachus-worker,
                        telemachus-secrets
      static/           the console (one HTML file) and its English strings
      locales/          the catalogs: en, ja, nl, es-419
      test/             unit suites, smoke scripts, the e2e gate, mock servers
