{
  description = "pico-dag: PICO-driven clinical research accelerator";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

        rWithPkgs = pkgs.rWrapper.override {
          packages = with pkgs.rPackages; [
            # Core
            tidyverse
            here

            # Shiny
            shiny
            bslib
            DT
            htmltools
            htmlwidgets

            # Network visualization
            visNetwork

            # HTTP
            httr2
            jsonlite

            # Database
            duckdb
            DBI

            # Export
            writexl
            yaml

            # Quarto rendering
            quarto

            # Dev
            languageserver
          ];
        };

      in {
        devShells.default = pkgs.mkShell {
          name = "pico-dag";

          packages = [
            rWithPkgs
            pkgs.quarto
            pkgs.git
            pkgs.nodejs
          ];

          env = {
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
              pkgs.stdenv.cc.cc.lib
            ];
          };

          shellHook = ''
            export USER="$(whoami 2>/dev/null || echo unknown)"
            export LANG=C.UTF-8
            export LC_ALL=C.UTF-8

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  pico-dag dev environment"
            echo "  R: $(R --version | head -1)"
            echo "  Run: Rscript -e 'shiny::runApp(\"app\")'"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          '';
        };
      });
}
