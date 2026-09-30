# Contributing


- Read `CLAUDE.md` before starting; add to it when you learn something that cost you time. It is the project’s memory.

- Keep SQL dialect-neutral and run the suites on both dialects.

- Every model-facing feature validates and refuses; every AI call is metered; every resource is checked through `can?`.

- Refuse loudly rather than degrade quietly. An unreadable reply, an unknown theme token, a secret that will not decrypt and a schema the model did not honour are all errors that name themselves — never an empty string, a dropped field or a silent default. Most of the bugs this project has had to hunt were something failing politely.

- Adding a route, a tool, a workflow or a permission changes the generated reference: regenerate and commit it in the same change.

- New user-facing strings go into the right home of the three, then through the extractor. English is required by the gate; other locales are coverage.

- Design first for anything with a policy fork: a short document under `docs/design/` with data shapes, a contract any backend could implement, and the decisions to confirm. The decision log is `docs/design/decisions.md`.

- Commit messages say what was verified and how. A slice is done when the unit suites, the smokes, the gate and `nix build` agree, on both databases.
