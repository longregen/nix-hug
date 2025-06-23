{
  description = "Project using nix-hug for Hugging Face models";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-hug.url = "github:longregen/nix-hug";
  };

  outputs = { self, nixpkgs, nix-hug }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      
      # Load models from lock file
      models = nix-hug.lib.withLock ./hug.lock;
    in
    {
      # Example: expose a model as a package
      packages.${system} = {
        # Access models like: models.fetchModel { url = "openai-community/gpt2"; }
        # Or use locked models: models."openai-community/gpt2".main
        
        default = pkgs.writeText "example" ''
          This is a template project using nix-hug.
          
          To add models:
            nix run nix-hug -- add openai-community/gpt2
            
          To use models in Nix:
            models."openai-community/gpt2".main
        '';
      };
      
      # Development shell with nix-hug CLI
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [
          nix-hug.packages.${system}.default
        ];
        
        shellHook = ''
          echo "nix-hug project environment"
          echo "Use 'nix-hug --help' to manage models"
        '';
      };
    };
}
