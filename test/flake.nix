{
  description = "nix-hug standalone integration test";

  inputs = {
    nix-hug.url = "path:..";
    nixpkgs.follows = "nix-hug/nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      nix-hug,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      nix-hug-lib = nix-hug.lib.${system};

      # 1. Fetch a tiny model (new v3 format — commit hash + fileTreeHash only)
      tiny-llama = nix-hug-lib.fetchModel {
        url = "stas/tiny-random-llama-2";
        rev = "3579d71fd57e04f5a364d824d3a2ec3e913dbb67";
        fileTreeHash = "sha256-mD+VYvxsLFH7+jiumTZYcE3f3kpMKeimaR0eElkT7FI=";
      };

      # 2. Build a HF Hub-compatible cache
      model-cache = nix-hug-lib.buildCache {
        models = [ tiny-llama ];
        hash = "sha256-psQcpC+BAfAFpu7P5T1+VXAPSytrq4GcfqiY2KWAU8g=";
      };
    in
    {
      checks.${system} = {
        # Test: fetchModel produces a valid store path with expected contents
        fetchModelTest = pkgs.runCommand "fetch-model-test" { } ''
          echo "=== fetchModel test ==="

          # The derivation must exist
          test -d ${tiny-llama} || { echo "FAIL: model dir missing"; exit 1; }

          # Must contain metadata files
          test -f ${tiny-llama}/.nix-hug-repoinfo.json || { echo "FAIL: missing repoinfo"; exit 1; }
          test -f ${tiny-llama}/.nix-hug-filetree.json || { echo "FAIL: missing filetree"; exit 1; }

          # repoinfo must have id and sha
          ${pkgs.jq}/bin/jq -e '.id'  ${tiny-llama}/.nix-hug-repoinfo.json >/dev/null
          ${pkgs.jq}/bin/jq -e '.sha' ${tiny-llama}/.nix-hug-repoinfo.json >/dev/null

          # Must contain config.json (present in all HF model repos)
          test -f ${tiny-llama}/config.json || { echo "FAIL: missing config.json"; exit 1; }

          echo "fetchModel test passed!" | tee $out
        '';

        # Test: buildCache produces the right directory layout
        buildCacheTest = pkgs.runCommand "build-cache-test" { } ''
          echo "=== buildCache test ==="

          cache=${model-cache}
          hub="$cache/hub/models--stas--tiny-random-llama-2"

          # Hub directory structure must exist
          test -d "$hub/snapshots" || { echo "FAIL: missing snapshots dir"; exit 1; }
          test -d "$hub/refs"      || { echo "FAIL: missing refs dir"; exit 1; }

          # refs/main must point to a commit hash
          rev=$(cat "$hub/refs/main")
          echo "refs/main -> $rev"
          test ''${#rev} -eq 40 || { echo "FAIL: refs/main is not a 40-char hash"; exit 1; }

          # Snapshot directory for that rev must exist and contain config.json
          test -d "$hub/snapshots/$rev"             || { echo "FAIL: snapshot dir missing"; exit 1; }
          test -f "$hub/snapshots/$rev/config.json" || { echo "FAIL: config.json missing in snapshot"; exit 1; }

          echo "buildCache test passed!" | tee $out
        '';

        # Test: model loads in Python with transformers
        pythonLoadTest =
          pkgs.runCommand "python-load-test"
            {
              buildInputs = [
                (pkgs.python3.withPackages (
                  ps: with ps; [
                    transformers
                    torch
                  ]
                ))
              ];
              __noChroot = false;
            }
            ''
              echo "=== Python load test ==="
              export HF_HUB_CACHE=${model-cache}
              export TRANSFORMERS_OFFLINE=1

              python3 -c "
              from transformers import AutoModelForCausalLM, AutoTokenizer
              import os, sys
                
              cache = os.environ['HF_HUB_CACHE']
              snap = os.path.join(cache, 'hub', 'models--stas--tiny-random-llama-2', 'snapshots')
              revs = os.listdir(snap)
              assert len(revs) == 1, f'Expected 1 snapshot, got {len(revs)}'
              path = os.path.join(snap, revs[0])

              model = AutoModelForCausalLM.from_pretrained(path, local_files_only=True)
              tok   = AutoTokenizer.from_pretrained(path, local_files_only=True)
              print(f'Model: {type(model).__name__}')
              print(f'Tokenizer: {type(tok).__name__}')
              print('Python load test passed!')
              " 2>&1 | tee $out
            '';

        # Test: applyFilter works correctly with subdirectory paths
        filterSubdirTest = let
          # Mock file entries simulating a recursive tree response with subdirectories
          mockFiles = [
            { path = ".gitattributes"; type = "file"; size = 123; }
            { path = "README.md"; type = "file"; size = 456; }
            { path = "config.json"; type = "file"; size = 789; }
            { path = "Q5_K_S"; type = "directory"; }
            { path = "Q5_K_S/model-00001-of-00003.gguf"; type = "file"; size = 1000;
              lfs = { oid = "abc123"; size = 1000; }; }
            { path = "Q5_K_S/model-00002-of-00003.gguf"; type = "file"; size = 1000;
              lfs = { oid = "def456"; size = 1000; }; }
            { path = "Q5_K_S/model-00003-of-00003.gguf"; type = "file"; size = 1000;
              lfs = { oid = "ghi789"; size = 1000; }; }
            { path = "Q8_0"; type = "directory"; }
            { path = "Q8_0/model-q8.gguf"; type = "file"; size = 2000;
              lfs = { oid = "jkl012"; size = 2000; }; }
            { path = "model-fp16.safetensors"; type = "file"; size = 5000;
              lfs = { oid = "mno345"; size = 5000; }; }
          ];

          lfsFiles = builtins.filter (f: f ? lfs) mockFiles;
          nonDirFiles = builtins.filter (f: (f.type or "") != "directory") mockFiles;

          # Test 1: include filter with wildcard matching subdirectory paths
          includeQ5 = nix-hug-lib.applyFilter { include = [ ".*Q5_K_S.*" ]; } lfsFiles;
          # Test 2: include filter with *.gguf should match across directories
          includeGguf = nix-hug-lib.applyFilter { include = [ ".*\\.gguf" ]; } lfsFiles;
          # Test 3: include filter for specific subdir pattern
          includeSubdir = nix-hug-lib.applyFilter { include = [ "Q5_K_S/.*" ]; } lfsFiles;
          # Test 4: exclude filter on subdirectory paths
          excludeQ5 = nix-hug-lib.applyFilter { exclude = [ ".*Q5_K_S.*" ]; } lfsFiles;
          # Test 5: file filter with exact subdirectory path
          fileFilter = nix-hug-lib.applyFilter { files = [ "Q5_K_S/model-00001-of-00003.gguf" ]; } lfsFiles;
          # Test 6: null filter returns all files
          noFilter = nix-hug-lib.applyFilter null lfsFiles;
          # Test 7: directory entries are not LFS files (sanity check)
          dirNotLfs = builtins.length (builtins.filter (f: f ? lfs && (f.type or "") == "directory") mockFiles);

          getPaths = files: map (f: f.path) files;

          assert1 = builtins.length includeQ5 == 3
            || throw "FAIL: include *Q5_K_S* should match 3 LFS files, got ${toString (builtins.length includeQ5)}: ${builtins.toJSON (getPaths includeQ5)}";
          assert2 = builtins.length includeGguf == 4
            || throw "FAIL: include *.gguf should match 4 LFS files, got ${toString (builtins.length includeGguf)}: ${builtins.toJSON (getPaths includeGguf)}";
          assert3 = builtins.length includeSubdir == 3
            || throw "FAIL: include Q5_K_S/* should match 3 LFS files, got ${toString (builtins.length includeSubdir)}: ${builtins.toJSON (getPaths includeSubdir)}";
          assert4 = builtins.length excludeQ5 == 2
            || throw "FAIL: exclude *Q5_K_S* should leave 2 LFS files, got ${toString (builtins.length excludeQ5)}: ${builtins.toJSON (getPaths excludeQ5)}";
          assert5 = builtins.length fileFilter == 1
            || throw "FAIL: file filter should match 1 file, got ${toString (builtins.length fileFilter)}: ${builtins.toJSON (getPaths fileFilter)}";
          assert6 = builtins.length noFilter == 5
            || throw "FAIL: null filter should return all 5 LFS files, got ${toString (builtins.length noFilter)}";
          assert7 = dirNotLfs == 0
            || throw "FAIL: directory entries should not have lfs attribute";
          assert8 = builtins.length nonDirFiles == 8
            || throw "FAIL: filtering directories should leave 8 files, got ${toString (builtins.length nonDirFiles)}";
        in
          assert assert1;
          assert assert2;
          assert assert3;
          assert assert4;
          assert assert5;
          assert assert6;
          assert assert7;
          assert assert8;
          pkgs.runCommand "filter-subdir-test" { } ''
            echo "=== applyFilter subdirectory test ==="
            echo "All Nix-level assertions passed:"
            echo "  1. include *Q5_K_S* matches 3 subdirectory LFS files"
            echo "  2. include *.gguf matches all 4 LFS gguf files across directories"
            echo "  3. include Q5_K_S/* matches 3 files in specific subdirectory"
            echo "  4. exclude *Q5_K_S* leaves 2 non-Q5 LFS files"
            echo "  5. file filter matches exact subdirectory path"
            echo "  6. null filter returns all LFS files"
            echo "  7. directory entries never have lfs attribute"
            echo "  8. type!=directory filter excludes directory entries"
            echo "filterSubdirTest passed!" | tee $out
          '';

        # Test: CLI package is available and prints help
        cliTest = pkgs.runCommand "cli-test" { } ''
          echo "=== CLI test ==="

          # CLI sources common.sh which creates cache dirs under $HOME;
          # provide a writable HOME for the sandbox
          export HOME=$(mktemp -d)

          # The CLI package must exist and be executable
          test -x ${nix-hug.packages.${system}.default}/bin/nix-hug || {
            echo "FAIL: nix-hug binary not found"; exit 1;
          }

          # --version must print something
          version=$(${nix-hug.packages.${system}.default}/bin/nix-hug --version)
          echo "Version: $version"
          echo "$version" | grep -q "nix-hug" || { echo "FAIL: unexpected version output"; exit 1; }

          # --help must mention the new commands
          help=$(${nix-hug.packages.${system}.default}/bin/nix-hug --help)
          echo "$help" | grep -q "export" || { echo "FAIL: --help missing export"; exit 1; }
          echo "$help" | grep -q "import" || { echo "FAIL: --help missing import"; exit 1; }
          echo "$help" | grep -q "store"  || { echo "FAIL: --help missing store"; exit 1; }

          echo "CLI test passed!" | tee $out
        '';
      };

      # Expose for manual inspection: nix build ./test#tiny-llama
      packages.${system} = {
        inherit tiny-llama model-cache;
      };
    };
}
