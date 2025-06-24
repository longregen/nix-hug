{
  description = "nix-hug - Declarative Hugging Face model management for Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      forAllSystems = f: nixpkgs.lib.genAttrs flake-utils.lib.defaultSystems f;
      
      mkCLI = pkgs: pkgs.stdenv.mkDerivation {
        pname = "nix-hug";
        version = "1.0.1";
        
        src = pkgs.lib.fileset.toSource {
          root = ./.;
          fileset = pkgs.lib.fileset.unions [
            ./cli/nix-hug
            ./cli/completion.bash
            ./cli/lib/common.sh
            ./cli/lib/commands.sh
            ./cli/lib/hash.sh
            ./cli/lib/nix-expr.sh
            ./cli/lib/ui.sh
            ./lib/default.nix
          ];
        };
        
        nativeBuildInputs = with pkgs; [ makeWrapper ];
        buildInputs = with pkgs; [ bash jq nix cacert curl ];
        
        installPhase = ''
          mkdir -p $out/bin $out/share/nix-hug/lib $out/share/bash-completion/completions
          
          cp cli/nix-hug $out/bin/
          chmod +x $out/bin/nix-hug
          
          cp lib/default.nix $out/share/nix-hug/lib/
          cp cli/lib/common.sh $out/share/nix-hug/lib/
          cp cli/lib/commands.sh $out/share/nix-hug/lib/
          cp cli/lib/hash.sh $out/share/nix-hug/lib/
          cp cli/lib/nix-expr.sh $out/share/nix-hug/lib/
          cp cli/lib/ui.sh $out/share/nix-hug/lib/
          
          cp cli/completion.bash $out/share/bash-completion/completions/nix-hug
          
          wrapProgram $out/bin/nix-hug \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.nix pkgs.jq pkgs.curl ]} \
            --set NIX_HUG_LIB_DIR $out/share/nix-hug/lib \
            --set NIX_HUG_FLAKE_PATH ${self}
        '';
        
        meta = with pkgs.lib; {
          description = "Declarative Hugging Face model management for Nix";
          longDescription = ''
            nix-hug is a tool for managing Hugging Face models in Nix, providing
            reproducible model fetching and caching. It supports downloading models
            with specific revisions and creation of offline caches.
          '';
          homepage = "https://github.com/longregen/nix-hug";
          changelog = "https://github.com/longregen/nix-hug/releases/tag/v1.0.1";
          license = licenses.mit;
          platforms = platforms.all;
          mainProgram = "nix-hug";
        };
      };
      
    in
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        packages = {
          default = mkCLI pkgs;
          nix-hug = mkCLI pkgs;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            nix
            jq
            bash
            shellcheck
            nixpkgs-fmt
            curl
          ];
          
          shellHook = ''
            export NIX_HUG_LIB_DIR=$PWD/cli/lib
            export PATH=$PWD/cli:$PATH
          '';
        };

        apps = {
          default = {
            type = "app";
            program = "${self.packages.${system}.default}/bin/nix-hug";
          };
        };
      }
    ) // {
      lib = forAllSystems (system: import ./lib { pkgs = nixpkgs.legacyPackages.${system}; });
      
      checks = forAllSystems (system: let
        pkgs = nixpkgs.legacyPackages.${system};
        nix-hug-lib = import ./lib { inherit pkgs; };
        
        # Fetch the tiny-random-llama-2 model
        tiny-llama = nix-hug-lib.fetchModel {
          url = "stas/tiny-random-llama-2";
          rev = "main";
          repoInfoHash = "sha256-UzhrnF4pogr533B7L0z7x0bPvEBqrrL8TWGe7NeHtIc=";
          fileTreeHash = "sha256-JRpzHFxfi3/HySzxEjdpqtEdVydSOGIFHQw2bcjCE0M=";
          derivationHash = "sha256-fVGaNkfWNCtSUJpB6gh+heTt+R/YMoa3xsyZ10x+n7c=";
        };

        # Create cache with the model
        model-cache = nix-hug-lib.buildCache {
          models = [ tiny-llama ];
          hash = "sha256-k7hdnAXEaP1iuJQhTX0Svx/Zame9zkOvmB5KvkZtH5A=";
        };
      in {
        # Quick build-time test
        buildCacheTest = pkgs.runCommand "nix-hug-buildcache-test" {
          buildInputs = with pkgs; [
            (python3.withPackages (ps: with ps; [ transformers torch ]))
          ];
          # Ensure network isolation for the test
          __noChroot = false;
        } ''
          echo "Testing buildCache with tiny-random-llama-2 model..." | tee $out

          export HF_HUB_CACHE=${model-cache}
          export TRANSFORMERS_OFFLINE=1
          
          echo "" | tee -a $out
          echo "HF_HUB_CACHE: $HF_HUB_CACHE" | tee -a $out
          echo "" | tee -a $out
          echo "Cache contents:" | tee -a $out
          find $HF_HUB_CACHE -type f | head -20 | tee -a $out
          
          echo "" | tee -a $out
          echo "Running Python test script..." | tee -a $out
          
          cat > test-cache.py << 'EOF'
from transformers import AutoModelForCausalLM, AutoTokenizer
import os

print(f"HF_HUB_CACHE: {os.environ.get('HF_HUB_CACHE')}")
print(f"Cache contents:")
cache_dir = os.environ.get('HF_HUB_CACHE')
if cache_dir:
    for root, dirs, files in os.walk(cache_dir):
        level = root.replace(cache_dir, "").count(os.sep)
        indent = ' ' * 2 * level
        print(f"{indent}{os.path.basename(root)}/")
        subindent = ' ' * 2 * (level + 1)
        for file in files[:5]:  # Limit files shown
            print(f"{subindent}{file}")

print("\nLoading model from cache...")
# Find the snapshot directory
snapshot_dir = None
models_dir = os.path.join(cache_dir, "hub", "models--stas--tiny-random-llama-2", "snapshots")
if os.path.exists(models_dir):
    snapshots = os.listdir(models_dir)
    if snapshots:
        snapshot_dir = os.path.join(models_dir, snapshots[0])
        print(f"Using snapshot directory: {snapshot_dir}")

if snapshot_dir:
    model = AutoModelForCausalLM.from_pretrained(snapshot_dir, local_files_only=True)
    tokenizer = AutoTokenizer.from_pretrained(snapshot_dir, local_files_only=True)
else:
    print("ERROR: Could not find snapshot directory")
    exit(1)

print("Model loaded successfully!")
print(f"Model type: {type(model)}")
print(f"Tokenizer type: {type(tokenizer)}")
EOF
          
          python3 test-cache.py 2>&1 | tee -a $out
          
          echo "" | tee -a $out
          echo "buildCache test passed!" | tee -a $out
        '';
        
        # NixOS VM test with proper isolation
        buildCacheVMTest = pkgs.nixosTest {
          name = "nix-hug-buildcache-vm-test";
          
          nodes.machine = { config, pkgs, ... }: {
            virtualisation.memorySize = 2048;
            virtualisation.diskSize = 8192;
            
            # No network access
            virtualisation.vlans = [];
            
            environment.systemPackages = with pkgs; [
              (python3.withPackages (ps: with ps; [ transformers torch ]))
            ];
            
            # Pre-build the cache in the VM image
            system.extraDependencies = [ model-cache ];
          };
          
          testScript = ''
start_all()
machine.wait_for_unit("multi-user.target")

print("Testing buildCache in isolated VM environment...")

# Verify no network access
machine.fail("ping -c 1 8.8.8.8")
machine.fail("ping -c 1 huggingface.co")

print("Network isolation confirmed")

# Create test script
machine.succeed("""cat > /tmp/test-cache.py << 'EOF'
from transformers import AutoModelForCausalLM, AutoTokenizer
import os
import sys

print(f"HF_HUB_CACHE: {os.environ.get('HF_HUB_CACHE')}")
print(f"TRANSFORMERS_OFFLINE: {os.environ.get('TRANSFORMERS_OFFLINE')}")

cache_dir = os.environ.get('HF_HUB_CACHE')
if not cache_dir:
    print("ERROR: HF_HUB_CACHE not set")
    sys.exit(1)

print("\\nCache contents:")
for root, dirs, files in os.walk(cache_dir):
    level = root.replace(cache_dir, "").count(os.sep)
    indent = ' ' * 2 * level
    print(f"{indent}{os.path.basename(root)}/")
    subindent = ' ' * 2 * (level + 1)
    for file in files[:5]:
        print(f"{subindent}{file}")

print("\\nLoading model from cache...")
# Find the snapshot directory
snapshot_dir = None
models_dir = os.path.join(cache_dir, "hub", "models--stas--tiny-random-llama-2", "snapshots")
if os.path.exists(models_dir):
    snapshots = os.listdir(models_dir)
    if snapshots:
        snapshot_dir = os.path.join(models_dir, snapshots[0])
        print(f"Using snapshot directory: {snapshot_dir}")

if snapshot_dir:
    try:
        model = AutoModelForCausalLM.from_pretrained(snapshot_dir, local_files_only=True)
        tokenizer = AutoTokenizer.from_pretrained(snapshot_dir, local_files_only=True)
        print("Model loaded successfully!")
        print(f"Model type: {type(model)}")
        print(f"Tokenizer type: {type(tokenizer)}")
    except Exception as e:
        print(f"ERROR loading model: {e}")
        sys.exit(1)
else:
    print("ERROR: Could not find snapshot directory")
    sys.exit(1)
EOF""")

# Run the test with proper environment
output = machine.succeed("""
  HF_HUB_CACHE=${model-cache} TRANSFORMERS_OFFLINE=1 python3 /tmp/test-cache.py
""")

print(output)

# Verify success
machine.succeed("echo '" + output + "' | grep -q 'Model loaded successfully!'")

print("VM test passed - model loaded successfully in network isolation!")
          '';
        };
      });
    };
}
