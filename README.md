# nix-hug

Declarative Hugging Face model management for Nix.

## Quick Start

Add a model to your Nix development environment:

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-hug.url = "github:longregen/nix-hug";
  };

  outputs = { self, nixpkgs, nix-hug }: {
    devShells.x86_64-linux.default = 
      let
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        hug = nix-hug.lib.x86_64-linux;
        
        gpt2 = hug.fetchModel { 
          url = "openai-community/gpt2";
          hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        };
      in
      pkgs.mkShell {
        buildInputs = with pkgs; [
          (python3.withPackages (ps: with ps; [
            transformers
            torch
          ]))
        ];
        
        shellHook = ''
          export HF_HOME=${hug.buildCache [gpt2]}
          echo "Model available at: $HF_HOME"
        '';
      };
  };
}
```

First build will fail with the correct hash. Update and rebuild:

```bash
$ nix develop
error: hash mismatch in fixed-output derivation
  specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
  got:       sha256-x1234567890abcdef1234567890abcdef123456789=

# Update the hash and rebuild
$ nix develop
Model available at: /nix/store/...-hf-home
```

## Using the CLI

For a more convenient workflow, use the CLI to manage models:

```bash
# Install the CLI
$ nix profile install github:longregen/nix-hug

# Add a model to your project
$ nix-hug add openai-community/gpt2
Downloaded to /nix/store/abc...-hf-model--openai-community--gpt2--base
Added to hug.lock with hash sha256-x1234567890...

# List available models
$ nix-hug ls openai-community/gpt2
Files in openai-community/gpt2:
  model.safetensors    523 MB  [LFS]
  pytorch_model.bin    523 MB  [LFS]
  config.json          1.2 KB
  ...
```

With lock file, your flake becomes simpler:

```nix
let
  hug = nix-hug.lib.x86_64-linux.withLock ./hug.lock;
  gpt2 = hug.fetchModel { url = "openai-community/gpt2"; };
in
  # ... rest of configuration
```

## Filtering Downloads

Download only the files you need:

```bash
# Only safetensors format
$ nix-hug add microsoft/phi-2 --filter safetensors

# Only specific files  
$ nix-hug add bert-base-uncased \
    --file config.json \
    --file model.safetensors \
    --file tokenizer.json

# Exclude certain patterns
$ nix-hug add EleutherAI/gpt-j-6B --exclude '*.bin'
```

In Nix:

```nix
# Using filter presets
phi2-safe = hug.fetchModel {
  url = "microsoft/phi-2";
  filters = hug.filters.safetensors;
};

# Custom filters
phi2-custom = hug.fetchModel {
  url = "microsoft/phi-2";
  filters = {
    include = ["*.safetensors" "*.onnx"];
  };
};

# Specific files only
bert-minimal = hug.fetchModel {
  url = "bert-base-uncased";
  files = ["config.json" "model.safetensors" "tokenizer.json"];
};
```

## Working with Private Models

For gated or private models, set your Hugging Face token:

```bash
# Via environment
$ HF_TOKEN=hf_your_token_here nix-hug add meta-llama/Llama-2-7b-hf

# Or export for session
$ export HF_TOKEN=hf_your_token_here
$ nix-hug add meta-llama/Llama-2-7b-hf
```

**Important**: Never put tokens in Nix files. They would be world-readable in `/nix/store`.

## Version Control

Pin models to specific commits or tags:

```bash
# Specific commit
$ nix-hug add openai-community/gpt2 --rev e7da7f221d5bf496a48136c0cd264e630fe9fcc8

# Tag or branch
$ nix-hug add openai-community/gpt2 --ref v1.0
```

In Nix:

```nix
gpt2-pinned = hug.fetchModel {
  url = "openai-community/gpt2";
  rev = "e7da7f221d5bf496a48136c0cd264e630fe9fcc8";
};
```

## Complete Example

Here's a full example creating a Python environment with multiple models:

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-hug.url = "github:longregen/nix-hug";
  };

  outputs = { self, nixpkgs, nix-hug }: 
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      
      # Load hug library with lock file
      hug = nix-hug.lib.${system}.withLock ./hug.lock;
      
      # Define models
      models = {
        gpt2 = hug.fetchModel { url = "openai-community/gpt2"; };
        bert = hug.fetchModel { 
          url = "google-bert/bert-base-uncased";
          filters = hug.filters.safetensors;
        };
        t5 = hug.fetchModel {
          url = "google-t5/t5-small";
          files = ["config.json" "model.safetensors" "tokenizer.json"];
        };
      };
      
      # Build combined cache
      modelCache = hug.buildCache (builtins.attrValues models);
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = with pkgs; [
          nix-hug.packages.${system}.default  # CLI tool
          (python3.withPackages (ps: with ps; [
            transformers
            torch
            jupyter
          ]))
        ];
        
        shellHook = ''
          export HF_HOME=${modelCache}
          echo "Models available:"
          echo "  - GPT-2: ${models.gpt2}"
          echo "  - BERT:  ${models.bert}" 
          echo "  - T5:    ${models.t5}"
          
          echo ""
          echo "Python environment ready. Run 'jupyter notebook' to start."
        '';
      };
    };
}
```

## Lock File Structure

The `hug.lock` file stores repository metadata and variant information to enable efficient HuggingFace cache population and avoid redundant API calls:

```json
{
  "version": 1,
  "models": {
    "openai-community/gpt2": {
      "repo": {
        "lastUpdated": "2025-06-20T15:37:51.933339+00:00Z",
        "refs": {
          "main": "7fe295d8bc8fbac8041b60ab351882634165517f"
        },
        "revisions": {
          "7fe295d8bc8fbac8041b60ab351882634165517f": {
            "lastUpdated": "2025-06-20T15:37:51.933339+00:00Z",
            "repo_files": {
              "config.json": {
                "hash": "69911b0f0c375d13b611d1334c0b8d7d259e1640",
                "lfs": false,
                "size": 1287
              },
              "model.safetensors": {
                "hash": "d15fa97c56df5c66fe893cae143d39e16a8663ec",
                "lfs": true,
                "size": 2472368
              }
            }
          }
        }
      },
      "variants": {
        "base": {
          "hash": "sha256-NfzNLEJhHbZn/a5fmTcLpZhIupPPVzDa7muPQYHqC/w=",
          "rev": "7fe295d8bc8fbac8041b60ab351882634165517f",
          "ref": "main",
          "lastUpdated": "2025-06-20T15:37:51.933339+00:00Z",
          "filtered_files": ["config.json", "model.safetensors"],
          "storePath": "/nix/store/abc123...-hf-model--openai-community--gpt2--base"
        }
      }
    }
  }
}
```

## How It Works

1. **Efficient Caching**: Models are stored in `/nix/store` as Fixed Output Derivations (FODs), surviving nixpkgs updates.

2. **Smart Downloads**: Only downloads files matching your filters. Non-LFS files (configs, tokenizers) are always included.

3. **Lock File**: `hug.lock` stores repository metadata and variant hashes, to populate a cache for Hugging Face.

4. **Git Integration**: Uses native Git with LFS support (requires Nix ≥2.26) for full version control capabilities.

## Requirements

- Nix ≥2.26 (for Git LFS support)
- Hugging Face account (for private/gated models)

## License

MIT
