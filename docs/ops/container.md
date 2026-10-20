# Running Telemachus in a container

The OCI image, compose for evaluation, and Kubernetes. Issue #89.

Configuration is **entirely environmental** — see
[configuration.md](configuration.md) for every variable and its default. Nothing
is written at runtime, which is what lets the image run with a read-only root
filesystem.

## Build it

```sh
nix build .#container        # on a Linux host; produces ./result, a tarball
docker load < result
docker image ls telemachus   # telemachus:0.1.0
```

The image is built from the **same derivation `nix build` produces**, so what
ships is what the unit suite ran inside. There is no Dockerfile, and that is
deliberate: a second build path is a second thing to keep in step with the
flake.

`packages.container` exists on Linux only, because an image's contents are Linux
store paths. From a Mac, build it on a Linux box or through a remote builder —
every input is pinned by `flake.lock`, so the bytes are the same either way.

## Run it

```sh
docker run -d --name telemachus \
  --read-only --tmpfs /tmp \
  --cap-drop ALL --security-opt no-new-privileges \
  -v telemachus-data:/data \
  -e DATABASE_URL='postgres://user:pass@db.internal:5432/telemachus' \
  -e TELEMACHUS_SECRET_KEY="$(openssl rand -hex 32)" \
  -e TELEMACHUS_SECRET="$(openssl rand -hex 32)" \
  -p 8835:8835 \
  --stop-timeout 30 \
  telemachus:0.1.0
```

Then `curl localhost:8835/health`, and bootstrap the first operator:

```sh
curl -XPOST localhost:8835/api/bootstrap -d '{"username":"ops","password":"a-real-password"}'
```

`POST /api/bootstrap` is **loopback-only** unless `TELEMACHUS_BOOTSTRAP_SECRET`
is set — a fresh instance on a network otherwise belongs to whoever calls first.
From outside the container that means either `docker exec`, a published port on
loopback as above, or setting that secret.

### The four flags that are not optional

| Flag | Why |
|---|---|
| `--tmpfs /tmp` | **/tmp is not in the image.** Under `--read-only` the container cannot create it, and request bodies and the PDF toolchain both need a writable one. Omitting this fails on the first upload, not at boot. |
| `-v …:/data` | Everything that persists: blobs, the SQLite file if you use one, a generated TLS cert. Without it, documents live in the container layer and vanish with it. |
| `--stop-timeout 30` | `docker stop` allows **10 seconds** by default and then SIGKILLs. The drain wants 25. A half-finished drain is worse than none — jobs are left `running` until their lease expires. |
| `-e DATABASE_URL=…` | Without it the instance uses SQLite inside `/data`, which is fine for evaluation and wrong for anything with more than one replica. |

`--read-only`, `--cap-drop ALL` and `--security-opt no-new-privileges` are not
required, but the image is built to run under all three and
`scripts/container-smoke.sh` asserts it does.

## What the image promises

- **Non-root**: uid/gid `65532:65532`, the distroless "nonroot" convention, so a
  cluster policy or a `runAsUser` written for that matches without translation.
- **No shell.** There is no `/bin/sh`, no `cat`, nothing to pivot to — the only
  extra binary is `curl`, and it is there solely so the `HEALTHCHECK` has
  something to run. A consequence worth knowing: `docker exec … sh` does not
  work, and debugging is done through the API and `docker logs`.
- **A healthcheck that asks the app.** `GET /health` is `{ok, multitenant}` and
  nothing else — cheap, public, and the one endpoint that needs no token. A TCP
  check would call a wedged instance healthy. It is the **exec** form and so
  hardcodes port 8835; if you override `PORT`, override the healthcheck too.
- **An SBOM at `/share/telemachus/sbom.json`**, a flat inventory of the image's
  Nix runtime closure. Verify it against the source with
  `nix path-info -r .#telemachus`.
- **`/data` declared as a VOLUME**, so a plain `docker run` with no `-v` still
  keeps documents across a restart instead of losing them with the container.

## Graceful shutdown

On `SIGTERM` (what `docker stop`, `systemctl stop` and Kubernetes all send) the
instance:

1. stops claiming new jobs;
2. waits up to `TELEMACHUS_DRAIN_SECONDS` (25) for in-flight jobs to finish;
3. hands back whatever did not finish — queued again, **no attempt spent**;
4. exits 0.

The log says what happened:

```
shutdown signal — draining (TELEMACHUS_DRAIN_SECONDS=25)
  drain: waiting up to 25s for 2 running job(s)
drained: 2 job(s) finished, 0 handed back to the queue
```

Why it matters: without the drain, every job the process was running stays
`running` with a live lease until the reaper notices, and the reaper requeues
with **attempt+1** — so a rolling restart spent an attempt per in-flight job,
and a job could reach `error` after three ordinary deploys.

Set the orchestrator's grace period **at least** as high as the drain:
`--stop-timeout 30` for Docker, `stop_grace_period: 30s` for compose,
`terminationGracePeriodSeconds: 30` for Kubernetes (its default, which fits).

