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
    in
      if (builtins.length parts) < 2 then
        throw "Invalid repository URL '${url}'"
      else {
        org = builtins.elemAt parts 0;
        repo = builtins.elemAt parts 1;
        repoId = "${builtins.elemAt parts 0}/${builtins.elemAt parts 1}";
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

  fetchRepo = isDataset: {
    url,
    rev,
    filters ? null,
    repoInfoHash ? null,  # deprecated — kept for backward compat
    fileTreeHash,
    derivationHash ? null,  # deprecated — kept for backward compat
  }:
    let
      parsed = mkRepoId url isDataset;
      typePrefix = if isDataset then "datasets/" else "";
      typeName = if isDataset then "dataset" else "model";
      typeApi = if isDataset then "datasets" else "models";

      repoInfo = getRepoInfo {
        inherit (parsed) org repo;
        inherit rev repoInfoHash fileTreeHash isDataset;
      };

      gitRepo = fetchGit {
        url = "https://huggingface.co/${typePrefix}${repoInfo.repoId}.git";
        rev = repoInfo.resolvedRev;
      };

      filteredLfsFiles = applyFilter filters repoInfo.lfsFiles;

      lfsDerivations = map (file: {
        name = file.path;
        drv = fetchurl {
          url = "https://huggingface.co/${typePrefix}${repoInfo.repoId}/resolve/${repoInfo.resolvedRev}/${file.path}";
          sha256 = file.lfs.oid;
        };
      }) filteredLfsFiles;
    in
      pkgs.runCommand "hf-${typeName}-${repoInfo.org}-${repoInfo.repo}-${repoInfo.resolvedRev}"
        ({
          passthru = {
            inherit (parsed) org repo;
            revision = repoInfo.resolvedRev;
          };
        } // optionalAttrs (derivationHash != null) {
          outputHash = derivationHash;
          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
        }) ''
        mkdir -p $out

        cp -rT ${gitRepo} $out/
        chmod -R +w $out

        ${builtins.concatStringsSep "\n" (map (lfsFile: ''
          cp ${lfsFile.drv} "$out/${lfsFile.name}"
        '') lfsDerivations)}

        ${if repoInfo.repoInfoFetched != null then
          # Legacy: copy full API response (backward compat with old derivationHash)
          ''cp ${repoInfo.repoInfoFetched} $out/.nix-hug-repoinfo.json''
        else
          ''echo '{"id":"${repoInfo.repoId}","sha":"${repoInfo.resolvedRev}"}' > $out/.nix-hug-repoinfo.json''
        }

        cp ${fetchurl {
          url = "https://huggingface.co/api/${typeApi}/${repoInfo.repoId}/tree/${rev}";
          sha256 = fileTreeHash;
        }} $out/.nix-hug-filetree.json
      '';

  fetchModel = fetchRepo false;
  fetchDataset = fetchRepo true;

  buildCache =
    { models ? [], datasets ? [], hash }:
    let
      taggedModels = map (item: { inherit item; isDataset = false; }) models;
      taggedDatasets = map (item: { inherit item; isDataset = true; }) datasets;
      allTagged = taggedModels ++ taggedDatasets;

      itemInfos = map (tagged:
        let
          item = tagged.item;
          inherit (item) org repo revision;
          isDataset = tagged.isDataset;
        in {
          inherit item org repo revision isDataset;
          hubPath = if isDataset
            then "hub/datasets--${org}--${repo}"
            else "hub/models--${org}--${repo}";
          fullRepoId = "${if isDataset then "dataset" else "model"}:${org}/${repo}";
        }
      ) allTagged;
    in
      pkgs.runCommand "hf-hub-cache"
        {
          outputHash = hash;
          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
        } ''
        mkdir -p $out

        ${builtins.concatStringsSep "\n" (map (info: ''
          mkdir -p "$out/${info.hubPath}/snapshots"
          mkdir -p "$out/${info.hubPath}/refs"
          cp -r ${info.item} "$out/${info.hubPath}/snapshots/${info.revision}"
          # No trailing newline — HF Hub reads the ref file verbatim
          printf '%s' "${info.revision}" > "$out/${info.hubPath}/refs/main"
        '') itemInfos)}
      '';

in {
  inherit fetchModel fetchDataset buildCache;
  meta = {
    description = "A library for fetching Hugging Face models";
    maintainers = [ "nix-hug" ];
  };
  version = {
    lib = "4.0.0";
    api = 1;
  };
}
