# nix-hug v3

Declarative Hugging Face model management for Nix - A complete rewrite with improved architecture, performance, and user experience.

## Features

- **Declarative Model Management**: Define models in your Nix configuration
- **Smart Filtering**: Include/exclude files with regex patterns or specific file lists
- **Hash Discovery**: Automatic hash discovery and caching
- **Modular Architecture**: Clean separation between CLI and library components
- **Developer Friendly**: Comprehensive error handling and helpful output

## Quick Start

### Installation

```bash
# Add to your flake inputs
{
  inputs.nix-hug.url = "github:longregen/nix-hug";
}

# Or install directly
nix profile install github:longregen/nix-hug
```

### Basic Usage

```bash
# List model files
nix-hug ls openai-community/gpt2

# Download a model
nix-hug fetch openai-community/gpt2

# Download with filters
nix-hug fetch openai-community/gpt2 --include '*.safetensors'
```

### In Your Nix Configuration

```nix
{
  inputs.nix-hug.url = "github:longregen/nix-hug";
  
  outputs = { self, nixpkgs, nix-hug }: {
    packages.x86_64-linux.gpt2-model = 
      nix-hug.lib.x86_64-linux.fetchModel {
        url = "openai-community/gpt2";
        rev = "main";
        filters = nix-hug.lib.x86_64-linux.filterPresets.safetensors;
        # Hashes will be discovered automatically
      };
  };
}
```

## Development

```bash
nix develop
./cli/nix-hug --help
```

## Architecture

The project is split into modular components:

- **lib/**: Nix library modules for declarative model management
- **cli/**: Command-line interface with bash completion
- **cache/**: Local cache for hash discovery and file listings

This modular design enables easier testing, maintenance, and extension of functionality.
