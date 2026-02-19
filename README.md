# nix-hug

Declarative Hugging Face model and dataset management for Nix.

## Installation

```bash
# Add to your flake inputs
{
  inputs.nix-hug.url = "github:longregen/nix-hug";
}
```

## Usage

### As a flake dependency

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    nix-hug.url = "github:longregen/nix-hug";
  };

  outputs = { nixpkgs, nix-hug, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      nix-hug-lib = nix-hug.lib.${system};

      my-model = nix-hug-lib.fetchModel {
        url = "stas/tiny-random-llama-2";
        rev = "3579d71fd57e04f5a364d824d3a2ec3e913dbb67";
        fileTreeHash = "sha256-mD+VYvxsLFH7+jiumTZYcE3f3kpMKeimaR0eElkT7FI=";
      };

      model-cache = nix-hug-lib.buildCache {
        models = [ my-model ];
        hash = "sha256-psQcpC+BAfAFpu7P5T1+VXAPSytrq4GcfqiY2KWAU8g=";
      };
    in {
      packages.${system} = {
        inherit my-model model-cache;
        default = nix-hug.packages.${system}.default;  # CLI
      };

      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [ nix-hug.packages.${system}.default ];
      };
    };
}
```

Use `nix-hug fetch` to generate the `fetchModel` expression with correct hashes, then paste it into your flake.

### Fetch a model

```bash
# Download Mistral 7B Instruct model (safetensors only)
nix-hug fetch mistralai/Mistral-7B-Instruct-v0.3 --include '*.safetensors'
```

This outputs a Nix expression you can use in your configuration:

```nix
nix-hug-lib.fetchModel {
  url = "mistralai/Mistral-7B-Instruct-v0.3";
  rev = "abc123...";
  filters = { include = [ ".*\\.safetensors" ]; };
  fileTreeHash = "sha256-def456...";
}
```

```bash
# Download Google's BERT base model
nix-hug fetch google-bert/bert-base-uncased
```

This outputs:

```nix
nix-hug-lib.fetchModel {
  url = "google-bert/bert-base-uncased";
  rev = "xyz789...";
  fileTreeHash = "sha256-uvw456...";
}
```

### Fetch a dataset

Datasets work the same way. The CLI auto-detects whether a repository is a model or dataset by querying the Hugging Face API:

```bash
nix-hug fetch rajpurkar/squad --include '*.json'
```

This outputs a `fetchDataset` expression:

```nix
nix-hug-lib.fetchDataset {
  url = "rajpurkar/squad";
  rev = "abc123...";
  filters = { include = [ ".*\\.json" ]; };
  fileTreeHash = "sha256-def456...";
}
```

You can also use explicit dataset URL formats (`datasets/org/repo`, `hf-datasets:org/repo`, or the full `https://huggingface.co/datasets/org/repo` URL) to skip the auto-detection.

### Create a HuggingFace cache

The `buildCache` function creates a HuggingFace Hub-compatible cache that works with transformers. It accepts both `models` and `datasets`:

```nix
# In your flake.nix
let
  mistral-model = nix-hug.lib.${system}.fetchModel {
    url = "mistralai/Mistral-7B-Instruct-v0.3";
    rev = "abc123...";
    filters = { include = [ ".*\\.safetensors" ]; };
    fileTreeHash = "sha256-def456...";
  };

  bert-model = nix-hug.lib.${system}.fetchModel {
    url = "google-bert/bert-base-uncased";
    rev = "xyz789...";
    fileTreeHash = "sha256-uvw456...";
  };

  squad-dataset = nix-hug.lib.${system}.fetchDataset {
    url = "rajpurkar/squad";
    rev = "ghi012...";
    filters = { include = [ ".*\\.json" ]; };
    fileTreeHash = "sha256-jkl345...";
  };

  # Create cache with models and datasets
  model-cache = nix-hug.lib.${system}.buildCache {
    models = [ mistral-model bert-model ];
    datasets = [ squad-dataset ];
    hash = "sha256-cache-hash...";
  };
```

Use the cache with Python:

```bash
export HF_HUB_CACHE=/nix/store/...-hf-hub-cache

python -c "
from transformers import AutoModelForCausalLM, AutoTokenizer

# Load Mistral model from cache
model = AutoModelForCausalLM.from_pretrained('mistralai/Mistral-7B-Instruct-v0.3')
tokenizer = AutoTokenizer.from_pretrained('mistralai/Mistral-7B-Instruct-v0.3')

# Generate text
inputs = tokenizer('Hello, how are you?', return_tensors='pt')
outputs = model.generate(**inputs, max_length=50)
print(tokenizer.decode(outputs[0], skip_special_tokens=True))
"
```

The cache structure is compatible with HuggingFace transformers and works offline.

### Other commands

```bash
# List model files without downloading
nix-hug ls mistralai/Mistral-7B-Instruct-v0.3

# Download a dataset
nix-hug fetch rajpurkar/squad --include '*.json'

# Download with filters
nix-hug fetch google-bert/bert-base-uncased --include '*.safetensors'
```

