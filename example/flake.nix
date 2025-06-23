{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-hug.url = "github:longregen/nix-hug";
  };

  outputs = { self, nixpkgs, nix-hug }: {
    devShells.x86_64-linux.default = 
      let
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        
        # Use withLock as documented in README.md
        hug = nix-hug.lib.withLock ./hug.lock;
        
        granite = hug.fetchModel { 
          url = "ibm-granite/granite-timeseries-patchtst";
        };
        
        # Build cache outside of shellHook to avoid string context issues
        modelCache = hug.buildCache [granite];
      in
      pkgs.mkShell {
        buildInputs = with pkgs; [
          nix-hug.packages.x86_64-linux.default  # CLI tool
          (python3.withPackages (ps: with ps; [
            transformers
            torch
          ]))
        ];
        
        shellHook = ''
          export HF_HOME=${modelCache}
          echo "Model available at: $HF_HOME"
          echo "Granite model available in HuggingFace cache format"
          echo "Use 'nix-hug --help' for CLI commands."
        '';
      };
  };
}
