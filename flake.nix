{
  description = "SysRep - MQTT-Based System Monitor";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self,  nixpkgs, zig-overlay, flake-utils, ... }: (
    let perSystemOutputs = flake-utils.lib.eachDefaultSystem(system:

      let
        pkgs = import nixpkgs { inherit system; };
        zig = zig-overlay.packages.${system}."0.16.0";

        # Step 1: fetch zig package deps (network-enabled FOD)
        deps = pkgs.stdenvNoCC.mkDerivation {
            pname = "sysrep-deps";
            version = "0.1.0";
            src = ./.;
            nativeBuildInputs = [ zig ];
            dontConfigure = true;
            dontInstall = false;
            buildPhase = ''
              export ZIG_GLOBAL_CACHE_DIR=$out
              zig build --fetch
            '';
            outputHashMode = "recursive";
            outputHashAlgo = "sha256";
            outputHash = "sha256-hwvCVnzGN1+RMthX9jE0ithR+71nCM16MI9RxD6hmEA=";
        };

      in {
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "sysrep";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = [ zig ];

          buildPhase = ''
            cp -r ${deps} $TMPDIR/zig-cache
            chmod -R u+w $TMPDIR/zig-cache
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            zig build -Doptimize=ReleaseFast
          '';

          installPhase = ''
            mkdir -p $out/bin $out/share/sysrep
            cp zig-out/bin/sysrep $out/bin/sysrep
            cp cfg.yml $out/share/sysrep/
          '';
          meta.mainProgram = "sysrep";
        };
      }
    );

    in perSystemOutputs // {
      nixosModules.default = { config, lib, pkgs, ... }: (

        let
          cfg = config.services.sysrep;
          yamlFormat = pkgs.formats.yaml { };
          configFile = yamlFormat.generate("cfg.yml")(cfg.settings);

        in {
          options.services.sysrep = {
            enable = lib.mkEnableOption "sysrep";

            package = lib.mkOption {
              type = lib.types.package;
              default = pkgs.sysrep;
            };

            settings = lib.mkOption {
              type = yamlFormat.type;
              default = { };
              description = "Configuration written to sysrep's config file.";
              default = {
                mqttServer = {
                  addr = "127.0.0.1";
                  port = 1883;
                  clientId = "sysrep";
                  retries = 3;
                  timeout = 5;
                  topic = "Sysrep";
                };
                logLevel = "info";
                pollInterval = 5;
                reconnectDelay = 30;
                dtFormat = "%Y-%m-%d %I:%M:%S %p";
              };
            };
          };

          config = lib.mkIf cfg.enable {
            systemd.services.sysrep = {
              description = "SysRep - MQTT-Based System Monitor";
              wantedBy = [ "multi-user.target" ];
              after = [ "network.target" ];
              serviceConfig = {
                ExecStart = "${cfg.package}/bin/sysrep";
                WorkingDirectory = "/var/lib/sysrep";
                StateDirectory = "sysrep";
                Restart = "always";
                RestartSec = 5;
                ExecStartPre = "+${pkgs.coreutils} -sf ${configFile} /var/lib/sysrep/config.yaml";
              };
            };
          };
        }
      );
    }
  );
}
