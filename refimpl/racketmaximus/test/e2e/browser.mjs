// test/e2e/browser.mjs — the ONE place a browser is launched.
//
// Playwright ships its own Chromium and normally uses it: `validate.sh` runs
// `npx playwright install chromium chromium-headless-shell`, which unpacks a
// build under ~/.cache/ms-playwright. That build links against the host's
// shared libraries, so on a box without them — NixOS has no /usr/lib at all —
// `chromium.launch()` dies with `error while loading shared libraries:
// libnss3.so`. It reads as a hang or an opaque launch failure rather than as a
// missing library, which is why the six scripts here now share this seam.
//
// Nothing changes on a box where Playwright's own build works (this one), so
// this is not a second browser to keep patched. `TMACH_CHROMIUM` points at any
// Chromium for a box where it does not:
//
//   nix shell nixpkgs#chromium -c env TMACH_CHROMIUM=$(command -v chromium) \
//     bash test/e2e/validate.sh
//
// What it buys is the gate: §3b2/§3b3 of demo-validate.mjs were written and
// never run on a box with a browser, and the first run found a `const H` that
// shadowed the console's own handler registry — the notes graph drew nothing and
// the whole Notes tab blanked. A gate nobody can run is not a gate.
import { chromium } from '@playwright/test';

// The two flags every script here already passed: no sandbox (the browser runs
// as an unprivileged user in CI and in a container) and no /dev/shm, which is
// 64 MB in Docker and crashes a renderer on anything real.
export const CHROMIUM_ARGS = ['--no-sandbox', '--disable-dev-shm-usage'];

export function launchChromium(opts = {}) {
  const exe = process.env.TMACH_CHROMIUM;
  return chromium.launch(Object.assign(
    exe ? { executablePath: exe } : {},
    opts,
    { args: opts.args || CHROMIUM_ARGS }));
}
