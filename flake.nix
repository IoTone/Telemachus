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
      } // nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        # The OCI image (issue #89) — Linux only, because an image's contents are
        # Linux store paths. On a Mac, build it on a Linux host (or a remote
        # builder); `nix build .#container` there produces the same bytes.
        container = import ./nix/container.nix {
          inherit pkgs;
          telemachus = pkgs.callPackage ./nix/telemachus.nix { };
          version = "0.1.0";
        };
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
            racket          # 9.3 CS — the version the project develops against
            sqlite          # the default backend, plus its CLI for poking at a DB
            postgresql      # the OTHER dialect: migrations must pass on both
            openssl         # TELEMACHUS_TLS=1 shells out to it for a self-signed cert
            poppler-utils   # pdftotext — PDF text extraction for the search index (slice 54);
                            # ALSO pdftoppm, which is how the OCR extractor renders a
                            # scanned PDF's pages to images (issue #92). One dependency
                            # covering both is why ocrmypdf is not here: it would add a
                            # Python application to do what two pinned binaries already do.
            tesseract       # the OCR engine (issue #92). The nixpkgs build bundles 129
                            # language files, so #92's "at least eng, spa" needs no
                            # override — `tesseract --list-langs` is the authority.
                            # Found with find-executable-path at CALL time (DWF-6), so a
                            # box without it boots and every other format still reads.
            curl python3    # every demo script uses both
            awscli2         # test/s3-smoke.sh drives the REAL client (issue #25) — the
                            # endpoint was built against aws-cli requests captured on
                            # the wire, so a mock would not prove the same thing
            nodejs_24       # the Playwright e2e tours (browser NOT included — see below)
            tectonic        # the developer e-book: docs/book/*.tex -> PDF (fetches TeX packages on first run)
            pandoc          # …and the same source -> a single-page HTML e-book
            # The book's CJK editions. xeCJK resolves these BY NAME through
            # fontconfig, so the packages alone are not enough — FONTCONFIG_FILE
            # below is what makes them findable. CLAUDE.md and TRANSLATING.md both
            # said these were in the devShell while they were not, so `build.sh ja`
            # died with `The font "Noto Serif CJK JP" cannot be found` on any box
            # that had not installed them by hand.
            # STATIC faces, not the default variable-font collections: nixpkgs now
            # ships `NotoSerifCJK-VF.otf.ttc`, and XeTeX resolves neither the family
            # name nor a face index inside one, so the build died on a font that
            # fontconfig could see perfectly well.
            noto-fonts-cjk-serif-static
            noto-fonts-cjk-sans-static
            jq
          ];
          shellHook = ''
            # xeCJK asks fontconfig for "Noto Serif CJK JP" by name, and a bare
            # `nix develop` inherits whatever fontconfig the host happens to have —
            # which on a machine with no system-wide Noto CJK is a config that
            # cannot see the packages above. This pins a config that can.
            export FONTCONFIG_FILE="${pkgs.makeFontsConf {
              fontDirectories = [ pkgs.noto-fonts-cjk-serif-static pkgs.noto-fonts-cjk-sans-static ];
            }}"
            # The single most-repeated line in CLAUDE.md, now automatic. pkgs/{cli-kit,
            # db-kit,web-kit} must win over any linked copies from the old Odysseus tree.
            export PLTCOLLECTS="$PWD/refimpl/racketmaximus/pkgs:"
            # A machine working on a DOWNSTREAM plugin needs that plugin's own
            # collections on PLTCOLLECTS, and its path belongs to nobody else. So
            # source an optional, gitignored .env.local AFTER the line above, which
            # lets it append rather than replace. No file, no effect — see
            # .env.local.example.
            [ -f "$PWD/.env.local" ] && . "$PWD/.env.local"
            echo "telemachus devShell — racket $(racket --version | grep -oE '[0-9]+\.[0-9]+' | head -1), PLTCOLLECTS set"
            [ -f "$PWD/.env.local" ] && echo "  .env.local sourced"
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
