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

  getRepoInfo = { org, repo, rev, repoInfoHash ? null, fileTreeHash, isDataset ? false }:
    let
      repoId = "${org}/${repo}";
      apiBase = "https://huggingface.co/api/${if isDataset then "datasets" else "models"}";
      isCommitHash = builtins.match "[0-9a-f]{40}" rev != null;

      # Legacy path: when rev is not a commit hash, fetch API to resolve it
      repoInfoFetched = if (!isCommitHash && repoInfoHash != null) then
        builtins.trace ''
          nix-hug: rev="${rev}" is not a commit hash. This is DEPRECATED and will stop working in a future release.
          Run `nix-hug fetch ${repoId}` to get a pinned expression with a commit hash.''
        (fetchurl {
          url = "${apiBase}/${repoId}";
          sha256 = repoInfoHash;
        })
      else null;

      repoInfoData = if repoInfoFetched != null then
        fromJSON (readFile repoInfoFetched)
      else null;

      resolvedRev =
        if isCommitHash then rev
        else if repoInfoData != null then
          (repoInfoData.sha or repoInfoData.commit or rev)
        else
          throw ''
            nix-hug: rev="${rev}" is not a commit hash and no repoInfoHash was provided.
            Run `nix-hug fetch ${repoId}` to generate a pinned expression.'';

      fileTreeData = fromJSON (readFile (fetchurl {
        url = "${apiBase}/${repoId}/tree/${rev}";
        sha256 = fileTreeHash;
      }));

    in {
      inherit org repo repoId rev resolvedRev repoInfoFetched;
      files = fileTreeData;
      lfsFiles = lib.filter (f: f ? lfs) fileTreeData;
      nonLfsFiles = lib.filter (f: !(f ? lfs)) fileTreeData;
    };

  # Simple fetch model function - all hashes provided by CLI
  fetchModel = {
    url,
    rev,
    filters ? null,
    repoInfoHash ? null,  # deprecated — kept for backward compat
    fileTreeHash,
    derivationHash ? null,  # deprecated — kept for backward compat
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
        (optionalAttrs (derivationHash != null) {
          outputHash = derivationHash;
          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
        }) ''
        mkdir -p $out

        # Copy git files
        cp -r ${gitRepo}/* $out/
        chmod -R +w $out

        # Copy LFS files from their individual derivations
        ${builtins.concatStringsSep "\n" (map (lfsFile: ''
          cp ${lfsFile.drv} "$out/${lfsFile.name}"
        '') lfsDerivations)}

        # Add metadata
        ${if repoInfo.repoInfoFetched != null then
          # Legacy: copy full API response (backward compat with old derivationHash)
          ''cp ${repoInfo.repoInfoFetched} $out/.nix-hug-repoinfo.json''
        else
          # New: minimal inline JSON
          ''echo '{"id":"${repoInfo.repoId}","sha":"${repoInfo.resolvedRev}"}' > $out/.nix-hug-repoinfo.json''
        }

        cp ${fetchurl {
          url = "https://huggingface.co/api/models/${repoInfo.repoId}/tree/${rev}";
          sha256 = fileTreeHash;
        }} $out/.nix-hug-filetree.json
      '';

  # Simple fetch dataset function - all hashes provided by CLI
  fetchDataset = {
    url,
    rev,
    filters ? null,
    repoInfoHash ? null,  # deprecated — kept for backward compat
    fileTreeHash,
    derivationHash ? null,  # deprecated — kept for backward compat
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
        (optionalAttrs (derivationHash != null) {
          outputHash = derivationHash;
          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
        }) ''
        mkdir -p $out

        # Copy git files
        cp -r ${gitRepo}/* $out/
        chmod -R +w $out

        # Copy LFS files from their individual derivations
        ${builtins.concatStringsSep "\n" (map (lfsFile: ''
          cp ${lfsFile.drv} "$out/${lfsFile.name}"
        '') lfsDerivations)}

        # Add metadata
        ${if repoInfo.repoInfoFetched != null then
          # Legacy: copy full API response (backward compat with old derivationHash)
          ''cp ${repoInfo.repoInfoFetched} $out/.nix-hug-repoinfo.json''
        else
          # New: minimal inline JSON
          ''echo '{"id":"${repoInfo.repoId}","sha":"${repoInfo.resolvedRev}"}' > $out/.nix-hug-repoinfo.json''
        }

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
