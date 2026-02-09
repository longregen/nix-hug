{
  description = "nix-hug standalone integration test";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    nix-hug.url = "path:..";
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
