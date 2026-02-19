# nix-hug

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE.md)
[![Nix Flake](https://img.shields.io/badge/Nix-Flake-5277C3?logo=nixos&logoColor=white)](https://nixos.wiki/wiki/Flakes)
[![CI](https://github.com/longregen/nix-hug/actions/workflows/ci.yml/badge.svg)](https://github.com/longregen/nix-hug/actions/workflows/ci.yml)
![Version](https://img.shields.io/badge/version-4.0.0-green)

Declarative Hugging Face model and dataset management for Nix. nix-hug pins
models to exact revisions, fetches only the files you need, builds
offline-compatible HuggingFace Hub caches, and persists store paths through
garbage collection.

## Table of Contents

- [Quick Start](#quick-start)
- [How It Works](#how-it-works)
- [Installation](#installation)
- [CLI Reference](#cli-reference)
  - [fetch](#fetch)
  - [ls](#ls)
  - [export](#export)
  - [import](#import)
  - [store](#store)
- [Nix Library](#nix-library)
  - [fetchModel / fetchDataset](#fetchmodel--fetchdataset)
  - [buildCache](#buildcache)
- [Persistent Storage](#persistent-storage)
- [URL Formats](#url-formats)
- [Development](#development)
- [License](#license)

## Quick Start

Add nix-hug to your flake inputs:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    nix-hug.url = "github:longregen/nix-hug";
  };
}
```

Use the CLI to fetch a model. It resolves the revision, computes hashes, and
prints a Nix expression you can paste into your configuration:

```console
$ nix-hug fetch mistralai/Mistral-7B-Instruct-v0.3 --include '*.safetensors'
```

Use the output in your flake to build an offline HuggingFace Hub cache:

```nix
let
  nix-hug-lib = nix-hug.lib.${system};

  mistral = nix-hug-lib.fetchModel {
    url = "mistralai/Mistral-7B-Instruct-v0.3";
    rev = "abc123...";  # pinned commit hash from CLI output
    filters = { include = [ ".*\\.safetensors" ]; };
    fileTreeHash = "sha256-...";
  };

  cache = nix-hug-lib.buildCache {
    models = [ mistral ];
    hash = "sha256-...";
  };
in
  pkgs.mkShell {
    HF_HUB_CACHE = cache;
    TRANSFORMERS_OFFLINE = "1";
  }
```

Python then finds the model without network access:

```python
from transformers import AutoModelForCausalLM
model = AutoModelForCausalLM.from_pretrained("mistralai/Mistral-7B-Instruct-v0.3")
```

## How It Works

When you run `nix-hug fetch`, the CLI resolves the git ref (for example,
`main`) to a commit hash via the Hugging Face API. It then fetches the
repository's file tree metadata and computes a SHA256 hash of the response.
The output is a Nix expression that pins both values.

When Nix evaluates that expression, `fetchGit` clones the Hugging Face
repository at the pinned revision. This retrieves all small files (configs,
tokenizer data, etc.) but only LFS pointer files for large weights. For each
LFS file that matches your filters, `fetchurl` downloads it from Hugging
Face's CDN using the LFS SHA256 OID as the content hash. A derivation
assembles the result: the git checkout with real model files replacing the LFS
pointers.

`buildCache` takes fetched models and datasets and arranges them into the
directory layout that HuggingFace Hub's Python libraries expect:

```
hub/
  models--org--repo/
    refs/
      main            # contains the pinned commit hash
    snapshots/
      <rev>/          # the actual model files
```

Set `HF_HUB_CACHE` to this store path and any library that reads from the Hub
cache (`transformers`, `diffusers`, `sentence-transformers`) will find the
model without making network requests.

Everything is content-addressed. The same inputs produce the same store paths.
Models can be shared across machines, cached in CI, and pinned in lockfiles
the same way as any other Nix dependency.

### Persistent storage internals

`nix-collect-garbage` removes store paths not referenced by a GC root. For
large models, re-downloading after collection is expensive. The `export`
command copies a model's store path to a local Nix binary cache using
`nix copy`, and `import` restores it. A JSON manifest tracks exported entries
so you can restore individual models or everything at once.

## Installation

### As a flake input

```nix
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
        default = nix-hug.packages.${system}.default;
      };

      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [ nix-hug.packages.${system}.default ];
      };
    };
}
```

### Run directly

```console
$ nix run github:longregen/nix-hug -- fetch mistralai/Mistral-7B-Instruct-v0.3
```

## CLI Reference

Global options:

- `--debug`: enable verbose logging
- `--version`: print version
- `--help`: show help

### `fetch`

Downloads a model or dataset from Hugging Face and prints a Nix expression
with pinned revision and hashes.

```console
$ nix-hug fetch <url> [options]
```

Options:

- `--ref REF`: git reference to resolve (default: `main`)
- `--include PATTERN`: include files matching a glob pattern
- `--exclude PATTERN`: exclude files matching a glob pattern
- `--file FILENAME`: include a specific file by name
- `--out DIR`: copy the result to a regular directory

```console
# Fetch only safetensors weights
$ nix-hug fetch mistralai/Mistral-7B-Instruct-v0.3 --include '*.safetensors'

# Fetch a dataset
$ nix-hug fetch rajpurkar/squad --include '*.json'

# Fetch a single config file
$ nix-hug fetch google-bert/bert-base-uncased --file config.json
```

The CLI auto-detects whether a repository is a model or dataset by querying
the Hugging Face API. You can also use explicit URL formats to skip detection
(see [URL Formats](#url-formats)).

### `ls`

Lists files in a repository without downloading anything. Accepts the same
filter options as `fetch`.

```console
$ nix-hug ls mistralai/Mistral-7B-Instruct-v0.3
$ nix-hug ls stanfordnlp/imdb --include '*.parquet'
```

### `export`

Fetches a model or dataset and copies the store path to persistent local
storage. Models exported this way survive `nix-collect-garbage`. Requires
`persist_dir` to be configured (see [Persistent Storage](#persistent-storage)).

Accepts the same filter options as `fetch`.

```console
$ nix-hug export openai-community/gpt2
$ nix-hug export openai-community/gpt2 --include '*.safetensors'
```

### `import`

Restores a previously exported model from the local binary cache back into
the Nix store.

```console
$ nix-hug import <url> [options]
$ nix-hug import --all
```

Options:

- `--ref REF`: match a specific revision
- `--all`: import all entries from the manifest
- `--yes`, `-y`: skip the trust confirmation prompt

Imports use `--no-check-sigs` because the local binary cache is not signed.
An interactive confirmation is shown unless `--yes` is passed.

```console
$ nix-hug import openai-community/gpt2
$ nix-hug import --all --yes
```

### `store`

Manage persistent storage.

```console
$ nix-hug store ls      # list persisted models with validity status
$ nix-hug store path    # print the configured persist directory
```

## Nix Library

The library is available as `nix-hug.lib.${system}` from the flake output.

### fetchModel / fetchDataset

Fetch a model or dataset from Hugging Face and return a store path containing
all files.

```nix
nix-hug-lib.fetchModel {
  url = "stas/tiny-random-llama-2";
  rev = "3579d71fd57e04f5a364d824d3a2ec3e913dbb67";
  fileTreeHash = "sha256-mD+VYvxsLFH7+jiumTZYcE3f3kpMKeimaR0eElkT7FI=";
}
```

`fetchDataset` has the same interface:

```nix
nix-hug-lib.fetchDataset {
  url = "rajpurkar/squad";
  rev = "abc123...";
  filters = { include = [ ".*\\.json" ]; };
  fileTreeHash = "sha256-...";
}
```

Parameters:

- `url` (required): repository identifier (see [URL Formats](#url-formats))
- `rev` (required): git commit hash (40 characters)
- `fileTreeHash` (required): SHA256 hash of the HF API file tree response
- `filters` (optional): filter object with `include`, `exclude`, or `files`

The `filters` attribute accepts one of three forms:

- `{ include = [ "regex" ... ]; }` keeps only matching LFS files
- `{ exclude = [ "regex" ... ]; }` skips matching LFS files
- `{ files = [ "filename" ... ]; }` selects specific files by exact name

Non-LFS files (configs, tokenizer files) are always included unless `files`
is used.

### buildCache

Combines fetched models and datasets into a HuggingFace Hub-compatible cache
directory.

```nix
nix-hug-lib.buildCache {
  models = [ my-model another-model ];
  datasets = [ my-dataset ];
  hash = "sha256-...";
}
```

The `hash` is the output hash of the combined cache derivation. Set it to an
empty string on first build and Nix will report the correct value.

Use the result as `HF_HUB_CACHE`:

```console
$ export HF_HUB_CACHE=/nix/store/...-hf-hub-cache
$ export TRANSFORMERS_OFFLINE=1
$ python your_script.py
```

## Persistent Storage

Models in `/nix/store/` are removed by `nix-collect-garbage` when no GC root
references them. For models that are expensive to re-download, the persistent
storage feature provides a local binary cache.

### Configuration

Create `~/.config/nix-hug/config`:

```ini
persist_dir=/persist/models
auto_persist=false
```

Or set environment variables (these take precedence):

```bash
export NIX_HUG_PERSIST_DIR=/persist/models
export NIX_HUG_AUTO_PERSIST=true
```

### Workflow

```console
# Export to persistent storage
$ nix-hug export stas/tiny-random-llama-2

# Check what is persisted
$ nix-hug store ls

# After garbage collection, restore
$ nix-hug import stas/tiny-random-llama-2

# Or restore everything
$ nix-hug import --all
```

### Auto-persist

When `auto_persist` is set to `true`, the `fetch` command handles persistence
automatically. Before building, it checks the manifest and restores the model
from the binary cache if the store path was collected. After building, it
exports the result.

```bash
export NIX_HUG_PERSIST_DIR=/persist/models
export NIX_HUG_AUTO_PERSIST=true

# First fetch downloads and auto-exports
nix-hug fetch openai-community/gpt2

# After garbage collection, fetch auto-imports
nix-hug fetch openai-community/gpt2
```

## URL Formats

Models:

- `mistralai/Mistral-7B-Instruct-v0.3`
- `hf:mistralai/Mistral-7B-Instruct-v0.3`
- `https://huggingface.co/mistralai/Mistral-7B-Instruct-v0.3`

Datasets:

- `rajpurkar/squad`
- `hf-datasets:rajpurkar/squad`
- `datasets/rajpurkar/squad`
- `https://huggingface.co/datasets/rajpurkar/squad`

When you use a bare `org/repo` path, the CLI queries the Hugging Face API to
determine whether the repository is a model or dataset.

## Development

```console
$ nix develop
$ ./cli/nix-hug --help
```

Run the tests:

```console
$ nix flake check
$ nix flake check ./test
```

The project uses [ShellCheck](https://www.shellcheck.net/) for bash linting
and [nixpkgs-fmt](https://github.com/nix-community/nixpkgs-fmt) for Nix
formatting.

## License

This software is provided free under the [MIT License](LICENSE.md).
