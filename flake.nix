{
  description = "nix-hug - Declarative Hugging Face model management for Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      forAllSystems = f: nixpkgs.lib.genAttrs flake-utils.lib.defaultSystems f;
      
      # Create the CLI package
      mkCLI = pkgs: pkgs.stdenv.mkDerivation {
        pname = "nix-hug";
        version = "3.0.0";
        
        src = ./cli;
        
        nativeBuildInputs = with pkgs; [ makeWrapper ];
        buildInputs = with pkgs; [ bash jq nix cacert curl ];
        
        installPhase = ''
          mkdir -p $out/bin $out/share/nix-hug/lib $out/share/bash-completion/completions
          
          # Install main script
          cp nix-hug $out/bin/
          chmod +x $out/bin/nix-hug
          
          # Install library files
          cp lib/*.sh $out/share/nix-hug/lib/
          
          # Install completions
          cp completion.bash $out/share/bash-completion/completions/nix-hug
          
          # Wrap with dependencies
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
            echo "nix-hug development environment"
            echo "Run ./cli/nix-hug --help for usage"
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