## Commands

Global options (apply to all commands):
- `--debug`: Enable verbose logging (shows internal steps, API calls, hash discovery)
- `--version`: Show version information
- `--help`: Show help message

### `fetch` - Download Models or Datasets
Downloads Hugging Face models or datasets and generates Nix expressions.

```bash
nix-hug fetch <model-or-dataset-url> [options]
```

Options:
- `--ref REF`: Use specific git reference (default: main)
- `--include PATTERN`: Include files matching glob pattern
- `--exclude PATTERN`: Exclude files matching glob pattern
- `--file FILENAME`: Include specific file by name
### `ls` - List Repository Contents
Lists files in a model or dataset repository without downloading. Automatically detects whether the repository is a model or dataset.

```bash
nix-hug ls <model-or-dataset-url> [options]
```

Options:
- `--ref REF`: Use specific git reference (default: main)
- `--include PATTERN`: Include files matching glob pattern
- `--exclude PATTERN`: Exclude files matching glob pattern
- `--file FILENAME`: Include specific file by name

Examples:
```bash
# List model files
nix-hug ls mistralai/Mistral-7B-Instruct-v0.3

# List dataset files
nix-hug ls rajpurkar/squad

# List with filters
nix-hug ls stanfordnlp/imdb --include '*.parquet'

# List specific file
nix-hug ls google-bert/bert-base-uncased --file config.json
```

### `export` - Persist Models to Local Binary Cache
Fetches a model/dataset and copies the store path to a persistent local Nix binary cache. Models survive `nix-collect-garbage` and can be restored without re-downloading.

```bash
nix-hug export <model-or-dataset-url> [options]
```

Options:
- `--ref REF`: Use specific git reference (default: main)
- `--include PATTERN`: Include files matching glob pattern
- `--exclude PATTERN`: Exclude files matching glob pattern
- `--file FILENAME`: Include specific file by name

Examples:
```bash
nix-hug export openai-community/gpt2
nix-hug export openai-community/gpt2 --include '*.safetensors'
```

### `import` - Restore from Persistent Storage
Restores a previously exported model/dataset from the persistent binary cache back into the Nix store.

```bash
nix-hug import <model-or-dataset-url> [options]
nix-hug import --all
```

Options:
- `--ref REF`: Match a specific revision
- `--all`: Import all entries from the manifest
- `--yes`, `-y`, `--no-check-sigs`: Skip the trust confirmation prompt (required in non-interactive contexts)

Import uses `--no-check-sigs` when copying from the local binary cache, since paths are not signed. An interactive confirmation prompt is shown unless one of the skip flags is passed.

Examples:
```bash
nix-hug import openai-community/gpt2
nix-hug import --all
nix-hug import --all --yes
```

### `store` - Manage Persistent Storage

```bash
nix-hug store ls      # List all persisted models with validity status
nix-hug store path    # Print the configured persist directory
```

## Persistent Storage

Models fetched by nix-hug live in `/nix/store/`. When Nix garbage-collects, these paths are evicted and must be re-downloaded. The persist feature lets you save models to a directory and restore them without re-downloading.

### Configuration

Create `~/.config/nix-hug/config` (or `$XDG_CONFIG_HOME/nix-hug/config` if `XDG_CONFIG_HOME` is set):

```
persist_dir=/persist/models
auto_persist=false
```

Or use environment variables (these take priority over the config file):

```bash
export NIX_HUG_PERSIST_DIR=/persist/models
export NIX_HUG_AUTO_PERSIST=true
```

### Workflow

```bash
# 1. Export a model to persistent storage
nix-hug export stas/tiny-random-llama-2

# 2. Check what's persisted
nix-hug store ls

# 3. After garbage collection, restore it
nix-hug import stas/tiny-random-llama-2

# Or restore everything at once
nix-hug import --all
```

### Auto-persist

When `auto_persist=true`, `fetch` integrates with persistent storage transparently:

- **Before building**: checks the manifest for a matching model and restores it from the binary cache if the store path was garbage-collected
- **After building**: automatically exports the store path to persistent storage

This means models survive GC with zero extra user action:

```bash
export NIX_HUG_PERSIST_DIR=/persist/models
export NIX_HUG_AUTO_PERSIST=true

# First fetch downloads and auto-exports
nix-hug fetch openai-community/gpt2

# After nix-collect-garbage, fetch auto-imports from persist dir
nix-hug fetch openai-community/gpt2
```

## URL Formats

Models:
- `https://huggingface.co/mistralai/Mistral-7B-Instruct-v0.3`
- `hf:mistralai/Mistral-7B-Instruct-v0.3`
- `mistralai/Mistral-7B-Instruct-v0.3`

Datasets:
- `https://huggingface.co/datasets/rajpurkar/squad`
- `hf-datasets:rajpurkar/squad`
- `datasets/rajpurkar/squad`
- `rajpurkar/squad` (the CLI queries the Hugging Face API to auto-detect whether a bare `org/repo` is a model or dataset)

## Development

```bash
nix develop
./cli/nix-hug --help
```
