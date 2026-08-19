# The Telemachus package: source + bytecode in the store, with a wrapped `racket`
# per entrypoint.
#
# Deliberately NOT `raco exe`: an embedded executable is fragile against a
# read-only store and against `dynamic-require`, which is how plugins, MCP servers
# and OOP hosts are loaded. Wrapping the interpreter keeps the plugin SDK working
# exactly as it does in a checkout.
{ lib, stdenv, makeWrapper, racket, openssl }:

stdenv.mkDerivation (finalAttrs: {
  pname = "telemachus";
  version = "0.1.0";

  src = ../refimpl/racketmaximus;

  nativeBuildInputs = [ makeWrapper racket ];

  # raco writes compiled/ next to sources and racket wants a writable HOME
  preBuild = ''
    export HOME=$TMPDIR
    export PLTCOLLECTS="$PWD/pkgs:"
  '';

  buildPhase = ''
    runHook preBuild
    raco make -j $NIX_BUILD_CORES server/main.rkt cli/telemachus-localize.rkt
    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    export HOME=$TMPDIR PLTCOLLECTS="$PWD/pkgs:"
    # `*-tests.rkt`, never `*.rkt`: the wider glob pulls in test/mock-*.rkt, which
    # are mock SERVERS that block forever. Both suites here are hermetic — no
    # network, and no model (the LLM path falls back to a deterministic reply when
    # TELEMACHUS_MODEL_URL is unset). The HTTP smoke binds a port, so it lives in
    # `checks.smoke` instead of the build sandbox.
    raco test test/*-tests.rkt
    racket cli/telemachus-localize.rkt check surface/messages.rkt surface/greetings.rkt --required en
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/telemachus $out/bin
    cp -r . $out/share/telemachus/

    for entry in server:server/main.rkt localize:cli/telemachus-localize.rkt; do
      name=''${entry%%:*}; path=''${entry#*:}
      makeWrapper ${racket}/bin/racket $out/bin/telemachus-$name \
        --add-flags "$out/share/telemachus/$path" \
        --set PLTCOLLECTS "$out/share/telemachus/pkgs:" \
        --prefix PATH : ${lib.makeBinPath [ racket openssl ]} \
        --run 'export TELEMACHUS_DATA_DIR="''${TELEMACHUS_DATA_DIR:-''${XDG_STATE_HOME:-$HOME/.local/state}/telemachus}"'
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
