{ pkgs, lib }:

let
  inherit (builtins) fetchurl fetchGit readFile fromJSON;
  inherit (lib) optionalAttrs;
  
  getRepoInfo = { org, repo, rev ? "main", repoInfoHash, fileTreeHash }:
    let
      repoId = "${org}/${repo}";
      
      repoInfoData = fromJSON (readFile (fetchurl {
        url = "https://huggingface.co/api/models/${repoId}";
        sha256 = repoInfoHash;
      }));
      
      fileTreeData = fromJSON (readFile (fetchurl {
        url = "https://huggingface.co/api/models/${repoId}/tree/${rev}";
        sha256 = fileTreeHash;
      }));
      
      resolvedRev = repoInfoData.sha or repoInfoData.commit or rev;
      
    in {
      inherit org repo repoId rev resolvedRev;
      files = fileTreeData;
      
      lfsFiles = lib.filter (f: f ? lfs) fileTreeData;
      nonLfsFiles = lib.filter (f: !(f ? lfs)) fileTreeData;
    };

  fetchModel = { 
    url, 
    rev ? "main",
    filters ? null,
    repoInfoHash,
    fileTreeHash,
    derivationHash,
    utils
  }:
    let
      parsed = utils.mkRepoId url;
      
      repoInfo = getRepoInfo {
        inherit (parsed) org repo;
        inherit rev repoInfoHash fileTreeHash;
      };
      
      gitRepo = fetchGit {
        url = "https://huggingface.co/${repoInfo.repoId}.git";
        rev = repoInfo.resolvedRev;
      };
      
      filtersModule = import ./filters.nix { inherit lib; };
      filteredLfsFiles = filtersModule.applyFilter filters repoInfo.lfsFiles;
      
    in
      let
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
        
        cp -r ${gitRepo}/* $out/
        chmod -R +w $out
        
        ${builtins.concatStringsSep "\n" (map (lfsFile: ''
          cp ${lfsFile.drv} "$out/${lfsFile.name}"
        '') lfsDerivations)}
        
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
  
  meta = {
    description = "Core functions for fetching Hugging Face models";
    maintainers = [ "nix-hug team" ];
  };
}
