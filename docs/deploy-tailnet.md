# Deploying the demo over Tailscale

How the `racketmaximus` reference implementation is shared **privately over a
Tailscale tailnet**, plus the (optional, gated) paths to trusted HTTPS and a
public URL.

## Current setup — private, tailnet-only

The server binds to this host's **tailnet IP**, so any device signed into the same
tailnet can reach it. Tailscale is WireGuard, so traffic is encrypted end-to-end —
plain HTTP is already private on the wire; the only thing missing vs. HTTPS is the
browser padlock.

```bash
cd refimpl/racketmaximus
export PLTCOLLECTS="$(pwd)/pkgs:"
TELEMACHUS_BIND=100.70.154.54 \                             # this host: `tailscale ip -4`
TELEMACHUS_MODEL_URL=http://127.0.0.1:11434/v1/chat/completions \
TELEMACHUS_MODEL=qwen2.5:7b \                               # ollama (OpenAI-compatible)
racket server/main.rkt
```

- **URL:** `http://<tailnet-ip>:8080` — this host is `red5buntu` / `100.70.154.54`
- **Model:** `qwen2.5:7b` via ollama — non-reasoning, streams cleanly (avoid the
  reasoning models like `qwen3.5:*`, whose answer lands in a `reasoning` field and
  reads as a blank reply here).
- **Bind:** `TELEMACHUS_BIND` selects the interface (default `127.0.0.1`).

### Demo accounts (runtime state, not in git)

| Login | Password | Role | Shows |
|---|---|---|---|
| `demo` | `Telemachus2026` | member | normal user — chat, notes, usage; **no** admin |
| `alice` | `s3cret` | operator | admin — members, quotas, admin status |

Change a password in the UI (**Team → Change your password**) or `POST /api/password`.
`alice` is on the first-run default — rotate it before any wider exposure.

### 60-second demo script
1. Log in as **`demo`** → **Chat** (real model, streams token-by-token); **Notes**
   (a private + a team note are seeded — try **Share**).
2. Flip **EN / 日本語** — the chrome and server errors both localize.
3. Log in as **`alice`** (operator) → **Team** (add a member), **Usage** (raise a
   quota live), **Admin**.
4. As a member, trigger an admin action → localized **403** (RBAC enforced server-side).

## Trusted HTTPS on the tailnet (optional) — `tailscale serve`

Real Let's Encrypt cert on your MagicDNS name (green padlock), still tailnet-only.

1. **Admin console → DNS** (login.tailscale.com/admin/dns): enable **MagicDNS** and
   **HTTPS Certificates**. *(Check: `tailscale status --json | grep CertDomains` —
   currently empty, i.e. not yet enabled.)*
2. On this host, once: `sudo tailscale set --operator=$USER`  (so serve runs without root)
3. Run the app on `localhost` (`TELEMACHUS_BIND=127.0.0.1`), then:
   ```bash
   tailscale serve --bg 8080          # → https://<host>.<tailnet>.ts.net
   ```

> The app's own `TELEMACHUS_TLS=1` self-signed cert is **not** recommended for the
> tailnet — it just adds a browser warning. Let Tailscale terminate TLS instead.

## Public URL (later, deliberate) — `tailscale funnel`

Exposes the app to the **public internet**. Only with a hardened login.

Everything under *serve* above, plus:
- **Admin console → Access Controls**: grant this node the Funnel attribute:
  ```jsonc
  "nodeAttrs": [ { "target": ["red5buntu"], "attr": ["funnel"] } ]
  ```
- Then: `tailscale funnel --bg 8080`  → public `https://<host>.<tailnet>.ts.net`

**Before funnelling:**
- Rotate `alice` off `s3cret`; remember the seeded `demo` login is then reachable by
  anyone with the URL.
- Prototype-grade: no rate limiting, bots will probe. Enable Funnel only for the
  call, then `tailscale funnel reset` and stop the server.
