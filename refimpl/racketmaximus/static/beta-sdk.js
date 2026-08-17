/* Telemachus Beta client SDK (slice 43) — Tier-B custom frontends load this so they
   never re-implement the anti-abuse gate. Framework-agnostic, no deps, same-origin.

   Usage in a plugin bundle:
     <script src="/beta-sdk.js"></script>
     const cfg = await Telemachus.beta.config();          // fields, theme, copy
     const res = await Telemachus.beta.submit({ name, email, use_case });
     // res => { ok:true, id, message } | { ok:false, error }

   submit() fetches a signed challenge, solves the proof-of-work, attaches the
   honeypot, and posts to /api/beta/signup — the same gate the built-in shell uses. */
(function () {
  function j(path, opts) {
    return fetch(path, opts).then(function (r) {
      return r.json().then(function (b) { return { ok: r.ok, status: r.status, json: b }; },
                           function () { return { ok: r.ok, status: r.status, json: {} }; });
    });
  }
  // FNV-1a 32-bit — byte-for-byte identical to domain/beta/antispam.rkt powhash (ASCII)
  function powhash(s) { var h = 2166136261 >>> 0; for (var i = 0; i < s.length; i++) { h = (h ^ s.charCodeAt(i)) >>> 0; h = Math.imul(h, 16777619) >>> 0; } return h >>> 0; }
  function solvePow(nonce, diff) { var mask = (diff >= 32) ? 0xFFFFFFFF : (((1 << diff) >>> 0) - 1); for (var n = 0; ; n++) { if ((powhash(nonce + ':' + n) & mask) === 0) return n; } }

  var cached = null;   // one challenge is single-use; dropped after each submit
  function config() { return j('/api/beta/config').then(function (r) { return r.json; }); }
  function challenge() { return j('/api/beta/challenge').then(function (r) { cached = r.ok ? r.json : null; return cached; }); }
  function submit(values) {
    var chP = cached ? Promise.resolve(cached) : challenge();
    return chP.then(function (ch) {
      if (!ch || !ch.challenge) return { ok: false, error: 'could not start — reload the page' };
      var pow = solvePow(String(ch.challenge).split('.')[0], ch.difficulty);
      var body = {}; for (var k in values) if (Object.prototype.hasOwnProperty.call(values, k)) body[k] = values[k];
      var hp = ch.honeypot || '_hp'; if (!(hp in body)) body[hp] = '';
      body.challenge = ch.challenge; body.pow = pow;
      return j('/api/beta/signup', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
        .then(function (r) {
          cached = null;
          return r.ok ? { ok: true, id: r.json.id, message: r.json.message }
                      : { ok: false, error: (r.json && r.json.error) || 'error' };
        });
    });
  }
  window.Telemachus = window.Telemachus || {};
  window.Telemachus.beta = { config: config, challenge: challenge, submit: submit, powhash: powhash };
})();
