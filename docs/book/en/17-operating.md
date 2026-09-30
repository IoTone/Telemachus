# Operating notes


- **Paths are anchored at definition.** The web server repoints the current directory at its own web root while it handles a request — inside the read-only Nix store on a packaged install. A relative path resolved lazily aims at the store. The blob root is absolute by construction, a unit test asserts it, and the server refuses to boot with a relative one. This shipped once: startup was healthy, every unit test passed, and the first document save failed with “Permission denied”.

- **Quotas stall queues.** A workflow step is a scheduler job admitted only when the team is under its AI budget. With the default two thousand tokens a day, a bulk draft or a batch extraction stops after the first jobs and looks like a hang. Raise `ai.tokens.total` first; the Automations card shows the remaining budget for this reason.

- **Uploads above one megabyte need the listener’s limit raised**, or the underlying web server drops the connection with no response at all.

- **The console caches its HTML at startup**; restart to pick up edits.

- **Multi-tenancy needs one restart** to set the flag; onboarding a company after that needs none.

- **PDF text extraction needs poppler-utils**; a missing extractor fails the indexing run deliberately, so that no PDF is silently unsearchable for months.

- **Decide about secrets at rest before you take a backup.** With no key set, a dump of the database carries every TOTP seed and S3 secret in the clear — a supported choice, and now a visible one. Adopting a key is one command and no downtime; keeping the key in the same backup as the database buys nothing. Losing it means re-enrolling every second factor and re-issuing every access key.

- **Upgrading the server upgrades the workers.** A pull worker must return the claim’s fencing token with every heartbeat and result; one that does not gets a 409. The reference worker sends it, but a third-party worker has to be updated in step.

- **A theme can be refused.** The console’s palette is validated and contrast-gated when it is written, so an operator who asks for an unreadable combination is told which pair and by how much, rather than discovering it on the sign-in screen.

The runbooks under `docs/ops/` cover the document repository, the workflow engine and multi-tenancy in operator terms.
