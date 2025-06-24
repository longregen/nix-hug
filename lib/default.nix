{ pkgs }:

let
  inherit (pkgs) lib;
  
  core = import ./core.nix { inherit pkgs lib; };
  filters = import ./filters.nix { inherit lib; };
  utils = import ./utils.nix { inherit lib; };
  
in {
  inherit (core) getRepoInfo;
  inherit (filters) applyFilter;
  inherit (utils) mkRepoId;
  
  fetchModel = args: core.fetchModel (args // {
    inherit utils;
  });
  
  version = {
    lib = "3.0.0";
    api = 1;
  };
}
