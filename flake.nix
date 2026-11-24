{
  description = "Škoda Enyaq and other connected Škodas for Dux Shell";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      forAll =
        f: nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (s: f nixpkgs.legacyPackages.${s});

      # Every QML and JS file next to plugin.json is part of the plugin, so a new component cannot be forgotten.
      plugin =
        pkgs:
        pkgs.runCommand "duxskoda" { } ''
          mkdir $out
          cp ${self}/plugin.json ${self}/*.qml ${self}/*.js $out/
        '';
    in
    {
      packages = forAll (pkgs: {
        default = plugin pkgs;
      });

      homeModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.programs.duxskoda;
          opt =
            type: description:
            lib.mkOption {
              type = lib.types.nullOr type;
              default = null;
              inherit description;
            };
        in
        {
          options.programs.duxskoda = {
            enable = lib.mkEnableOption "the Škoda widget for Dux Shell";
            tokenFile = opt lib.types.str "Path to a file with only your MyŠkoda API key. Keep it out of the nix store (agenix, sops, or a plain file); null uses ~/.config/skoda/token.";
            vinFile = opt lib.types.str "Path to a file with only your car's VIN; null uses ~/.config/skoda/vin.";
            refreshMinutes =
              opt
                (lib.types.enum [
                  10
                  15
                  30
                  60
                ])
                "Minutes between refreshes. The API allows 20 requests per hour per car, shared with every other app that uses it.";
          };

          config = lib.mkIf cfg.enable {
            programs.dank-material-shell.plugins.duxSkoda.src = plugin pkgs;
            xdg.configFile."skoda/config.json".text = builtins.toJSON (
              lib.filterAttrs (_: v: v != null) {
                inherit (cfg) tokenFile vinFile refreshMinutes;
              }
            );
          };
        };

      checks = forAll (pkgs: {
        logic = pkgs.runCommand "duxskoda-logic" { nativeBuildInputs = [ pkgs.nodejs ]; } ''
          cd ${self} && node --test 'tests/*.test.mjs' && touch $out
        '';

        manifest = pkgs.runCommand "duxskoda-manifest" { nativeBuildInputs = [ pkgs.jq ]; } ''
          jq -e '
            .id == "duxSkoda" and .type == "widget"
            and (.component | test("^\\./")) and (.requires_dms | test("^>=\\d+\\.\\d+\\.\\d+$"))
            and ((.permissions - ["settings_read", "settings_write", "process", "network"]) | length == 0)
          ' ${self}/plugin.json && touch $out
        '';

        # The files the manifest points at must be in the package.
        packaged = pkgs.runCommand "duxskoda-packaged" { nativeBuildInputs = [ pkgs.jq ]; } ''
          for f in $(jq -r '.component, .settings' ${self}/plugin.json); do
            test -e ${plugin pkgs}/$f || { echo "$f is not packaged"; exit 1; }
          done
          touch $out
        '';
      });

      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.nodejs
            pkgs.jq
            pkgs.python3
            pkgs.xvfb
            pkgs.kdePackages.qtdeclarative
          ];
        };
      });
    };
}
