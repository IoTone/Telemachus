<!-- Thanks for contributing to Telemachus! Keep PRs focused; see CONTRIBUTING.md. -->

## Summary

<!-- What does this change and why? Link any issue: Closes #123 -->

## Type of change

- [ ] Feature
- [ ] Fix
- [ ] Refactor / internal
- [ ] Docs / CI / tooling

## Checklist

Run from `refimpl/racketmaximus` with `export PLTCOLLECTS="$(pwd)/pkgs:"`.

- [ ] `raco make server/main.rkt` compiles clean
- [ ] `raco test test/*-tests.rkt` — unit tests pass (see CONTRIBUTING for the list)
- [ ] `bash test/server-smoke.sh` passes
- [ ] Localization gate passes if surfaces changed:
      `racket cli/telemachus-localize.rkt check surface/messages.rkt surface/greetings.rkt --required en`
- [ ] E2E tour passes if the UI changed: `bash test/e2e/run.sh`
- [ ] New API endpoints enforce RBAC (`require-perm` / `can?`); new tools register a permission
- [ ] New user-facing strings are localized (no bare literals in `surface/`)
- [ ] New behavior has a `test/*-tests.rkt`
- [ ] Only MIT-licensable code

## Notes for reviewers

<!-- Anything worth calling out: trade-offs, follow-ups, screenshots, migration steps. -->
