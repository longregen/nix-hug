# nix-hug Project Template

This template provides a basic setup for using nix-hug to manage Hugging Face models in your Nix project.

## Getting Started

1. **Add models to your project:**
   ```bash
   nix develop
   nix-hug add openai-community/gpt2
   nix-hug add microsoft/DialoGPT-medium --filter safetensors
   ```

2. **Use models in your Nix expressions:**
   ```nix
   let
     models = nix-hug.withLock ./hug.lock;
   in
   {
     # Access a specific model variant
     myModel = models."openai-community/gpt2".main;
     
     # Or use the fetchModel function directly
     anotherModel = models.fetchModel {
       url = "microsoft/DialoGPT-medium";
       hash = "sha256-..."; # from hug.lock
     };
   }
   ```

## Available Commands

- `nix-hug add <model>` - Add a model to hug.lock
- `nix-hug ls <model>` - List model contents
- `nix-hug update <model>` - Update a model
- `nix-hug variants <model>` - Show model variants

## Example Usage

```bash
# List available files in a model
nix-hug ls openai-community/gpt2

# Add only safetensors files
nix-hug add openai-community/gpt2 --filter safetensors

# Add specific files
nix-hug add openai-community/gpt2 --file config.json --file model.safetensors
```

For more information, see the [nix-hug documentation](https://github.com/nix-community/nix-hug).
