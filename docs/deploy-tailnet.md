# Deploying the demo over Tailscale (and the LAN)

How the `racketmaximus` reference implementation is shared **privately over a
Tailscale tailnet**, how to also answer on the **local network**, plus the
(optional, gated) paths to trusted HTTPS and a public URL.

**Pick your reach first** — `TELEMACHUS_BIND` takes a *single* interface, so the
value you choose is the whole exposure decision:

| `TELEMACHUS_BIND` | Reachable from | Use when |
|---|---|---|
| `127.0.0.1` *(default)* | this host only | developing |
| `100.70.154.54` | tailnet devices | sharing with your own devices, anywhere |
| `0.0.0.0` | tailnet **and** LAN **and** localhost | you're on the same network *and* the tailnet |

There is no value that means "tailnet + LAN but nothing else" — `0.0.0.0` binds
every interface, including the `lxcbr0`/`docker0` bridges. On a trusted network
that is fine; it is not a substitute for a firewall.

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

- **URL:** `http://<tailnet-ip>:8835` — this host is `red5buntu` / `100.70.154.54`
- **Model:** `qwen2.5:7b` via ollama — non-reasoning, streams cleanly (avoid the
  reasoning models like `qwen3.5:*`, whose answer lands in a `reasoning` field and
  reads as a blank reply here).
- **Bind:** `TELEMACHUS_BIND` selects the interface (default `127.0.0.1`).

## Also on the local network (LAN)

Tailscale routes over its own interface, so a tailnet-bound server is **invisible
to a laptop sitting on the same Wi-Fi** unless that laptop uses the tailnet
address. To answer on both, bind every interface:

```bash
TELEMACHUS_BIND=0.0.0.0 racket server/main.rkt     # + the model/db env from above
```

- **LAN URL:** `http://10.0.0.244:8835` — this host on `eno1` (`ip -4 -o addr show eno1`)
- **Tailnet URL:** `http://100.70.154.54:8835` — still works, unchanged
- **Localhost:** `http://127.0.0.1:8835` — also comes back

### The firewall will block it until you say otherwise

`ufw` is **active** on this host with `DEFAULT_INPUT_POLICY="DROP"`. Tailscale is
unaffected — it installs its own iptables rules outside ufw's `INPUT` chain, which
is why the tailnet path works with no firewall change. **The LAN path does not.**
Open the port once, scoped to the local subnet rather than the world:

```bash
sudo ufw allow from 10.0.0.0/24 to any port 8835 proto tcp
sudo ufw status                                   # confirm the rule landed
```

> **Testing from the host itself proves nothing here.** `curl http://10.0.0.244:8835`
> run *on* this box routes through loopback, which ufw permits — so it returns 200
> whether or not the LAN is actually allowed in. Verify from the other machine.

### What LAN exposure means

Anyone on the local network can reach the app — including the **public beta signup**
at `/`, which by design takes submissions without an account. That is a different
audience from the tailnet (your own devices). Before binding `0.0.0.0` on a network
you don't control: rotate `alice` off `s3cret`, and remember the seeded `demo`
login works for anyone who reaches the page.

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
   now populated with `red5buntu.quokka-hippocampus.ts.net`, i.e. **already done**.)*
2. On this host, once: `sudo tailscale set --operator=$USER`  (so serve runs without root)
3. Run the app on `localhost` (`TELEMACHUS_BIND=127.0.0.1`), then:
   ```bash
   tailscale serve --bg 8835          # → https://<host>.<tailnet>.ts.net
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
- Then: `tailscale funnel --bg 8835`  → public `https://<host>.<tailnet>.ts.net`

**Before funnelling:**
- Rotate `alice` off `s3cret`; remember the seeded `demo` login is then reachable by
  anyone with the URL.
- Prototype-grade: no rate limiting, bots will probe. Enable Funnel only for the
  call, then `tailscale funnel reset` and stop the server.
