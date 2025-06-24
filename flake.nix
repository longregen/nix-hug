{
  description = "nix-hug - Declarative Hugging Face model management for Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      forAllSystems = f: nixpkgs.lib.genAttrs flake-utils.lib.defaultSystems f;
      
      mkCLI = pkgs: pkgs.stdenv.mkDerivation {
        pname = "nix-hug";
        version = "3.0.0";
        
        src = pkgs.lib.fileset.toSource {
          root = ./cli;
          fileset = pkgs.lib.fileset.unions [
            ./cli/nix-hug
            ./cli/completion.bash
            ./cli/lib/common.sh
            ./cli/lib/commands.sh
            ./cli/lib/hash.sh
            ./cli/lib/ui.sh
          ];
        };
        
        nativeBuildInputs = with pkgs; [ makeWrapper ];
        buildInputs = with pkgs; [ bash jq nix cacert curl ];
        
        installPhase = ''
          mkdir -p $out/bin $out/share/nix-hug/lib $out/share/bash-completion/completions
          
          cp nix-hug $out/bin/
          chmod +x $out/bin/nix-hug
          
          cp lib/common.sh $out/share/nix-hug/lib/
          cp lib/commands.sh $out/share/nix-hug/lib/
          cp lib/hash.sh $out/share/nix-hug/lib/
          cp lib/ui.sh $out/share/nix-hug/lib/
          
          cp completion.bash $out/share/bash-completion/completions/nix-hug
          
          wrapProgram $out/bin/nix-hug \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.nix pkgs.jq pkgs.curl ]} \
            --set NIX_HUG_LIB_DIR $out/share/nix-hug/lib \
            --set NIX_HUG_FLAKE_PATH ${self}
        '';
      };
      
    in
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        nix-hug-lib = import ./lib { inherit pkgs; };
      in
      {
        packages = {
          default = mkCLI pkgs;
          nix-hug = mkCLI pkgs;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            nix
            jq
            bash
            shellcheck
            nixpkgs-fmt
            curl
          ];
          
          shellHook = ''
            export NIX_HUG_LIB_DIR=$PWD/cli/lib
            export PATH=$PWD/cli:$PATH
          '';
        };

        apps = {
          default = {
            type = "app";
            program = "${self.packages.${system}.default}/bin/nix-hug";
          };
        };
      }
    ) // {
      lib = forAllSystems (system: import ./lib { pkgs = nixpkgs.legacyPackages.${system}; });
    };
}
