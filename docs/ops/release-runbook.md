# Cutting a release

TMach's version is **one line in one file** — `refimpl/racketmaximus/VERSION` —
and three things read it: `app-version` in `config.rkt` (the console footer and
`GET /api/admin/status`), the derivation's `version` in `nix/telemachus.nix`, and
the `version` `flake.nix` hands `nix/container.nix`, which becomes the image
**tag**, the `org.opencontainers.image.version` label and the SBOM component's
version.

**It was three literals until #227, and they agreed only because nobody had
touched any of them**: `git tag` read `v0.3.0` while all three said `0.1.0` and
442 commits had landed since. That is why this page exists — the number was
never the hard part, keeping four publishers in step was.

## What the two identity fields mean

- **`version`** is what somebody *released*. It moves when a person decides it
  does, which is what makes it useful in a bug report and useless for "is this
  the code I just merged".
- **`commit`** answers that second question and is stamped by the packaging
  (`TMACH_BUILD_COMMIT`, or read out of `.git` in a checkout, else `dev`). It is
  never guessed: a wrong commit is worse than an absent one.

Both ride on `GET /api/whoami` (authenticated — an exact version is a shopping
list, which is why #11 moved it off the public `/health`) and on
`GET /api/admin/status`. `/health` is still `{ok, multitenant}` and nothing else.

**Dirty-or-clean is deliberately not reported.** It cannot be known without
reading the whole working tree, and a commit that silently means "that commit
plus whatever was edited" is the half-truth the field exists to remove — which
is also why `flake.nix` passes `self.rev or "dev"` rather than `dirtyRev`.

## The procedure

1. **Decide the number.** Semver, and the project is pre-1.0: additive feature
   work is a minor bump. **`1.0.0` is a compatibility promise** about the HTTP
   API, the SDK contract and the plugin seams — the durable product, per the
   layout notes — so it is a product decision and not a consequence of how much
   landed.

2. **Edit `refimpl/racketmaximus/VERSION`.** One semver line, no trailing
   content. `test/build-identity-tests.rkt` pins the shape, because the file is
   read by Nix at eval time and a stray second line would land in an image tag.

3. **`git add` it if it is new.** Nix only sees git-tracked files, so an
   untracked VERSION is absent from the store and the image — and `app-version`
   RAISES on a missing file rather than falling back, so the server would refuse
   to boot. That is the intended failure: `nix build` runs the unit suite, so it
   fails there rather than in production.

4. **Re-render the generated reference, in BOTH locales.** The version IS in a
   generated document — `docs/reference/README.md` line 3 reads "Version
   `<version>`", from the generator's `app-version` — so a bump that does not
   re-render fails CI's drift gate. **This page first claimed the opposite and
   CI corrected it on the first run**, which is the same shape as the
   `telemachus-docs check --locale` claim asserted three times without testing
   and then disproved by its own control:

   ```sh
   racket cli/telemachus-docs.rkt render
   racket cli/telemachus-docs.rkt render --locale ja   # `check` covers every committed locale
   racket cli/telemachus-docs.rkt check
   ```

5. **Bump the files that cannot read VERSION, and let the gate find any you
   miss.** Everything that can read a file does — `config.rkt` at instantiation,
   both Nix files at eval time, `scripts/container-smoke.sh` with `tr`. A compose
   file, a Kubernetes manifest and a prose example cannot, so they carry the
   number:

   - `compose.yaml` (`image:`)
   - `deploy/k8s/telemachus.yaml` (`image:`)
   - `docs/ops/container.md` and `docs/integrators-guide.md` (`docker run` /
     `docker image ls` examples)

   **The first two are functional**: `nix build .#container` tags the image with
   the version, so a stale `image:` points at a tag that does not exist and every
   `docker compose up` fails with "image not found". `scripts/check-config-reference.sh`
   fails on any `telemachus:<semver>` anywhere in the tree that is not the current
   version, in both directions — **it was written because CI caught exactly this
   in `container-smoke.sh`, whose default `IMAGE=` was a fourth spelling nobody
   had noticed.**

6. **Run the gates and the suite**, because the read is at module instantiation
   and a malformed file takes the server down at boot:

   ```sh
   nix develop --command bash -c 'cd refimpl/racketmaximus && raco test test/*-tests.rkt'
   DATABASE_URL="postgres://…" … raco test test/*-tests.rkt
   bash test/server-smoke.sh && bash test/doc-pipeline-smoke.sh   # one at a time: fixed ports
   ```

7. **Check all four publishers agree**, which is the one step a literal made
   impossible:

   ```sh
   cat refimpl/racketmaximus/VERSION
   nix eval --raw .#telemachus.version
   nix eval .#packages.x86_64-linux.container.imageTag
   curl -s -H "Authorization: Bearer $TOK" http://127.0.0.1:8835/api/admin/status | jq .version
   ```

8. **Merge, then tag the merge commit** — never a branch head, so the tag names
   something that passed CI:

   ```sh
   git tag -a v<version> -m "TMach v<version>"
   git push origin v<version>
   ```

   **A tag on a public repository is something people pull.** Cut it after the
   merge is green, and verify it is an ancestor of `main`
   (`git merge-base --is-ancestor v<version> origin/main`).

9. **The container image is Linux-only** (`packages.container` is behind
   `optionalAttrs isLinux`), because an image's contents are Linux store paths.
   Build it on a Linux host; `nix eval` answering "does not provide attribute" on
   a Mac is that working, not a fault.

   ```sh
   nix build .#container && docker load < result        # on Linux
   bash scripts/container-smoke.sh                       # 24 assertions
   ```

## What a release does NOT do

- **It does not migrate anything by itself.** Migrations are applied at startup
  and startup REFUSES to serve when the database was migrated by a *newer* build,
  because old code against a new schema writes rows the new code misreads. The
  remedy is to deploy that version, so rolling back across a migration is not a
  version decision — check `docs/ops/container.md` before going backwards.
- **It does not change the `TELEMACHUS_*` environment aliases.** Dropping them is
  its own release decision (#204) and has no deadline by ENVN‑1.
- **It does not re-render `docs/reference/`.** Those pages are generated from the
  route table, the tool registry and the permission catalog, none of which carry
  the version — so a release that changed no routes needs no render, and CI's
  drift gate is what says so either way.
