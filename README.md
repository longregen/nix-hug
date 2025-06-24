# nix-hug

Declarative Hugging Face model and dataset management for Nix.

## Usage

### Fetch a model

```bash
# Download Mistral 7B Instruct model (safetensors only)
nix-hug fetch mistralai/Mistral-7B-Instruct-v0.3 --include '*.safetensors'
```

This outputs a Nix expression you can use in your configuration:

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

```bash
# Download Google's BERT base model
nix-hug fetch google-bert/bert-base-uncased
```

This outputs:

```nix
nix-hug-lib.fetchModel {
  url = "google-bert/bert-base-uncased";
  rev = "main";
  repoInfoHash = "sha256-xyz789...";
  fileTreeHash = "sha256-uvw456...";
  derivationHash = "sha256-rst123...";
}
```

### Create a HuggingFace cache

The `buildCache` function creates a HuggingFace Hub-compatible cache that works with transformers:

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

## Installation

```bash
# Add to your flake inputs
{
  inputs.nix-hug.url = "github:longregen/nix-hug";
}
```

### Other commands

```bash
# List model files without downloading
nix-hug ls mistralai/Mistral-7B-Instruct-v0.3

# Download a dataset
nix-hug fetch rajpurkar/squad --include '*.json'

# Download with filters
nix-hug fetch google-bert/bert-base-uncased --include '*.safetensors'
```

## Development

```bash
nix develop
./cli/nix-hug --help
```

## Commands

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
- `--yes, -y`: Auto-confirm operations

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

## URL Formats

Models:
- `https://huggingface.co/mistralai/Mistral-7B-Instruct-v0.3`
- `hf:mistralai/Mistral-7B-Instruct-v0.3`
- `mistralai/Mistral-7B-Instruct-v0.3`

Datasets:
- `https://huggingface.co/datasets/rajpurkar/squad`
- `hf-datasets:rajpurkar/squad`
- `datasets/rajpurkar/squad`
- `rajpurkar/squad` (when using `fetch`)

## Cache Management

The `cache` command helps manage nix-hug's local cache for improved performance:

```bash
# Clean expired cache entries
nix-hug cache clean

# Verify cache integrity
nix-hug cache verify

# Show cache statistics
nix-hug cache stats
```

The cache stores discovered hashes and metadata to speed up subsequent operations. Cache entries expire after 24 hours by default.
