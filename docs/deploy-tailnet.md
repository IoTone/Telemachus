# Deploying the demo over Tailscale (and the LAN)

How the `racketmaximus` reference implementation is shared **privately over a
Tailscale tailnet**, how to also answer on the **local network**, plus the
(optional, gated) paths to trusted HTTPS and a public URL.

**Pick your reach first** — `TMACH_BIND` takes a *single* interface, so the
value you choose is the whole exposure decision:

| `TMACH_BIND` | Reachable from | Use when |
|---|---|---|
| `127.0.0.1` *(default)* | this host only | developing |
| `100.70.154.54` | tailnet devices | sharing with your own devices, anywhere |
| `0.0.0.0` | tailnet **and** LAN **and** localhost | you're on the same network *and* the tailnet |

There is no value that means "tailnet + LAN but nothing else" — `0.0.0.0` binds
every interface, including the `lxcbr0`/`docker0` bridges. On a trusted network
that is fine; it is not a substitute for a firewall.

## Set the encryption key before you store a real credential

TMach has to keep some credentials in a form it can use again: the **mail relay
password**, S3 access keys, webhook and feed secrets, worker keys, two-factor
seeds. It encrypts them with one key, `TMACH_SECRET_KEY`.

**With no key set it stores them unencrypted and carries on working.** Nothing
fails and no screen warns you. The only places that say so are the boot log and
`GET /api/admin/status`, which read `secrets: plaintext`. That is deliberate — a
key can be added later with no migration — and it is how this demo ran until a
live SMTP password was typed into **Admin → Email transport** in November 2026
and sat readable in `data/telemachus.db`, a file that goes into every backup.

So do this **before** anybody enters a relay password, issues an S3 key or
turns on two-factor:

```bash
# 1. Once, on the host. The key goes in a file only this account can read —
#    never in git, never on an `Environment=` line, never in a Nix expression.
mkdir -p ~/.config/tmach && umask 077
printf 'TMACH_SECRET_KEY=%s\n' "$(openssl rand -hex 32)" > ~/.config/tmach/secret.env

# 2. Hand it to the server.
#    systemd:   EnvironmentFile=%h/.config/tmach/secret.env   then restart
#    by hand:   set -a; . ~/.config/tmach/secret.env; set +a

# 3. If the instance already stored credentials, encrypt what is there.
#    From refimpl/racketmaximus inside `nix develop`, with the key loaded as in
#    step 2 and DATABASE_URL naming the instance's database. Safe to re-run;
#    rows already encrypted are left alone.
racket cli/telemachus-secrets.rkt rewrap

# 4. Check, rather than assume.
racket cli/telemachus-secrets.rkt status      # each line: N stored, N sealed, 0 in the clear
```

`GET /api/admin/status` should now read `"secrets": "sealed"` with a
`secret_key_id`. If it still says `plaintext`, the server did not get the key —
stop there and do not enter a credential.

Three things about the key itself:

- **Keep a copy somewhere the database backup does not go.** Stored beside the
  backup it protects nothing; lost, every stored credential has to be typed in
  again.
- **Generate it once, by hand.** Never at boot: a key made fresh on each start
  encrypts everything with a key nobody has.
- **It is not `TMACH_SECRET`.** That one is the token pepper, and changing it
  signs everybody out.

`TMACH_STRICT_STARTUP=1` turns a missing key into a refusal to start, which is
the right setting for anything unattended. It **also** refuses plain HTTP on a
non-loopback address, which is exactly the tailnet setup below — so use it
with the `tailscale serve` arrangement further down (the app on `127.0.0.1`,
Tailscale in front), not with a direct tailnet bind.

Full procedures, including rotating the key:
[`ops/secrets-at-rest-runbook.md`](ops/secrets-at-rest-runbook.md).

## Current setup — private, tailnet-only

The server binds to this host's **tailnet IP**, so any device signed into the same
tailnet can reach it. Tailscale is WireGuard, so traffic is encrypted end-to-end —
plain HTTP is already private on the wire; the only thing missing vs. HTTPS is the
browser padlock.

```bash
cd refimpl/racketmaximus
export PLTCOLLECTS="$(pwd)/pkgs:"
set -a; . ~/.config/tmach/secret.env; set +a            # the encryption key, see above
TMACH_BIND=100.70.154.54 \                             # this host: `tailscale ip -4`
TMACH_MODEL_URL=http://127.0.0.1:11434/v1/chat/completions \
TMACH_MODEL=qwen2.5:7b \                               # ollama (OpenAI-compatible)
racket server/main.rkt
```

- **URL:** `http://<tailnet-ip>:8835` — this host is `red5buntu` / `100.70.154.54`
- **Model:** `qwen2.5:7b` via ollama — non-reasoning, streams cleanly (avoid the
  reasoning models like `qwen3.5:*`, whose answer lands in a `reasoning` field and
  reads as a blank reply here).
- **Bind:** `TMACH_BIND` selects the interface (default `127.0.0.1`).

## Also on the local network (LAN)

Tailscale routes over its own interface, so a tailnet-bound server is **invisible
to a laptop sitting on the same Wi-Fi** unless that laptop uses the tailnet
address. To answer on both, bind every interface:

```bash
TMACH_BIND=0.0.0.0 racket server/main.rkt     # + the model/db env from above
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
you don't control: make sure every account has a password you chose (below),
and remember the `demo` login works for anyone who reaches the page and knows it.

### Demo accounts

Two logins, **with passwords you choose when you create them**. This page does
not print any: a password in a public repository is a password for every
instance deployed by following it.

| Login | Role | Shows |
|---|---|---|
| `demo` | member | normal user — chat, notes, usage; **no** admin |
| `alice` | operator | admin — members, quotas, admin status |

- **`alice`** is the first-run operator. Create it from the console's **First
  run** form on the sign-in screen (it pre-fills nothing), or on the host itself:
  ```bash
  read -rs -p 'operator password: ' PW; echo
  curl -s -X POST http://127.0.0.1:8835/api/bootstrap \
    -d "$(jq -n --arg p "$PW" '{username:"alice",password:$p}')"
  unset PW
  ```
- **`demo`** is an ordinary member. Signed in as `alice`, add it under **Team**,
  or with alice's token:
  ```bash
  read -rs -p 'demo password: ' PW; echo
  curl -s -X POST http://127.0.0.1:8835/api/members -H "Authorization: Bearer $TOKEN" \
    -d "$(jq -n --arg p "$PW" '{username:"demo",password:$p,role:"member"}')"
  unset PW
  ```

Both routes refuse a password under six characters. Keep the two passwords out of
shell history and out of this file; change one later in the UI (**Team → Change
your password**) or with `POST /api/password`.

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
3. Run the app on `localhost` (`TMACH_BIND=127.0.0.1`), then:
   ```bash
   tailscale serve --bg 8835          # → https://<host>.<tailnet>.ts.net
   ```

> The app's own `TMACH_TLS=1` self-signed cert is **not** recommended for the
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
- Use passwords you chose for both logins (see *Demo accounts*), and remember the
  `demo` login is then reachable by anyone with the URL and its password.
- Prototype-grade: no rate limiting, bots will probe. Enable Funnel only for the
  call, then `tailscale funnel reset` and stop the server.