## Compose, for evaluation

[`compose.yaml`](../../compose.yaml) brings up the app, Postgres and a
deterministic model stub:

```sh
nix build .#container && docker load < result
docker compose up                 # or: docker-compose up, for the standalone v2 binary
HOST_PORT=18835 docker compose up # if something already holds 8835

curl localhost:8835/health
curl -XPOST localhost:8835/api/bootstrap \
     -H 'X-Telemachus-Bootstrap: compose-evaluation-bootstrap' \
     -d '{"username":"ops","password":"pw-pw-pw1"}'
```

The header is needed because **bootstrap is loopback-only** and from your shell
the container is the bridge gateway, not loopback; `compose.yaml` sets the
matching `TELEMACHUS_BOOTSTRAP_SECRET` so the documented first step works. It is
an evaluation value, and the file says so.

It is for **evaluation**, and says so at each line that would be wrong in
production: the database password is in the file, no TLS terminates in front of
the app, and nothing backs up the `data` volume.

**On MinIO:** issue #89 asks for it and it is deliberately absent. Telemachus
*serves* an S3 API (`TELEMACHUS_S3_PORT`) but cannot yet *store* blobs in a
bucket — an S3-compatible blob-store backend is **issue #82**, unbuilt. A MinIO
container today would be a service nothing talks to, which reads as a broken
example rather than a staged one.

## Kubernetes

[`deploy/k8s/telemachus.yaml`](../../deploy/k8s/telemachus.yaml) is plain YAML
rather than a Helm chart — the issue allows either, and a chart's `values.yaml`
would be a second configuration surface to keep in step with
[configuration.md](configuration.md).

```sh
kubectl create namespace telemachus
kubectl -n telemachus create secret generic telemachus \
  --from-literal=database-url='postgres://user:pass@host:5432/telemachus' \
  --from-literal=secret-key="$(openssl rand -hex 32)" \
  --from-literal=secret="$(openssl rand -hex 32)"
kubectl -n telemachus apply -f deploy/k8s/telemachus.yaml
```

It sets `TELEMACHUS_STRICT_STARTUP=1`, which is the right default for an
unattended deployment: with a secret key in place and TLS on the Ingress, every
startup check passes, so a configuration mistake refuses to start instead of
running degraded.

**It is `replicas: 1`, and that is a storage limit rather than a concurrency
one.** The PVC is `ReadWriteOnce` and the default blob store (`rs3`) is a local
directory, so a second pod cannot reach the first one's documents; a shared store
is issue #82. The scheduler itself is safe in several processes — every claim is
an atomic `UPDATE … WHERE status='queued' RETURNING id`, and the drain hands back
only the attempts *that process* holds, tracked in memory rather than inferred
from `executor_id IS NULL`, precisely so one replica's restart cannot steal
another's work.

Probes are `httpGet`, not `exec`, so they need nothing inside the image and keep
working if `curl` is ever dropped from it. The `startupProbe` is generous
because the first boot migrates the schema — 43 transactions on an empty
database.

## Object storage for document bytes

