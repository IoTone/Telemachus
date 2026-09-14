{
  description = "Telemachus — self-hosted, privacy-first, Racket-first platform for AI tools & apps";

  # One input. The deterministic-deps tenet applied to the toolchain: the pin lives
  # in flake.lock, not in a channel, and there is no second package manager to
  # reconcile. nixpkgs' full `racket` bundles web-server, db, rackunit, net and
  # json, so the dependency closure for the whole platform is one package.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAll (pkgs: rec {
        telemachus = pkgs.callPackage ./nix/telemachus.nix { };
        default = telemachus;
      });

      apps = forAll (pkgs:
        let tm = self.packages.${pkgs.stdenv.hostPlatform.system}.telemachus;
        in {
          default = { type = "app"; program = "${tm}/bin/telemachus-server"; };
          telemachus-server = { type = "app"; program = "${tm}/bin/telemachus-server"; };
          telemachus-localize = { type = "app"; program = "${tm}/bin/telemachus-localize"; };
        });

      # `nix develop` replaces the brew + PATH + PLTCOLLECTS preamble entirely.
      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            racket          # 9.2 CS — the version the project develops against
            sqlite          # the default backend, plus its CLI for poking at a DB
            postgresql      # the OTHER dialect: migrations must pass on both
            openssl         # TELEMACHUS_TLS=1 shells out to it for a self-signed cert
            poppler-utils   # pdftotext — PDF text extraction for the search index (slice 54)
            curl python3    # every demo script uses both
            nodejs_24       # the Playwright e2e tours (browser NOT included — see below)
            tectonic        # the developer e-book: docs/book/*.tex -> PDF (fetches TeX packages on first run)
            pandoc          # …and the same source -> a single-page HTML e-book
            jq
          ];
          shellHook = ''
            # The single most-repeated line in CLAUDE.md, now automatic. pkgs/{cli-kit,
            # db-kit,web-kit} must win over any linked copies from the old Odysseus tree.
            export PLTCOLLECTS="$PWD/refimpl/racketmaximus/pkgs:"
            echo "telemachus devShell — racket $(racket --version | grep -oE '[0-9]+\.[0-9]+' | head -1), PLTCOLLECTS set"
            echo "  cd refimpl/racketmaximus && raco make server/main.rkt"
          '';
        };
      });

      # `nix flake check` — the unit suite runs inside the package build (doCheck),
      # so it is covered by `nix build`; this adds the HTTP smoke, which binds a port
      # and therefore cannot run in the build sandbox.
      checks = forAll (pkgs:
        let system = pkgs.stdenv.hostPlatform.system; in {
          package = self.packages.${system}.telemachus;
          smoke = pkgs.runCommand "telemachus-smoke"
            { nativeBuildInputs = [ pkgs.racket pkgs.curl pkgs.python3 pkgs.bash ]; }
            ''
              cp -r ${./refimpl/racketmaximus} src && chmod -R +w src && cd src
              export HOME=$TMPDIR PLTCOLLECTS="$PWD/pkgs:" PORT=8899
              raco make -j $NIX_BUILD_CORES server/main.rkt
              bash test/server-smoke.sh
              touch $out
            '';
        });

      formatter = forAll (pkgs: pkgs.nixpkgs-fmt);
    };
}
