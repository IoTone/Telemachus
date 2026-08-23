# Telemachus e2e — feature tour + screenshot catalog

A headless [Playwright](https://playwright.dev) walk through the **whole product**
against a real running server. It boots a throwaway server on a temp DB, drives the
actual UI (bootstrap → chat → agent → translate → notes → team → usage → admin →
localization), **asserts** each state, and captures a captioned screenshot per step.
The screenshots are assembled into a self-contained, shareable HTML catalog.

It's a plain Node script (not the `@playwright/test` runner) on purpose: it launches
fast, logs each step live, and exits non-zero on any hard-assertion failure — so it
doubles as a smoke test of the full UI. Structural checks are hard (they fail the
run); model-output waits are soft (a slow/absent model won't fail the tour, the
screenshot is still captured).

## Validate the demo (the deploy gate)

`demo-validate.mjs` is the other kind of job: **no screenshots, all assertions.**
The tours above will happily photograph a broken page; this one exits non-zero.

```bash
bash test/e2e/validate.sh                                   # fresh throwaway server
BASE_URL=http://100.70.154.54:8835 bash test/e2e/validate.sh --no-server   # a live box
```

31 checks, top to bottom: sign-in and default branding → first-run bootstrap →
notes → **documents create *and edit*** → repository upload with a byte-identical
download → search → workflows/jobs/usage render → **Admin › Branding** round-trip
(title, tagline, logo upload, reset) → sign out and back in.

Three things fail the run, not just the explicit checks:

- any **uncaught page or console error** — a silent JS exception is a broken
  console even when the assertions happen to pass;
- any **5xx** from any request the page makes;
- any assertion above.

The `--no-server` form bootstraps a `demo-validator` operator, so point it at a
throwaway or at a box that already has one.

Failure screenshots land in `catalog/validate/`.

## Run

```bash
bash test/e2e/run.sh
# → test/e2e/catalog/catalog.html
```

`run.sh` picks a modern Node from nvm (the box default is too old for Playwright),
installs deps + the chromium browser on first run, boots the server, runs the tour,
and builds the catalog. Point it at a model for live chat/translate output:

```bash
TELEMACHUS_MODEL_URL=http://127.0.0.1:11434/v1/chat/completions \
TELEMACHUS_MODEL=qwen2.5:7b bash test/e2e/run.sh
```

With no model configured the server falls back to a deterministic simulated reply,
so the tour still passes (the model steps just show the fallback).

## Layout

| file | role |
|------|------|
| `run.sh` | boot a temp-DB server on `127.0.0.1:8835`, run the tour, build the catalog, tear down |
| `boot-server.sh` | the throwaway-server launch (temp DB, binds 127.0.0.1) |
| `run-tour.mjs` | the tour: drives the UI, asserts, writes `catalog/*.png` + `manifest.json` |
| `workflow-tour.mjs` | the workflow-engine tour: runs a workflow from the **Workflows** tab, watches it advance, forces a failure → `catalog/workflow/` |
| `build-catalog.mjs` | assembles the screenshots + captions into `catalog/catalog.html` |

`catalog/`, `node_modules/`, and `report/` are git-ignored.

## The workflow tour

Drives the Workflows tab against **any** running instance rather than booting its
own server:

```bash
export PATH=~/.nvm/versions/node/v24.18.0/bin:$PATH
BASE_URL=http://127.0.0.1:8835 node test/e2e/workflow-tour.mjs
node test/e2e/build-catalog.mjs workflow "Workflow engine" "Steps, fan-out, failure" ""
```

It signs in as `alice`/`s3cret`, bootstrapping that operator if the instance is
fresh, and picks the workflow named by `WF_SLUG` (default `translate-chat`). The
last shot disables `translate_text` to force a failing run, then re-enables it.

## Adding a step

Add a block to `run-tour.mjs` (navigate with `go(page, tab, waitSel)`, run a
model-backed action with `model(page, fn, label)`, assert with `assert(...)`, then
`shot(page, id, title, caption)`), and — if it's a new section — a label in the
`SECTION` map in `build-catalog.mjs`.