Document bytes live on the data volume by default (the `rs3` store). With the
`s3blobs` plugin and `TELEMACHUS_BLOB_STORE=s3` they live in a bucket instead,
which is what removes the `ReadWriteOnce` coupling that keeps the Kubernetes
example at `replicas: 1`. Every variable is in
[configuration.md](configuration.md#object-storage-blob-store-the-s3blobs-plugin-issue-82).

The layout is `<prefix>/<org>/<sha256>`. **The org segment is load-bearing**, not
tidiness: deduplicating identical bytes inside one company is a feature, and
deduplicating them across companies is an existence oracle — "my upload finished
suspiciously fast" tells you another tenant holds that exact file (DOC‑6).

### The IAM policy

Least privilege is Get/Put/Delete on the prefix and nothing else. Telemachus
never lists the bucket, never reads another prefix, and never creates the bucket,
so none of those permissions are needed.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "Blobs",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::my-bucket/blobs/*" },
    { "Sid": "EnvelopeKey",
      "Effect": "Allow",
      "Action": ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey"],
      "Resource": "arn:aws:kms:eu-west-1:111122223333:key/<key-id>" }
  ]
}
```

`kms:GenerateDataKey` is required for SSE‑KMS even though Telemachus never calls
KMS itself — S3 calls it on the caller's behalf, so the permission is checked
against this identity. Drop the whole second statement with
`TELEMACHUS_S3_BLOB_SSE=s3` (SSE‑S3 needs no KMS grant) or `=none`.

**Deny unencrypted writes in the bucket policy as well**, because the
application-side check can only see what the bucket reports:

```json
{ "Effect": "Deny", "Principal": "*", "Action": "s3:PutObject",
  "Resource": "arn:aws:s3:::my-bucket/*",
  "Condition": { "StringNotEquals": { "s3:x-amz-server-side-encryption": "aws:kms" } } }
```

With that in place a PUT that somehow omitted the header is refused by S3; with
`TELEMACHUS_S3_BLOB_REQUIRE_ENCRYPTION` on, one that *succeeds* without
reporting encryption is refused by Telemachus. The two catch different failures
and both are worth having.

### Moving existing blobs in

```sh
racket cli/telemachus-blobs.rkt plan              # what is on disk, by org
racket cli/telemachus-blobs.rkt migrate --verify  # copy, re-hashing each blob
racket cli/telemachus-blobs.rkt verify            # read back out of the bucket
```

Safe to run while the instance is up, and resumable: **no database row moves**,
because `repo_versions` stores the digest and the store is addressed by it, so
the same rows describe the blobs wherever they live. A re-run skips what is
already present, since a content-addressed object of the right length *is* the
right object.

It **re-hashes every blob before copying it**. `rs3` takes a blob's digest from
its path, so a file whose bytes have rotted still looks correct to anything that
does not hash it — a copy that trusted the filename would propagate the rot to
the bucket under a name that lies about it. A blob whose bytes disagree with its
name is reported and **left alone**: its row points at a digest nothing can
satisfy, which is a data-loss question for an operator rather than something a
copy tool should paper over. Nothing is deleted from local disk; that is a
separate decision for after you have verified.

### On MinIO

The issue that asked for this store asks for MinIO in CI, and that is no longer
possible without credentials: **MinIO's container images are not freely
pullable** — `docker.io/minio/minio` and `quay.io/minio/minio` both answer
`unauthorized`, and `:latest` is no longer published (checked 20 Oct 2026). The
store is not MinIO-specific; path-style addressing is the default here precisely
because MinIO and Ceph RGW need it. To exercise it against a real bucket, set
`S3_TEST_ENDPOINT` (with `S3_TEST_BUCKET`/`S3_TEST_KEY`/`S3_TEST_SECRET`) and
`test/s3-blobstore-smoke.sh` section 5 will use it; without it that section
skips and says so.

## OCR is not in the image, and what to do about it

The `ocr` plugin (issue #92) ships in the image like every other plugin, but
**`tesseract` does not**, so setting `TELEMACHUS_OCR=1` on the stock image makes
the plugin fail to load and say why. That is deliberate and measured:

| What | Closure |
|---|---|
| `tesseract` with all 129 bundled language files | **1.1 GiB** |
| `tesseract.override { enableLanguages = [ "eng" ]; }` | **129 MiB** |
| the image itself, today | 1.74 GB |

All languages would grow the image by **63%** for a feature that is off by
default — and the slim-variant decision already declined a *second* image for a
23% saving, so shipping a bigger one here would be the same trade in reverse.

An integrator who wants OCR in a container adds the engine with the languages
they actually use, which is a few lines against this flake and costs ~7%:

```nix
# in your own flake. `extraPath` adds each package to the image's contents, to
# the image's closure (so the SBOM stays honest) and to the FRONT of the server's
# PATH. Leaving it out is inert — same contents, same closure, and a
# character-identical PATH — so it costs nothing when unused.
packages.container-ocr = import ./nix/container.nix {
  inherit pkgs;
  telemachus = pkgs.callPackage ./nix/telemachus.nix { };
  version = "0.1.0";
  extraPath = [ (pkgs.tesseract.override { enableLanguages = [ "eng" "spa" ]; }) ];
};
```

Then run it with `-e TELEMACHUS_OCR=1 -e TELEMACHUS_OCR_LANGUAGES=eng+spa`.

`pdftoppm`, which the OCR path uses to rasterise a scanned PDF's pages, is
already in the image as part of poppler-utils, so the engine is the only piece
missing. `TELEMACHUS_OCR_LANGUAGES` must name languages that were actually
compiled in — the plugin passes the value to tesseract as-is, and
`tesseract --list-langs` is the authority on what a given image can read.

## Startup checks

The instance refuses to serve when the blob store is not writable, when
migrations are still pending, or when the database was migrated by a **newer**
build than this one — see [configuration.md](configuration.md#startup-checks).
Two further checks (no secret key; plaintext HTTP on a non-loopback bind) are
warnings by default and refusals under `TELEMACHUS_STRICT_STARTUP=1`, because
both are positions a working instance can legitimately hold.

## Verifying a deployment

```sh
bash scripts/container-smoke.sh          # builds if needed, starts its own Postgres
IMAGE=telemachus:0.1.0 DATABASE_URL='postgres://…' bash scripts/container-smoke.sh
```

It asserts the image's own promises, then runs it the way this page describes —
read-only, non-root, no capabilities, an external Postgres — and checks that
`/health` answers, that the log says `db: postgres://` (and not a SQLite file it
quietly fell back to), that a document round-trips byte-identically through
`/data`, and that `docker stop` produces a drain and exit code 0 rather than a
kill. CI runs it on every push.
