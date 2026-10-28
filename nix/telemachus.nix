# The Telemachus package: source + bytecode in the store, with a wrapped `racket`
# per entrypoint.
#
# Deliberately NOT `raco exe`: an embedded executable is fragile against a
# read-only store and against `dynamic-require`, which is how plugins, MCP servers
# and OOP hosts are loaded. Wrapping the interpreter keeps the plugin SDK working
# exactly as it does in a checkout.
{ lib, stdenv, makeWrapper, racket, openssl
, poppler-utils
, pandoc, tectonic   # PDF forms (DWF-6, slice 68): doc_render md/html -> pandoc -> tectonic
, weasyprint         # #88 req 1: the HTML/CSS paged-media PDF engine. Found at
                     # CALL time like pandoc and tectonic, so a box without it
                     # boots and only an `engine: "weasyprint"` call is refused.
, pdfcpu, qpdf       # AcroForm fields (#88 req 2): pdfcpu lists and fills them,
                     # qpdf flattens. Two binaries because pdfcpu 0.15 has no
                     # flatten and qpdf cannot set a value; both are found with
                     # find-executable-path at CALL time, so a box without them
                     # boots and only a form call is refused.
, tzdata               # #137: the IANA zone database.
                     #
, commit ? "dev" }:  # The revision this was built from. A store path has no
                     # `.git` beside it, so the checkout fallback in config.rkt
                     # cannot answer on a packaged install — the flake passes
                     # `self.rev` and the wrapper SETS it. "dev" is the honest
                     # answer for a build from a dirty tree, never a guess.
                     # TZDIR is SET, not prefixed onto
                     # PATH: the image has no /usr/share/zoneinfo and no shell to
                     # debug with, so an undeclared tz database would make every
                     # zone resolve to UTC on a packaged install while working on
                     # every developer's box.

stdenv.mkDerivation (finalAttrs: {
  pname = "telemachus";
  version = "0.1.0";

  src = ../refimpl/racketmaximus;

  nativeBuildInputs = [ makeWrapper racket ];

  # #137: the zone database is a BUILD input as well as a runtime one, so the
  # unit suite's timezone vectors actually run in the sandbox. Without it they
  # skip — and a skip is how a path goes unexercised for a year (the S3 smoke's
  # lesson), which is exactly what happened here: the sandbox has no tz database,
  # so the first version of this slice shipped a `zone-exists?` that refused UTC.
  buildInputs = [ tzdata ];

  # raco writes compiled/ next to sources and racket wants a writable HOME
  preBuild = ''
    export HOME=$TMPDIR
    export PLTCOLLECTS="$PWD/pkgs:"
    export TZDIR="${tzdata}/share/zoneinfo"
  '';

  buildPhase = ''
    runHook preBuild
    raco make -j $NIX_BUILD_CORES server/main.rkt cli/telemachus-localize.rkt cli/telemachus-secrets.rkt
    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    export HOME=$TMPDIR PLTCOLLECTS="$PWD/pkgs:" TZDIR="${tzdata}/share/zoneinfo"
    # `*-tests.rkt`, never `*.rkt`: the wider glob pulls in test/mock-*.rkt, which
    # are mock SERVERS that block forever. Both suites here are hermetic — no
    # network, and no model (the LLM path falls back to a deterministic reply when
    # TMACH_MODEL_URL is unset). The HTTP smoke binds a port, so it lives in
    # `checks.smoke` instead of the build sandbox.
    raco test test/*-tests.rkt
    racket cli/telemachus-localize.rkt check surface/messages.rkt surface/greetings.rkt --required en
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/telemachus $out/bin
    cp -r . $out/share/telemachus/

    # telemachus-secrets is an OPERATOR tool (issue #19): adopting or rotating the
    # key that seals stored secrets is done from the shell, never at boot.
    for entry in server:server/main.rkt localize:cli/telemachus-localize.rkt secrets:cli/telemachus-secrets.rkt; do
      name=''${entry%%:*}; path=''${entry#*:}
      makeWrapper ${racket}/bin/racket $out/bin/telemachus-$name \
        --add-flags "$out/share/telemachus/$path" \
        --set PLTCOLLECTS "$out/share/telemachus/pkgs:" \
        --prefix PATH : ${lib.makeBinPath [ racket openssl poppler-utils pandoc tectonic weasyprint pdfcpu qpdf ]} \
        --set-default TZDIR "${tzdata}/share/zoneinfo" \
        --set-default TMACH_BUILD_COMMIT "${commit}" \
        --run 'export TMACH_DATA_DIR="''${TMACH_DATA_DIR:-''${XDG_STATE_HOME:-$HOME/.local/state}/telemachus}"'
    done
    runHook postInstall
  '';

  meta = with lib; {
    description = "Self-hosted, privacy-first, team-oriented platform for AI tools and apps";
    homepage = "https://github.com/IoTone/Telemachus";
    license = licenses.mit;
    mainProgram = "telemachus-server";
    platforms = platforms.unix;
  };
})
