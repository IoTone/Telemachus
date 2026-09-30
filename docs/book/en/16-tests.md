# How the project tests


- **Unit suites** (`test/*-tests.rkt`) exercise `domain/` directly against a fresh database, on both dialects. Whole pipelines run through the real scheduler by draining its queue in the test process.

- **Smoke scripts** (`test/server-smoke.sh` and friends) boot a real server and assert over HTTP with `curl`. *Test the endpoints, not just the model*: the bug that actually bit the Localization Manager lived in the HTTP layer, where a query filter compared a string against symbol keys and silently fell back to its default.

- **The end-to-end gate** (`test/e2e/validate.sh`) drives the console in a headless browser, fails on any uncaught page error and any 5xx, and runs the whole document pipeline against the scripted mock model. It is the deploy gate; the screenshot tours do not assert and will photograph a broken page.

- **Mocks are servers.** `test/mock-llm.rkt` is a deterministic OpenAI-compatible model with a tool-call mode for the agent loop and a chat mode for the pipeline.

- **Verify on PostgreSQL** before calling anything done. Everything honours `DATABASE_URL`.

- **The gates in CI**: unit, smoke, multi-tenancy, the S3 endpoint against the real `aws` client, the localization gate (English required, other locales advisory), the documentation drift gate, the end-to-end gate, and the funnel’s browser test.

**A suite that can skip is a suite that can hide.** The S3 smoke exits cleanly when the `aws` CLI is absent — so when the credential’s secret became encrypted at rest, the path that decrypts it on every signed request went unexercised, because no developer box and no CI runner had the client. The client is in the development shell and installed in CI now, and the suite runs with the secret sealed, which is how a real deployment runs it. The same suite had never run outside the Nix shell, so it had never needed to set its own collection path; its first run in CI could not load a library and reported that the server never came up.

**Some things only a browser can see.** Converting the console’s inline handlers left exactly one of them inside a quoted string rather than a template literal, so it rendered as literal text and the funnel’s submit button did nothing. Every static check passed. A browser test pressed the button and timed out. Where a static check *is* possible, write it afterwards: the two invariants that conversion depends on are now pinned in a unit test that reads the console as a file.

Some habits the tests taught: never assert “newest first” on two rows created in the same second; kill a background server by PID, never by pattern (`pkill -f` matches its own command line); a test that creates documents must point the blob root at a temporary directory or it writes into the checkout.
