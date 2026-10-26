# Secrets at rest — operator runbook

Operator-facing. What TMach stores that cannot be hashed, what sealing those
values does and does not buy, and the three procedures: adopting a key, rotating
one, and revoking a two-factor seed. Issue
[#19](https://github.com/IoTone/Telemachus/issues/19).

**Everything below runs from `refimpl/racketmaximus/`, inside `nix develop`.**

---

## 1. What is stored, and why it cannot all be hashed

| Value | Stored as | Why |
|---|---|---|
| Passwords | PBKDF2 hash | Verified by re-hashing. Nothing to steal. |
| API tokens | peppered HMAC-SHA-256 (`v1:<hex>`) | Same. |
| `users.totp_secret` | **the seed itself** | A TOTP code is computed *from* the seed; there is nothing to compare a hash against. |
| `repo_credentials.secret_key` | **the secret itself** | SigV4 is an HMAC keyed by it. An HMAC cannot be checked against a hash. |
| `executors.secret_key` | **the secret itself** | A push executor signs with it. |

Those bottom three are *replayable*: whoever reads the row can use the credential.
Before this change they sat in the clear, so a single database dump — a backup
file, a read replica, a `pg_dump` pasted into a ticket, a stolen volume snapshot —
was enough to replay all of them.

## 2. What sealing them buys, exactly

The key lives in the environment (`TELEMACHUS_SECRET_KEY`), never in the database.

- **It defends a dump.** A dump travels without the process's environment, and the
  sealed rows are AES-256-GCM ciphertext.
- **It does not defend a host.** An attacker who is running as the server reads the
  key out of its own environment. Nothing here changes that, and nothing here
  should be read as claiming otherwise.
- **It does not replace encrypting the volume, or keeping backups out of reach.**
  It means that when a backup *does* end up somewhere it should not, the credentials
  in it are not usable.

Corollary for where the key lives: keeping it in the same backup as the database
puts it back in the dump and buys nothing. Put it in the unit file, the secret
manager, or the environment of the service — somewhere a database backup does not
reach.

## 2b. Volume encryption is necessary, and it is not sufficient

The two claims point in opposite directions and both are true, so it is worth
being plain about which does what.

RDS encryption, an encrypted EBS volume or LUKS under the data directory defends
**the disk at rest**: a drive pulled out of a rack, a decommissioned volume, a
snapshot copied to another account. Turn it on. Nothing below is a reason not to.

What it cannot defend is every path a dump actually takes, because **a running
database decrypts for anyone it answers**:

- `pg_dump` output, which is plaintext whatever the volume is encrypted with —
  including the copy attached to a support ticket.
- A read replica or a logical-replication subscriber, which receives decrypted
  rows and may sit under a different, weaker key.
- A backup restored onto a host that is encrypted with a key many people hold.
- Anything with `SELECT` on the database: a reporting account, an ORM console, a
  BI tool, an analyst, a compromised credential that is not the server's own.

Those are the cases application-level sealing covers, because the ciphertext in
the column travels with the row and the key does not travel with the dump. The
two layers compose and neither replaces the other: the volume protects the disk,
the column protects the *data*, and the column is the one that survives being
`SELECT`ed.

Two switches, deliberately separate (ENC-1):

| Variable | Seals | Default |
|---|---|---|
| `TELEMACHUS_SECRET_KEY` | the three replayable credentials above | unset (plaintext — a supported choice) |
| `TELEMACHUS_ENCRYPT_CONTENT` | document-derived content: `repo_text`, job payloads/results/errors, workflow run and step bindings and errors, translations, trigger-fire errors | off |

`TELEMACHUS_ENCRYPT_CONTENT` is its own switch because sealing `repo_text.content`
**removes content search** — the match is a SQL `LIKE` over that column — so it
cannot ride along on a key every instance should set. Turning it on without a key
refuses to start, because that combination writes the plaintext it was enabled to
prevent *and* costs search, while reporting healthy.

## 3. Is this instance sealed?

```sh
racket cli/telemachus-secrets.rkt status
```

```
secret key : configured (id 0dd60e84)
users.totp_secret: 1 stored, 1 sealed, 0 in the clear
repo_credentials.secret_key: 1 stored, 1 sealed, 0 in the clear
executors.secret_key: 0 stored, 0 sealed, 0 in the clear

A dump of this database carries no replayable secret.
```

The server says the same thing at boot (`secrets: sealed (key 0dd60e84)` or
`secrets: plaintext`), and `GET /api/admin/status` reports `secrets` and
`secret_key_id` for a monitor.

**Running with no key is a supported choice** — it is the "the database is the
trust boundary" position, and it is what every instance did before this existed.
The point of the status line is that it is now a decision you can see, rather than
one you inherit without noticing.

## 4. Adopting a key on a running instance

Existing rows are plaintext and stay readable, so this is not a migration and
there is no downtime.

```sh
racket cli/telemachus-secrets.rkt keygen        # a 256-bit key, hex
# put it in the service environment as TELEMACHUS_SECRET_KEY, then:
DATABASE_URL=… TELEMACHUS_SECRET_KEY=… racket cli/telemachus-secrets.rkt rewrap
```

`rewrap` seals every plaintext row and leaves rows already sealed by the current
key alone, so it is safe to re-run after an interruption. Restart the server with
the key in its environment (either order works — a plaintext row reads with or
without a key; a sealed row needs it).

A passphrase is accepted in place of 64 hex characters and is stretched with
PBKDF2; it is not truncated. `keygen` is still the better answer.

> **Losing the key loses the secrets it sealed.** Every TOTP seed and S3 secret
> becomes unreadable — users re-enrol their second factor (§6) and re-issue their
> access keys. The server will not start pretending they are empty; it raises.

## 5. Rotating the key

```sh
export TELEMACHUS_SECRET_KEY_OLD=<the current key>
export TELEMACHUS_SECRET_KEY=<the new key>
racket cli/telemachus-secrets.rkt rewrap
```

Rows sealed by either key are readable while both are set; `rewrap` re-seals every
row under the new one. When `status` reports the new key id against every row,
drop `TELEMACHUS_SECRET_KEY_OLD` and restart.

An unreadable row **stops the run** rather than being skipped — carrying on would
quietly leave behind secrets nobody can decrypt.

This is deliberately separate from `TELEMACHUS_SECRET` / `TELEMACHUS_TOKEN_PEPPER`.
Rotating the pepper signs everyone out, which is a fine emergency action; if the
same value sealed stored secrets, that action would also destroy them.

## 6. Revoking a two-factor seed

A password can be changed and an access key re-issued, but a TOTP seed cannot be
rotated by using it — which is why the issue called it out. It can now be revoked,
which forces a fresh enrolment and makes the old seed useless:

```sh
curl -X DELETE $BASE/api/2fa -H "Authorization: Bearer $TOKEN"                # your own
curl -X DELETE $BASE/api/admin/users/<id>/2fa -H "Authorization: Bearer $OP"  # anyone's (instance:manage)
```

Both are audited as `user.2fa.reset`. The response says `was_enabled`, so a script
can tell "turned it off" from "there was nothing on".

**If a dump taken before sealing has leaked**, the order is: revoke the seeds
(§6), revoke and re-issue the S3 credentials (`DELETE /api/repo-credentials/<id>`,
then issue new ones), adopt a key (§4) so the next dump is not a repeat, and
rotate the token pepper if tokens were in the same dump.

## 7. How it is stored

`enc:v1:<key-id>:<nonce base64>:<ciphertext+tag base64>`, AES-256-GCM. Anything
without the `enc:v1:` prefix is plaintext and is read as-is.

- The **key id** is the first 8 hex of the key's SHA-256 — a label, not a secret,
  so a rotation knows which key to try.
- Each value is sealed with **its column and row id as additional authenticated
  data**, so a ciphertext lifted out of one row and pasted into another does not
  open. Someone with write access to the database cannot move a known secret onto
  another principal.
- A fresh nonce per write means two identical secrets are not identical
  ciphertexts in a dump.
- A sealed value that will not open **raises**. It must never look like an empty
  secret: an empty TOTP seed would silently disable somebody's second factor.

Correctness is pinned to NIST's GCM vectors in `test/secretbox-tests.rkt`, the same
way `sha2.rkt` pins its digests — the risk in an FFI binding is a wrong signature,
and a vector catches that immediately.
