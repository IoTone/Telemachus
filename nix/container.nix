# The OCI image (issue #89).
#
# Built from the same derivation `nix build` produces, so the thing that ships is
# the thing the unit suite ran inside — there is no second build path and no
# Dockerfile to drift from the flake. `dockerTools.buildLayeredImage` puts each
# store path in its own layer, so a Racket bump re-pushes Racket and a one-line
# server change re-pushes a few kilobytes.
#
# The posture, and why each piece is here rather than left to the operator:
#
#   • NON-ROOT. A dedicated uid with no shell and no home of its own. uid 65532
#     is the distroless "nonroot" convention, so a cluster policy written for
#     that (or a `runAsUser` already in a chart) matches without translation.
#   • READ-ONLY ROOT FILESYSTEM. Everything the server writes goes to /data,
#     which is the one declared VOLUME. The store is read-only anyway; what used
#     to break under `--read-only` is a writable HOME, which Racket wants, so
#     HOME is /data rather than a path inside the image.
#   • A HEALTHCHECK that asks the app, not the port. `/health` is `{ok,
#     multitenant}` and nothing else (issue #11) — deliberately cheap, public,
#     and the one endpoint that needs no token, which is exactly what a probe
#     wants. A TCP check would call a wedged instance healthy.
#   • AN SBOM in the image and beside it. The runtime closure is the honest
#     answer to "what is in here", and it costs nothing to record because Nix
#     already knows it exactly.
#
# /tmp is NOT in the image: under `--read-only` the caller supplies it as a
# tmpfs. compose.yaml, the k8s manifests and scripts/container-smoke.sh all do,
# and docs/ops/container.md says so — a missing /tmp surfaces as a confusing
# failure in the first request that buffers an upload.
# `extraPath` adds packages to the image's contents AND to the server's PATH.
# It exists for ONE case that the stock image cannot otherwise reach: OCR
# (issue #92) needs `tesseract`, whose closure with all 129 bundled language
# files is 1.1 GiB against this image's 1.74 GB — +63% for a feature that is off
# by default, so it is not shipped. An integrator who wants it overrides with the
# languages they actually use (English alone is 129 MiB, +7%) rather than
# maintaining a second image, which is what DEPLOY-12 declined for the slim
# variant. docs/ops/container.md carries the recipe.
#
# An EMPTY extraPath is inert: `contents ++ [ ]` and `rootPaths ++ [ ]` are the
# same lists, and the PATH string is character-identical, because
# concatMapStringsSep over [] is "" and optionalString false is "" (checked, not
# assumed). It does NOT mean this branch's image matches an older one — the image
# now contains the ocr plugin, so of course it differs. Do not try to establish
# that by comparing .drv paths from `--impure` evaluations: `<nixpkgs>` can
# resolve to a moving channel, so two evaluations of ONE expression disagree and
# the comparison means nothing.
{ pkgs, telemachus, version, extraPath ? [ ] }:

let
  uid = 65532;
  gid = 65532;
  user = "telemachus";

  # /etc/passwd, /etc/group and the TLS trust store. `fakeNss` would give us a
  # `nobody`; a named uid is clearer in `docker top` and in a pod spec, and the
  # CA bundle is needed the moment TMACH_MODEL_URL is an https endpoint.
  etc = pkgs.runCommand "telemachus-etc" { } ''
    mkdir -p $out/etc $out/data
    cat > $out/etc/passwd <<EOF
    root:x:0:0:root:/root:/sbin/nologin
    ${user}:x:${toString uid}:${toString gid}:Telemachus:/data:/sbin/nologin
    EOF
    cat > $out/etc/group <<EOF
    root:x:0:
    ${user}:x:${toString gid}:
    EOF
    # a resolver that works in a plain `docker run` as well as in a pod
    cat > $out/etc/nsswitch.conf <<EOF
    hosts: files dns
    EOF
  '';

  # What is actually in the image, from the runtime closure Nix already computed.
  # Not full SPDX — it is a flat, sorted inventory of every store path that ships,
  # with the name and version Nix parsed out of each. That is the claim it makes,
  # and it is verifiable: `nix path-info -r` on the package gives the same list.
  closure = pkgs.closureInfo { rootPaths = [ telemachus pkgs.curl pkgs.cacert etc ] ++ extraPath; };

  sbom = pkgs.runCommand "telemachus-sbom.json" { nativeBuildInputs = [ pkgs.jq ]; } ''
    mkdir -p $out/share/telemachus
    # store-paths is one path per line; split each basename into hash / name / version
    ${pkgs.python3}/bin/python3 - "$out/share/telemachus/sbom.json" <<'PY'
    import json, os, re, sys
    out = sys.argv[1]
    paths = [l.strip() for l in open("${closure}/store-paths") if l.strip()]
    pkgs_ = []
    for p in sorted(paths):
        base = os.path.basename(p)
        rest = base.split("-", 1)[1] if "-" in base else base
        m = re.match(r"^(.*?)-([0-9][^-]*(?:-[0-9][^-]*)*)$", rest)
        name, ver = (m.group(1), m.group(2)) if m else (rest, None)
        pkgs_.append({"name": name, "version": ver, "storePath": p})
    json.dump({
        "sbomVersion": 1,
        "component": {"name": "telemachus", "version": "${version}"},
        "note": "Flat inventory of the image's Nix runtime closure. "
                "Verify with: nix path-info -r <package>",
        "packageCount": len(pkgs_),
        "packages": pkgs_,
    }, open(out, "w"), indent=2, sort_keys=True)
    PY
  '';

