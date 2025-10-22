# nix-hug 🤗

[![Build Status](https://github.com/longregen/nix-hug/actions/workflows/test.yml/badge.svg)](https://github.com/longregen/nix-hug/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Declarative Hugging Face model and dataset management for Nix.

## Key Features

- Content-addressed model fetching with hash verification
- HuggingFace Hub-compatible offline cache
- File filtering (download only what you need)
- Works with standard transformers library
- Reproducible builds

## Why nix-hug?

**Without nix-hug:**
- Manual downloads with `git lfs clone`
- No hash verification or reproducibility
- Manual cache management
- Difficult to version control model dependencies

**With nix-hug:**
- Generate Nix expressions with verified hashes
- Declarative model dependencies in `flake.nix`
- Automatic HuggingFace-compatible cache structure
- Content-addressed storage in Nix store

## Quick Start

Try without installing:

```bash
# List model files
nix run github:longregen/nix-hug -- ls mistralai/Mistral-7B-Instruct-v0.3

# Fetch a small model and generate Nix expression
nix run github:longregen/nix-hug -- fetch stas/tiny-random-llama-2
```

## Installation

Add to your flake inputs:

```nix
{
  inputs.nix-hug.url = "github:longregen/nix-hug";
}
```

Or run directly:

```bash
nix profile install github:longregen/nix-hug
```

## Usage

### Fetch a model

Download and generate Nix expression for a model:

```bash
# Download Mistral 7B Instruct (safetensors only)
nix-hug fetch mistralai/Mistral-7B-Instruct-v0.3 --include '*.safetensors'
```

Output:

```nix
nix-hug-lib.fetchModel {
  url = "mistralai/Mistral-7B-Instruct-v0.3";
  rev = "main";
  filters = { include = [ ".*\\.safetensors" ]; };
  repoInfoHash = "sha256-abc123...";
  fileTreeHash = "sha256-def456...";
  derivationHash = "sha256-ghi789...";
}
```

### Build a HuggingFace cache

The `buildCache` function creates a HuggingFace Hub-compatible cache:

```nix
# In your flake.nix
let
  mistral-model = nix-hug.lib.${system}.fetchModel {
    url = "mistralai/Mistral-7B-Instruct-v0.3";
    rev = "main";
    filters = { include = [ ".*\\.safetensors" ]; };
    repoInfoHash = "sha256-abc123...";
    fileTreeHash = "sha256-def456...";
    derivationHash = "sha256-ghi789...";
  };

  bert-model = nix-hug.lib.${system}.fetchModel {
    url = "google-bert/bert-base-uncased";
    rev = "main";
    repoInfoHash = "sha256-xyz789...";
    fileTreeHash = "sha256-uvw456...";
    derivationHash = "sha256-rst123...";
  };

  # Create cache with multiple models
  model-cache = nix-hug.lib.${system}.buildCache {
    models = [ mistral-model bert-model ];
    hash = "sha256-cache-hash...";
  };
in
# ... use model-cache in your packages
```

### Use the cache with Python

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

The cache works offline with `TRANSFORMERS_OFFLINE=1`.

## Commands

### `fetch` - Download and generate Nix expression

```bash
nix-hug fetch <model-or-dataset-url> [options]
```

**Options:**
- `--ref REF` - Git reference (default: main)
- `--include PATTERN` - Include files matching glob pattern
- `--exclude PATTERN` - Exclude files matching glob pattern
- `--file FILENAME` - Include specific file by name
- `--yes, -y` - Auto-confirm operations

**Examples:**

```bash
# Download Mistral 7B (safetensors only)
nix-hug fetch mistralai/Mistral-7B-Instruct-v0.3 --include '*.safetensors'

# Download BERT base model
nix-hug fetch google-bert/bert-base-uncased

# Download a dataset
nix-hug fetch rajpurkar/squad --include '*.json'
```

### `ls` - List repository contents

List files without downloading:

```bash
nix-hug ls <model-or-dataset-url> [options]
```

**Options:**
- `--ref REF` - Git reference (default: main)
- `--include PATTERN` - Filter files matching glob pattern
- `--exclude PATTERN` - Exclude files matching glob pattern
- `--file FILENAME` - Show specific file by name

**Examples:**

```bash
# List model files
nix-hug ls mistralai/Mistral-7B-Instruct-v0.3

# List dataset files
nix-hug ls rajpurkar/squad

# List with filters
nix-hug ls stanfordnlp/imdb --include '*.parquet'

# Show specific file
nix-hug ls google-bert/bert-base-uncased --file config.json
```

### `cache` - Manage local cache

```bash
# Clean expired cache entries
nix-hug cache clean

# Verify cache integrity
nix-hug cache verify

# Show cache statistics
nix-hug cache stats
```

Cache entries expire after 24 hours by default.

## URL Formats

**Models:**
- `https://huggingface.co/mistralai/Mistral-7B-Instruct-v0.3`
- `hf:mistralai/Mistral-7B-Instruct-v0.3`
- `mistralai/Mistral-7B-Instruct-v0.3`

**Datasets:**
- `https://huggingface.co/datasets/rajpurkar/squad`
- `hf-datasets:rajpurkar/squad`
- `datasets/rajpurkar/squad`
- `rajpurkar/squad`

## Comparison with Alternatives

| Feature | nix-hug | git-lfs clone | huggingface-cli |
|---------|---------|---------------|-----------------|
| Reproducible builds | ✅ | ❌ | ❌ |
| Declarative config | ✅ | ❌ | ❌ |
| Content addressing | ✅ | ❌ | ❌ |
| Hash verification | ✅ | ⚠️  | ⚠️  |
| Nix integration | ✅ | ❌ | ❌ |
| Offline cache | ✅ | ⚠️  | ⚠️  |
| File filtering | ✅ | ❌ | ✅ |

## Troubleshooting

### Hash mismatch error

The repository content changed. Regenerate hashes:

```bash
nix-hug fetch your-model/name --yes
```

### Models not loading from cache

Ensure `HF_HUB_CACHE` points to the Nix store path:

```bash
export HF_HUB_CACHE=/nix/store/xxx-hf-hub-cache
export TRANSFORMERS_OFFLINE=1
```

Check cache structure:

```bash
ls -la $HF_HUB_CACHE/hub/
```

### Out of disk space

Use filters to download only required files:

```bash
# Download only safetensors (exclude PyTorch bins)
nix-hug fetch model/name --include '*.safetensors' --exclude '*.bin'
```

### Network timeouts

The Hugging Face API may be slow for large models. The CLI shows progress and caches results locally.

## Development

```bash
nix develop
./cli/nix-hug --help
```

Run tests:

```bash
nix flake check
```

## License

MIT License - see flake.nix for details.

## Acknowledgments

Built with Nix. Model hosting by Hugging Face.
