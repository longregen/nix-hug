{
  description = "nix-hug - Declarative Hugging Face model management for Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      mkCLI =
        pkgs:
        pkgs.stdenv.mkDerivation {
          pname = "nix-hug";
          version = "5.1.0";

          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              ./cli/nix-hug
              ./cli/completion.bash
              ./cli/completion.fish
              ./cli/completion.zsh
              ./cli/lib/common.sh
              ./cli/lib/commands.sh
              ./cli/lib/hash.sh
              ./cli/lib/nix-expr.sh
              ./cli/lib/ui.sh
              ./lib/default.nix
            ];
          };

          nativeBuildInputs = with pkgs; [ makeWrapper ];
          buildInputs = with pkgs; [
            bash
            jq
            nix
            cacert
            curl
            git
          ];

          installPhase = ''
            mkdir -p $out/bin $out/share/nix-hug/lib \
              $out/share/bash-completion/completions \
              $out/share/fish/vendor_completions.d \
              $out/share/zsh/site-functions

            cp cli/nix-hug $out/bin/
            chmod +x $out/bin/nix-hug

            cp lib/default.nix $out/share/nix-hug/lib/
            cp cli/lib/common.sh $out/share/nix-hug/lib/
            cp cli/lib/commands.sh $out/share/nix-hug/lib/
            cp cli/lib/hash.sh $out/share/nix-hug/lib/
            cp cli/lib/nix-expr.sh $out/share/nix-hug/lib/
            cp cli/lib/ui.sh $out/share/nix-hug/lib/

            cp cli/completion.bash $out/share/bash-completion/completions/nix-hug
            cp cli/completion.fish $out/share/fish/vendor_completions.d/nix-hug.fish
            cp cli/completion.zsh $out/share/zsh/site-functions/_nix-hug

            wrapProgram $out/bin/nix-hug \
              --prefix PATH : ${
                pkgs.lib.makeBinPath [
                  pkgs.nix
                  pkgs.jq
                  pkgs.curl
                  pkgs.git
                ]
              } \
              --set NIX_HUG_LIB_DIR $out/share/nix-hug/lib \
              --set NIX_HUG_FLAKE_PATH ${self}
          '';

          meta = with pkgs.lib; {
            description = "Declarative Hugging Face model management for Nix";
            longDescription = "Manages Hugging Face models in Nix with reproducible fetching, caching, and offline builds.";
            homepage = "https://github.com/longregen/nix-hug";
            changelog = "https://github.com/longregen/nix-hug/releases/tag/v5.0.0";
            license = licenses.mit;
            platforms = platforms.all;
            mainProgram = "nix-hug";
          };
        };

    in
    {
      packages = forAllSystems (
        pkgs:
        let
          nix-hug = mkCLI pkgs;
        in
        {
          inherit nix-hug;
          default = nix-hug;
        }
      );

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          buildInputs = with pkgs; [
            nix
            jq
            bash
            shellcheck
            nixpkgs-fmt
            curl
            (mkCLI pkgs)
          ];

          shellHook = ''
            export NIX_HUG_LIB_DIR=$PWD/cli/lib
            export PATH=$PWD/cli:$PATH
          '';
        };
      });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = "${mkCLI pkgs}/bin/nix-hug";
          meta.description = "Declarative Hugging Face model management for Nix";
        };
      });

      lib = forAllSystems (pkgs: import ./lib { inherit pkgs; });

      checks = forAllSystems (
        pkgs:
        let
          nix-hug-lib = import ./lib { inherit pkgs; };

          tiny-llama = nix-hug-lib.fetchModel {
            url = "stas/tiny-random-llama-2";
            rev = "3579d71fd57e04f5a364d824d3a2ec3e913dbb67";
            fileTreeHash = "sha256-mD+VYvxsLFH7+jiumTZYcE3f3kpMKeimaR0eElkT7FI=";
          };

          model-cache = nix-hug-lib.buildCache {
            models = [ tiny-llama ];
          };
        in
        {
          buildCacheTest =
            pkgs.runCommand "nix-hug-buildcache-test"
              {
                buildInputs = [
                  (pkgs.python3.withPackages (
                    ps: with ps; [
                      transformers
                      torch
                    ]
                  ))
                ];
              }
              ''
                export HF_HUB_CACHE=${model-cache}
                export TRANSFORMERS_OFFLINE=1
                python3 -c "
                from transformers import AutoModelForCausalLM, AutoTokenizer
                import os
                cache = os.environ['HF_HUB_CACHE']
                snap = os.path.join(cache, 'models--stas--tiny-random-llama-2', 'snapshots')
                revs = os.listdir(snap)
                assert len(revs) == 1, f'Expected 1 snapshot, got {len(revs)}'
                path = os.path.join(snap, revs[0])
                model = AutoModelForCausalLM.from_pretrained(path, local_files_only=True)
                tok = AutoTokenizer.from_pretrained(path, local_files_only=True)
                print(f'Model: {type(model).__name__}, Tokenizer: {type(tok).__name__}')
                print('buildCache test passed!')
                " 2>&1 | tee $out
              '';

          buildCacheVMTest = pkgs.testers.nixosTest {
            name = "nix-hug-buildcache-vm-test";

            nodes.machine =
              { pkgs, ... }:
              {
                virtualisation = {
                  memorySize = 2048;
                  diskSize = 8192;
                };
                environment.systemPackages = [
                  (pkgs.python3.withPackages (
                    ps: with ps; [
                      transformers
                      torch
                    ]
                  ))
                  (mkCLI pkgs)
                ];
                system.extraDependencies = [
                  model-cache
                  tiny-llama
                ];
              };

            testScript = ''
              start_all()
              machine.wait_for_unit("multi-user.target")
              machine.fail("ping -c 1 8.8.8.8")
              machine.fail("ping -c 1 huggingface.co")

              machine.succeed("""cat > /tmp/test-cache.py << 'PYEOF'
              from transformers import AutoModelForCausalLM, AutoTokenizer
              import os, sys
              cache = os.environ.get('HF_HUB_CACHE')
              if not cache: print("ERROR: HF_HUB_CACHE not set"); sys.exit(1)
              snap = os.path.join(cache, 'models--stas--tiny-random-llama-2', 'snapshots')
              revs = os.listdir(snap)
              assert len(revs) == 1, f'Expected 1 snapshot, got {len(revs)}'
              path = os.path.join(snap, revs[0])
              model = AutoModelForCausalLM.from_pretrained(path, local_files_only=True)
              tok = AutoTokenizer.from_pretrained(path, local_files_only=True)
              print(f'Model: {type(model).__name__}, Tokenizer: {type(tok).__name__}')
              print('Model loaded successfully!')
              PYEOF""")

              output = machine.succeed("HF_HUB_CACHE=${model-cache} TRANSFORMERS_OFFLINE=1 python3 /tmp/test-cache.py")
              assert "Model loaded successfully!" in output
              print("buildCache VM test passed!")

              # --- Round-trip test: export → verify → import → verify ---

              # Phase 1: Export from nix store to HF cache (offline, no network)
              machine.succeed("nix-hug export stas/tiny-random-llama-2 2>&1")

              # Phase 2: Verify blobs+symlinks structure
              machine.succeed("test -d /root/.cache/huggingface/hub/models--stas--tiny-random-llama-2/blobs")
              machine.succeed("test -f /root/.cache/huggingface/hub/models--stas--tiny-random-llama-2/refs/main")
              # Snapshot files must be symlinks pointing into blobs/
              machine.succeed("test -L /root/.cache/huggingface/hub/models--stas--tiny-random-llama-2/snapshots/*/config.json")

              # Phase 3: Verify Python/transformers loads from exported HF cache
              machine.succeed("""cat > /tmp/test-export.py << 'PYEOF'
              from transformers import AutoModelForCausalLM, AutoTokenizer
              model = AutoModelForCausalLM.from_pretrained('stas/tiny-random-llama-2', local_files_only=True)
              tok = AutoTokenizer.from_pretrained('stas/tiny-random-llama-2', local_files_only=True)
              print('Export cache load OK!')
              PYEOF""")
              output = machine.succeed("HF_HUB_CACHE=/root/.cache/huggingface/hub TRANSFORMERS_OFFLINE=1 HF_HUB_OFFLINE=1 python3 /tmp/test-export.py")
              assert "Export cache load OK!" in output
              print("Export + HF cache load verified!")

              # Phase 4: Rename snapshot to a fake rev so import creates a NEW store path
              cache_dir = "/root/.cache/huggingface/hub/models--stas--tiny-random-llama-2"
              real_rev = machine.succeed(f"cat {cache_dir}/refs/main").strip()
              fake_rev = "0" * 40
              machine.succeed(f"mv {cache_dir}/snapshots/{real_rev} {cache_dir}/snapshots/{fake_rev}")
              machine.succeed(f"printf '%s' {fake_rev} > {cache_dir}/refs/main")

              # Phase 5: Import from the exported HF cache (creates new store path with fake rev)
              machine.succeed("HF_HUB_CACHE=/root/.cache/huggingface/hub nix-hug import stas/tiny-random-llama-2 2>&1")

              # Phase 6: Verify the new store path exists
              machine.succeed(f"nix-store --check-validity $(echo /nix/store/*-hf-model-stas-tiny-random-llama-2-{fake_rev})")
              print("Round-trip test passed!")
            '';
          };
        }
      );
    };
}