in
pkgs.dockerTools.buildLayeredImage {
  name = "telemachus";
  # A readable tag for humans; the DIGEST is the identity, and it is reproducible
  # because every input is pinned by flake.lock. CI prints both.
  tag = version;

  contents = [
    telemachus
    etc
    sbom
    pkgs.cacert
    # curl is in here for ONE reason: the HEALTHCHECK below. A probe that needs a
    # tool the image does not ship is a healthcheck that reports "unhealthy"
    # forever, which is worse than none.
    pkgs.curl
  ] ++ extraPath;

  # /data is created in `etc` above so it exists with the right owner even when
  # nothing is mounted over it — otherwise a plain `docker run` with no volume
  # fails on a read-only parent instead of writing to the container's own layer.
  fakeRootCommands = ''
    mkdir -p ./data ./tmp
    chown -R ${toString uid}:${toString gid} ./data
    chmod 1777 ./tmp
  '';
  enableFakechroot = true;

  config = {
    User = "${toString uid}:${toString gid}";
    WorkingDir = "/data";
    Entrypoint = [ "${telemachus}/bin/telemachus-server" ];

    Env = [
      # Everything the server needs that is NOT configuration an operator should
      # have to supply. Each of these has a real failure behind it:
      #   HOME — Racket wants a writable one, and the wrapper derives
      #          TMACH_DATA_DIR from it when that is unset.
      #   TMACH_DATA_DIR — named explicitly so it never depends on the above.
      #   TMACH_BIND — a container that binds loopback is unreachable from
      #          outside itself, which is the single most common first-run
      #          mistake with a server image.
      "HOME=/data"
      "TMACH_DATA_DIR=/data"
      "TMACH_BIND=0.0.0.0"
      "PORT=8835"
      "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      # extraPath comes FIRST so an operator-supplied tool wins over anything of
      # the same name in the package wrapper, and it is on PATH at all because
      # the OCR extractor resolves `tesseract` with find-executable-path at call
      # time (DWF-6's rule) rather than being handed a store path.
      "PATH=${pkgs.lib.concatMapStringsSep ":" (p: "${p}/bin") extraPath}${
         pkgs.lib.optionalString (extraPath != [ ]) ":"
       }${pkgs.curl}/bin:${telemachus}/bin"
      # Under an orchestrator the stop signal arrives with a deadline;
      # 25s fits inside Kubernetes' default 30s grace period. See
      # domain/sched/scheduler.rkt's drain-seconds.
      "TMACH_DRAIN_SECONDS=25"
    ];

    ExposedPorts = {
      "8835/tcp" = { };
      # The S3 front door, off unless TMACH_S3_PORT is set. Declared so
      # `-P` and a Service that forwards it need no extra knowledge.
      "8836/tcp" = { };
    };

    # The blob store lives here when TMACH_BLOB_STORE is the default `rs3`
    # (local filesystem), and so does the SQLite database. Declaring it means a
    # plain `docker run` keeps documents across a restart instead of losing them
    # with the container layer.
    Volumes = { "/data" = { }; };

    # Docker/OCI want nanoseconds. --start-period is generous because the first
    # boot migrates the schema, which on an empty Postgres is 43 transactions.
    #
    # The EXEC form, not CMD-SHELL: there is no /bin/sh in this image and there
    # should not be — a shell is the first thing an attacker looks for, and the
    # only reason to add one would be to expand a variable here. The cost is
    # that the port is fixed at the image's own default, so an operator who
    # overrides PORT must override this healthcheck too (compose and the k8s
    # probes below both define their own, and a k8s httpGet probe needs nothing
    # inside the image at all).
    Healthcheck = {
      Test = [ "CMD" "curl" "-fsS" "-o" "/dev/null" "http://127.0.0.1:8835/health" ];
      Interval = 15000000000;      # 15s
      Timeout = 3000000000;        #  3s
      StartPeriod = 30000000000;   # 30s
      Retries = 3;
    };

    Labels = {
      "org.opencontainers.image.title" = "Telemachus";
      "org.opencontainers.image.description" =
        "Self-hosted, privacy-first, team-oriented platform for AI tools and apps";
      "org.opencontainers.image.version" = version;
      "org.opencontainers.image.licenses" = "MIT";
      "org.opencontainers.image.source" = "https://github.com/IoTone/Telemachus";
      # Where the inventory shipped inside the image lives.
      "ai.iotone.telemachus.sbom" = "/share/telemachus/sbom.json";
    };
  };
}
