{ pkgs }:

let
  inherit (builtins) fetchurl fetchGit readFile fromJSON;
  inherit (pkgs) lib;
  inherit (lib) optionalAttrs;

  applyFilter = filter: files:
    if filter == null then
      files
    else
      let
        validFiles = lib.filter (f: f != null && builtins.isAttrs f && f ? path) files;
        
        lfsFiles = lib.filter (f: f ? lfs) validFiles;
        nonLfsFiles = lib.filter (f: !(f ? lfs)) validFiles;
        
        filteredFiles = 
          if filter ? include then
            lib.filter (f: 
              lib.any (pattern: builtins.match pattern f.path != null) filter.include
            ) lfsFiles ++ nonLfsFiles
          else if filter ? exclude then
            lib.filter (f: 
              !lib.any (pattern: builtins.match pattern f.path != null) filter.exclude
            ) lfsFiles ++ nonLfsFiles
          else if filter ? files then
            lib.filter (f: 
              lib.elem f.path filter.files
            ) validFiles
          else
            validFiles;
      in
        filteredFiles;

  mkRepoId = url: isDataset:
    let
      # Handle different URL formats
      cleaned = 
        if lib.hasPrefix "https://huggingface.co/datasets/" url then
          lib.removePrefix "https://huggingface.co/datasets/" url
        else if lib.hasPrefix "http://huggingface.co/datasets/" url then
          lib.removePrefix "http://huggingface.co/datasets/" url
        else if lib.hasPrefix "hf-datasets:" url then
          lib.removePrefix "hf-datasets:" url
        else if lib.hasPrefix "datasets/" url then
          lib.removePrefix "datasets/" url
        else if lib.hasPrefix "https://huggingface.co/" url then
          lib.removePrefix "https://huggingface.co/" url
        else if lib.hasPrefix "http://huggingface.co/" url then
          lib.removePrefix "http://huggingface.co/" url
        else if lib.hasPrefix "hf:" url then
          lib.removePrefix "hf:" url
        else
          url;
      
      parts = lib.splitString "/" cleaned;
      repoType = if isDataset then "dataset" else "model";
    in
      if (builtins.length parts) < 2 then
        throw "Invalid repository URL '${url}'"
      else {
        org = builtins.elemAt parts 0;
        repo = builtins.elemAt parts 1;
        repoId = "${builtins.elemAt parts 0}/${builtins.elemAt parts 1}";
        fullRepoId = "${repoType}:${builtins.elemAt parts 0}/${builtins.elemAt parts 1}";
      };
  
  # Helper function to follow redirects for HuggingFace API
  fetchWithRedirect = url: sha256:
    let
      # First try the original URL
      original = builtins.tryEval (fetchurl {
        inherit url sha256;
      });
    in
      if original.success then
        original.value
      else
        # If that fails, try with common redirect patterns
        let
          # Extract repo ID from URL
          pathParts = lib.splitString "/" url;
          repoPath = lib.concatStringsSep "/" (lib.drop 4 pathParts); # Skip https://huggingface.co/api/models or datasets
          
          # Try alternate URLs
          altUrls = [
            url  # Original
            (builtins.replaceStrings ["/models/"] ["/datasets/"] url)  # Switch model/dataset
            (builtins.replaceStrings ["/datasets/"] ["/models/"] url)  # Switch dataset/model
            # Add more redirect patterns as needed
          ];
          
          tryUrl = url: builtins.tryEval (fetchurl { inherit url sha256; });
          results = map tryUrl altUrls;
          successfulResult = lib.findFirst (r: r.success) null results;
        in
          if successfulResult != null then
            successfulResult.value
          else
            # Fallback to original if all fail
            fetchurl { inherit url sha256; };

  getRepoInfo = { org, repo, rev ? "main", repoInfoHash, fileTreeHash, isDataset ? false }:
    let
      repoId = "${org}/${repo}";
      
      repoInfoData = fromJSON (readFile (fetchWithRedirect 
        "https://huggingface.co/api/${if isDataset then "datasets" else "models"}/${repoId}"
        repoInfoHash));
      
      fileTreeData = fromJSON (readFile (fetchWithRedirect
        "https://huggingface.co/api/${if isDataset then "datasets" else "models"}/${repoId}/tree/${rev}"
        fileTreeHash));
      
      resolvedRev = repoInfoData.sha or repoInfoData.commit or rev;
      
    in {
      inherit org repo repoId rev resolvedRev;
      files = fileTreeData;
      
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
    derivationHash
  }:
    let
      parsed = mkRepoId url false;
      
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
      filteredLfsFiles = applyFilter filters repoInfo.lfsFiles;
      
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
        
        # Add stable metadata using the already-fetched API data
        cp ${fetchurl {
          url = "https://huggingface.co/api/models/${repoInfo.repoId}";
          sha256 = repoInfoHash;
        }} $out/.nix-hug-repoinfo.json
        
        cp ${fetchurl {
          url = "https://huggingface.co/api/models/${repoInfo.repoId}/tree/${rev}";
          sha256 = fileTreeHash;
        }} $out/.nix-hug-filetree.json
      '';

  # Simple fetch dataset function - all hashes provided by CLI
  fetchDataset = { 
    url, 
    rev ? "main",
    filters ? null,
    # All hashes must be provided
    repoInfoHash,
    fileTreeHash,
    derivationHash
  }:
    let
      parsed = mkRepoId url true;
      
      # Get repository info
      repoInfo = getRepoInfo {
        inherit (parsed) org repo;
        inherit rev repoInfoHash fileTreeHash;
        isDataset = true;
      };
      
      # Fetch git repository (non-Git LFS files)
      gitRepo = fetchGit {
        url = "https://huggingface.co/datasets/${repoInfo.repoId}.git";
        rev = repoInfo.resolvedRev;
      };
      
      # Apply filters if provided
      filteredLfsFiles = applyFilter filters repoInfo.lfsFiles;
      
    in
      # Use fetchurl for each LFS file individually, then combine
      let
        # Fetch each LFS file as a separate derivation using SHA from file tree
        lfsDerivations = map (file: {
          name = file.path;
          drv = fetchurl {
            url = "https://huggingface.co/datasets/${repoInfo.repoId}/resolve/${repoInfo.resolvedRev}/${file.path}";
            sha256 = file.lfs.oid;
          };
        }) filteredLfsFiles;
      in
      pkgs.runCommand "hf-dataset-${repoInfo.org}-${repoInfo.repo}-${repoInfo.resolvedRev}"
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
        
        # Add stable metadata using the already-fetched API data
        cp ${fetchurl {
          url = "https://huggingface.co/api/datasets/${repoInfo.repoId}";
          sha256 = repoInfoHash;
        }} $out/.nix-hug-repoinfo.json
        
        cp ${fetchurl {
          url = "https://huggingface.co/api/datasets/${repoInfo.repoId}/tree/${rev}";
          sha256 = fileTreeHash;
        }} $out/.nix-hug-filetree.json
      '';

  # Build HuggingFace Hub-compatible cache from multiple models and datasets
  buildCache = 
    # Handle both old interface: buildCache { models = [...]; hash = "..."; }
    # and new interface: buildCache { models = [...]; datasets = [...]; hash = "..."; }
    { models ? [], datasets ? [], hash }:
    let
      # Extract info for cache structure - handle both models and datasets
      allItems = models ++ datasets;
      itemInfos = map (item: 
        let
          repoInfoFile = "${item}/.nix-hug-repoinfo.json";
          repoInfo = if builtins.pathExists repoInfoFile
            then fromJSON (readFile repoInfoFile)
            else throw "Item ${item} missing repo info file";
          
          itemId = repoInfo.id or (throw "Item repo info missing id field");
          idParts = lib.splitString "/" itemId;
          org = builtins.elemAt idParts 0;
          repo = builtins.elemAt idParts 1;
          
          # Determine if this is a dataset based on the item path structure
          isDataset = lib.hasInfix "hf-dataset-" (toString item);
          
          revision = repoInfo.sha or repoInfo.commit or "main";
        in {
          inherit item org repo revision isDataset;
          hubPath = if isDataset 
            then "hub/datasets--${org}--${repo}"
            else "hub/models--${org}--${repo}";
          fullRepoId = "${if isDataset then "dataset" else "model"}:${org}/${repo}";
        }
      ) allItems;
    in
      pkgs.runCommand "hf-hub-cache"
        {
          outputHash = hash;
          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
          # Ensure network isolation
          __noChroot = false;
        } ''
        mkdir -p $out
        
        # Create cache structure for each item (model or dataset)
        ${builtins.concatStringsSep "\n" (map (info: ''
          # Create directory structure
          mkdir -p "$out/${info.hubPath}/snapshots"
          mkdir -p "$out/${info.hubPath}/refs"
          
          # Copy all item files (not symlink)
          cp -r ${info.item} "$out/${info.hubPath}/snapshots/${info.revision}"
          
          # Create refs/main file (no trailing newline to prevent HF Hub corruption)
          printf '%s' "${info.revision}" > "$out/${info.hubPath}/refs/main"
        '') itemInfos)}
      '';

in {
  inherit getRepoInfo fetchModel fetchDataset applyFilter mkRepoId buildCache;
  meta = {
    description = "A library for fetching Hugging Face models";
    maintainers = [ "nix-hug" ];
  };
  version = {
    lib = "3.0.0";
    api = 1;
  };
}
