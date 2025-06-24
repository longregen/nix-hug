{ pkgs, lib }:

let
  inherit (builtins) fetchurl fetchGit readFile fromJSON;
  inherit (lib) optionalAttrs;
  
  # Get repository information
  getRepoInfo = { org, repo, rev ? "main", repoInfoHash, fileTreeHash }:
    let
      repoId = "${org}/${repo}";
      
      # Fetch API data
      repoInfoData = fromJSON (readFile (fetchurl {
        url = "https://huggingface.co/api/models/${repoId}";
        sha256 = repoInfoHash;
      }));
      
      fileTreeData = fromJSON (readFile (fetchurl {
        url = "https://huggingface.co/api/models/${repoId}/tree/${rev}";
        sha256 = fileTreeHash;
      }));
      
      # Extract resolved revision
      resolvedRev = repoInfoData.sha or repoInfoData.commit or rev;
      
    in {
      inherit org repo repoId rev resolvedRev;
      files = fileTreeData;
      
      # Categorize files
      lfsFiles = lib.filter (f: f ? lfs) fileTreeData;
      nonLfsFiles = lib.filter (f: !(f ? lfs)) fileTreeData;
    };

  # Simple fetch model function - all hashes provided by CLI
  fetchModel = { 
    url, 
    rev ? "main",
    filters ? null,
    # All hashes must be provided
    repoInfoHash,
    fileTreeHash,
    derivationHash,
    # Injected dependencies
    utils
  }:
    let
      parsed = utils.mkRepoId url;
      
      # Get repository info
      repoInfo = getRepoInfo {
        inherit (parsed) org repo;
        inherit rev repoInfoHash fileTreeHash;
      };
      
      # Fetch git repository (non-LFS files) - this has internet access
      gitRepo = fetchGit {
        url = "https://huggingface.co/${repoInfo.repoId}.git";
        rev = repoInfo.resolvedRev;
      };
      
      # Apply filters if provided
      filtersModule = import ./filters.nix { inherit lib; };
      filteredLfsFiles = filtersModule.applyFilter filters repoInfo.lfsFiles;
      
    in
      # Use fetchurl for each LFS file individually, then combine
      let
        # Fetch each LFS file as a separate derivation using SHA from file tree
        lfsDerivations = map (file: {
          name = file.path;
          drv = fetchurl {
            url = "https://huggingface.co/${repoInfo.repoId}/resolve/${repoInfo.resolvedRev}/${file.path}";
            sha256 = file.lfs.oid;
          };
        }) filteredLfsFiles;
      in
      pkgs.runCommand "hf-model-${repoInfo.org}-${repoInfo.repo}-${repoInfo.resolvedRev}"
        {
          outputHash = derivationHash;
          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
        } ''
        mkdir -p $out
        
        # Copy git files
        cp -r ${gitRepo}/* $out/
        chmod -R +w $out
        
        # Copy LFS files from their individual derivations
        ${builtins.concatStringsSep "\n" (map (lfsFile: ''
          cp ${lfsFile.drv} "$out/${lfsFile.name}"
        '') lfsDerivations)}
        
        # Add metadata
        cat > $out/.nix-hug-metadata.json <<EOF
        {
          "org": "${repoInfo.org}",
          "repo": "${repoInfo.repo}",
          "repoId": "${repoInfo.repoId}",
          "rev": "${repoInfo.rev}",
          "resolvedRev": "${repoInfo.resolvedRev}",
          "filters": ${if filters == null then "null" else builtins.toJSON filters},
          "fetchedFileCount": ${toString (builtins.length filteredLfsFiles)}
        }
        EOF
      '';

in {
  inherit getRepoInfo fetchModel;
  
  # Add metadata for documentation
  meta = {
    description = "Core functions for fetching Hugging Face models";
    maintainers = [ "nix-hug team" ];
  };
}
