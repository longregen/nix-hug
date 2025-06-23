{ pkgs, lockFile ? null }:

let
  lib = pkgs.lib;
  base64 = import ./base64.nix;
  
  inherit (builtins) 
    attrNames elemAt head mapAttrs readFile fromJSON pathExists toJSON 
    hashString substring replaceStrings isAttrs isList listToAttrs
    filter attrValues getEnv baseNameOf;
  
  VERSION = 1;
  DEFAULT_REF = "main";
  HF_BASE_URLS = ["https://huggingface.co/" "http://huggingface.co/" "hf:"];
  
in rec {
  # LOCK FILE HANDLING
  
  # Load and validate lock file
  lockData = 
    let
      default = { version = VERSION; models = {}; };
      load = path:
        let data = fromJSON (readFile path); in
        if data.version == null || data.version != VERSION then
          abort "Unsupported lock file version ${toString (data.version ? "unknown")} (expected ${toString VERSION})"
        else data;
    in
      if lockFile != null && pathExists lockFile then load lockFile else default;
  
  # HELPER FUNCTIONS
  
  # Canonicalize data structure for consistent hashing
  canonicalise = obj:
    if isAttrs obj then
      listToAttrs (
        lib.sort (a: b: a.name < b.name)
          (lib.mapAttrsToList (name: value: { 
            inherit name; 
            value = canonicalise value; 
          }) obj)
      )
    else if isList obj then
      lib.sort (a: b: a < b) (map canonicalise obj)
    else 
      obj;
  
  # Generate 22-char minihash (must be identical to Python implementation)
  miniHash = filters:
    if filters == null then "base" else
      let
        canonical = toJSON (canonicalise filters);
        hashHex = hashString "sha256" canonical;
        base64Hash = base64.hexStringToBase64UrlSafe hashHex;
      in 
        substring 0 22 base64Hash;
  
  # Parse repository URL into `org/repo` format
  mkRepoId = url:
    let
      # Remove common prefixes in one pass
      cleaned = lib.removePrefix "https://huggingface.co/"
        (lib.removePrefix "http://huggingface.co/"
          (lib.removePrefix "hf:" url));
      parts = lib.splitString "/" cleaned;
    in
      if (builtins.length parts) < 2 
      then abort "Invalid repository URL: ${url}"
      else "${elemAt parts 0}/${head (lib.splitString "/tree/" (elemAt parts 1))}";
  
  # Lookup hash from lock file with fallback
  fromLock = repoId: mHash: default:
    let
      repo = lockData.models.${repoId} or {};
      variant = (repo.variants or {}).${mHash} or {};
    in 
      variant.hash or default;
  
  # Derivation Helpers
  
  # Check if we need the custom builder
  needsCustomBuilder = filters: filters != null;
  
  # Build with custom builder
  buildWithCustomBuilder = { 
    drvName, 
    hash, 
    repoId, 
    rev, 
    ref, 
    filters, 
    builderSrc,
    mHash
  }:
    pkgs.runCommand drvName {
      outputHash = hash;
      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
      
      nativeBuildInputs = [ 
        (pkgs.python3.withPackages (ps: with ps; [ huggingface-hub requests ]))
        pkgs.git
      ];
      
      # Environment variables for builder
      NIX_HUG_REPO = repoId;
      NIX_HUG_REV = rev ? ref ? DEFAULT_REF;
      NIX_HUG_FILTERS = if filters != null then (toJSON filters) else "{}";
      NIX_HUG_TOKEN = getEnv "HF_TOKEN";
      NIX_HUG_LOCK_FILE = lib.optionalString (lockFile != null) lockFile;
      NIX_HUG_VARIANT_KEY = mHash;
    } ''
      # Copy builder source and execute
      cp -r ${builderSrc} ./nix_hug
      python3 -m nix_hug.builder
    '';
  
  # Main fetch function
  
  # Fetch HuggingFace model with optional filtering and caching
  fetchModel = { 
    url, 
    hash ? lib.fakeHash, 
    rev ? null, 
    ref ? null, 
    filters ? null
  }:
    let
      # Parse and validate URL
      repoId = mkRepoId url;
      parts = lib.splitString "/" repoId;
      org = elemAt parts 0;
      repo = elemAt parts 1;
      
      # Generate identifiers
      mHash = miniHash filters;
      drvName = "hf-model--${org}--${repo}--${mHash}";
      
      # Determine effective values
      effectiveHash = 
        if hash != lib.fakeHash then 
          hash 
        else if lockFile != null then
          # Try to get from lock file, fallback to lib.fakeHash if not found
          fromLock repoId mHash lib.fakeHash
        else 
          abort ''
            Missing hash for model '${repoId}'
            
            To get the hash, run:
              nix run github:longregen/nix-hug -- fetch ${repoId}${lib.optionalString (filters != null) " --filter ..."}
            
            Or use a lock file:
              nix run github:longregen/nix-hug -- add ${repoId}${lib.optionalString (filters != null) " --filter ..."}
              # Then use: nix-hug.lib.withLock ./hug.lock
          '';
      
      effectiveRef = ref ? DEFAULT_REF;
      
      # Build the derivation - always use custom builder when we have a lock file
      derivation = 
        if needsCustomBuilder filters || lockFile != null
        then buildWithCustomBuilder {
          inherit drvName repoId rev filters mHash;
          hash = effectiveHash;
          ref = effectiveRef;
          builderSrc = ./nix_hug;
        }
        else builtins.fetchGit ({
          url = "https://huggingface.co/${repoId}.git";
          lfs = true;
          name = drvName;
        } // lib.optionalAttrs (rev != null) { inherit rev; }
          // lib.optionalAttrs (ref != null && ref != DEFAULT_REF) { ref = effectiveRef; });
    in
      derivation;
  
  # Cache building
  
  # Extract model info from store path
  extractModelInfo = model:
    let
      name = baseNameOf model;
      parts = lib.splitString "--" name;
    in {
      org = elemAt parts 1;
      repo = elemAt parts 2;
      variantKey = lib.last parts;  # Extract variant key from derivation name
      revision = DEFAULT_REF;
    };
  
  # Build HuggingFace Hub cache structure for local use
  buildCache = models:
    let
      # Create cache entry for a single model
      createCacheEntry = model:
        let
          info = extractModelInfo model;
          modelId = "${info.org}--${info.repo}";
          repoId = "${info.org}/${info.repo}";
          
          # Look up variant by key (no string context issues!)
          cleanRepoId = builtins.unsafeDiscardStringContext repoId;
          cleanVariantKey = builtins.unsafeDiscardStringContext info.variantKey;
          modelData = lockData.models.${cleanRepoId} or {};
          variant = (modelData.variants or {}).${cleanVariantKey} or {};
          ref = variant.tag_or_branch or "main";
          
        in
          pkgs.linkFarm "model-${info.org}-${info.repo}" [
            {
              name = builtins.unsafeDiscardStringContext "hub/models--${modelId}/snapshots/${info.revision}";
              path = model;
            }
            {
              name = builtins.unsafeDiscardStringContext "hub/models--${modelId}/refs/${ref}";
              path = pkgs.writeText "ref" info.revision;
            }
          ];
      
      cacheEntries = map createCacheEntry models;
    in
      pkgs.symlinkJoin {
        name = "hf-hub-cache";
        paths = cacheEntries;
      };
  
  # Filter presets
  
  # Common filter presets for different model formats
  filters = {
    safetensors = {
      include = [ 
        "*.safetensors" 
        "*.json" 
        "*.txt" 
        "tokenizer_config.json" 
        "config.json" 
      ];
    };
    
    onnx = {
      include = [ "*.onnx" "*.json" "*.txt" ];
    };
    
    pytorch = {
      include = [ 
        "*.bin" 
        "pytorch_model.bin" 
        "*.json" 
        "*.txt" 
      ];
    };
  };
  
  # Create a library instance with a specific lock file
  withLock = lockFilePath: 
    import ./lib.nix { 
      inherit pkgs; 
      lockFile = lockFilePath; 
    };
}
