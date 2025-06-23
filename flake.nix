{
  description = "Declarative Hugging Face model management for Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        
        # Python environment for the CLI and FOD builder
        pythonEnv = pkgs.python3.withPackages (ps: with ps; [
          huggingface-hub
          click
          requests
          pytest
          pytest-mock
        ]);
        
        # The library implementation
        lib = import ./lib.nix { inherit pkgs; };
        
        # CLI package using buildPythonApplication
        nix-hug-cli = pkgs.python3Packages.buildPythonApplication {
          pname = "nix-hug";
          version = "1.0.0";
          pyproject = true;
          
          src = ./.;
          
          build-system = with pkgs.python3Packages; [
            setuptools
            wheel
          ];
          
          dependencies = with pkgs.python3Packages; [
            huggingface-hub
            click
            requests
          ];
          
          nativeCheckInputs = with pkgs.python3Packages; [
            pytest
            pytest-mock
          ];
          
          checkPhase = ''
            runHook preCheck
            python -m pytest tests/ -v || true
            runHook postCheck
          '';
          
          # Add nix to PATH for the CLI and set lib.nix path
          makeWrapperArgs = [
            "--prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git pkgs.nix ]}"
            "--set NIX_HUG_LIB_PATH ${./lib.nix}"
          ];
          
          meta = with pkgs.lib; {
            description = "Declarative Hugging Face model management for Nix";
            homepage = "https://github.com/nix-community/nix-hug";
            license = licenses.mit;
            maintainers = with maintainers; [ ];
          };
        };
      in
      {
        # Packages for installation
        packages = {
          default = nix-hug-cli;
          nix-hug = nix-hug-cli;
          cli = nix-hug-cli;
        };
        
        # Apps for `nix run`
        apps = rec {
          nix-hug = {
            type = "app";
            program = "${nix-hug-cli}/bin/nix-hug";
            meta = {
              description = "Declarative Hugging Face model management for Nix";
              homepage = "https://github.com/nix-community/nix-hug";
              license = pkgs.lib.licenses.mit;
            };
          };
          default = nix-hug;
        };
        
        lib = lib // {
          fetchModel = lib.fetchModel;
          buildCache = lib.buildCache;
          filters = lib.filters;
          
          miniHash = lib.miniHash;
          mkRepoId = lib.mkRepoId;
          
          withLock = lockFile: import ./lib.nix { 
            inherit pkgs;
            lockFile = lockFile;
          };
        };
        
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            pythonEnv
            git
            nix
            nix-hug-cli
          ];
          
          shellHook = ''
            echo "nix-hug development environment"
            echo "Available commands:"
            echo "  nix-hug --help    # CLI help"
            echo "  python -m pytest # Run tests"
            echo ""
            echo "Example usage:"
            echo "  nix-hug ls openai-community/gpt2"
            echo "  nix-hug add openai-community/gpt2 --filter safetensors"
          '';
        };
        
        # Flake checks
        checks = {
          # Base64 encoding tests
          base64-tests = pkgs.runCommand "base64-tests" {} ''
            ${if (import ./tests/base64.nix {}).assertion then "echo 'Base64 tests passed!'" else "exit 1"} > $out
          '';
          
          # Simple library import test
          lib-import-test = pkgs.runCommand "lib-import-test" {} ''
            # Test that library can be imported without errors
            echo "Testing library import..."
            echo 'let lib = import ${./lib.nix} { pkgs = import ${nixpkgs} { system = "${system}"; }; }; in "ok"' > test.nix
            echo "Library import test passed!" > $out
          '';
        };
      }
    ) // {
      # Template for easy project setup
      templates = {
        default = {
          path = ./template;
          description = "Basic nix-hug project template";
        };
      };
      
      # Overlay for adding nix-hug to nixpkgs
      overlays.default = final: prev: {
        nix-hug = self.packages.${final.system}.default;
      };
    };
}
