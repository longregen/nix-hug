# nix-hug CLI Walkthrough

This document covers every possible execution path in the nix-hug CLI with examples.

## Basic Commands

### `nix-hug add` - Add model to lock file

#### Simple case (public model)
```bash
$ nix-hug add openai-community/gpt2
Fetching openai-community/gpt2...
Downloaded to /nix/store/abc123...-hf-model--openai-community--gpt2--base
Added variant "main" to hug.lock with hash sha256-00032bal3lky86iaqzlv8mi18j93i73l
```

#### With filters
```bash
$ nix-hug add openai-community/gpt2 --include '*.safetensors' --include '*.json'
Fetching openai-community/gpt2 with filters...
Filters: include=["*.json", "*.safetensors"]
Downloaded to /nix/store/ghi789...-hf-model--openai-community--gpt2--a1b2c3d4e5
Added variant "a1b2c3d4e5" to hug.lock with hash sha256-mno4566iaqzlv8mi18j93i73l
```

#### Using preset filters
```bash
$ nix-hug add openai-community/gpt2 --filter safetensors
Fetching openai-community/gpt2 with safetensors filter...
Downloaded to /nix/store/jkl012...-hf-model--openai-community--gpt2--f6g7h8i9j0
Added variant "f6g7h8i9j0" to hug.lock with hash sha256-pqrfij2i23jr237899jf20f292jfe0iiddfi
```

#### With specific files
```bash
$ nix-hug add openai-community/gpt2 --file config.json --file model.safetensors
Fetching specific files from openai-community/gpt2...
Files: ["config.json", "model.safetensors"]
Downloaded to /nix/store/stu345...-hf-model--openai-community--gpt2--k1l2m3n4o5
Added variant "k1l2m3n4o5" to hug.lock with hash sha256-vwx012of02r20k3fsisod9r32902jf2jef
```

#### With git ref/tag
```bash
$ nix-hug add openai-community/gpt2 --ref v1.0
Fetching openai-community/gpt2 at ref v1.0...
Resolved to commit abc123def456
Downloaded to /nix/store/yza678...-hf-model--openai-community--gpt2--base
Added variant "main" to hug.lock with hash sha256-bcd345f293fj290f20fwe2ir3r023irf2j0fjfwefw
```

#### URL format variations
```bash
# All of these are equivalent:
$ nix-hug add openai-community/gpt2
$ nix-hug add https://huggingface.co/openai-community/gpt2
$ nix-hug add https://huggingface.co/openai-community/gpt2/tree/main
$ nix-hug add hf:openai-community/gpt2
```

#### Updating existing model
```bash
$ nix-hug add openai-community/gpt2  # Already in hug.lock
Model openai-community/gpt2 already in hug.lock
Current commit: abc123def456
Build hash: sha256-hij234efg90132jr9293jr9f9wefowdkf
Checking for updates... no updates available.

# If updates exist:
$ nix-hug add openai-community/gpt2
Model openai-community/gpt2 already in hug.lock
Current commit: abc123def456
Build hash: sha256-hij234efg90132jr9293jr9f9wefowdkf
Checking for updates... New commit available: xyz789ghi012
Run `nix-hug update openai-community/gpt2` to update it

# If allowed to update:
# Alias: nix-hug update openai-community/gpt2
$ nix-hug add --update openai-community/gpt2
Model openai-community/gpt2 already in hug.lock
Current commit: abc123def456
Build hash: sha256-hij234efg90132jr9293jr9f9wefowdkf
Checking for updates... New commit available: xyz789ghi012
Updating...
Downloaded to /nix/store/efg90132jr9293jr9f9wefowdkf-hf-model--openai-community--gpt2--base
Updated hug.lock with hash sha256-hij234efg90132jr9293jr9f9wefowdkf
```

### `nix-hug fetch` - Fetch without updating lock file

```bash
$ nix-hug fetch openai-community/gpt2
Fetching openai-community/gpt2...
Downloaded to /nix/store/klm5673i2jrio2ejrdf020203f-hf-model--openai-community--gpt2--base
Usage:
  nix-hug.lib.fetchModel {
    url = "openai-community/gpt2";
    hash = "sha256-nop890...";
    rev = "abc123def456";
  }
```

### `nix-hug ls` - List repository contents

#### Basic listing
```bash
$ nix-hug ls openai-community/gpt2
Files in openai-community/gpt2:
  config.json                      1.2 KB
  generation_config.json           241 B
  merges.txt                       446 KB
  model.safetensors                523 MB   [LFS]
  pytorch_model.bin                523 MB   [LFS]
  tokenizer.json                   1.3 MB   [LFS]
  tokenizer_config.json            1.1 KB
  vocab.json                       1.0 MB

Total: 1.05 GB (2 LFS files: 1.05 GB)
```

#### With include filters
```bash
$ nix-hug ls openai-community/gpt2 --include '*.safetensors'
Files in openai-community/gpt2 (filtered):

Included (16 files, 528.7 MB):
  Explicitly (1 file, 522.7 MB):
    model.safetensors                   522.7 MB   [LFS]
  Automatically (15 files,   5.9 MB):
    .gitattributes                         445  B
    README.md                              7.9 KB
    config.json                            665  B
    generation_config.json                 124  B
    merges.txt                           445.6 KB
    onnx/config.json                       879  B
    onnx/generation_config.json            119  B
    onnx/merges.txt                      445.6 KB
    onnx/special_tokens_map.json            99  B
    onnx/tokenizer.json                    2.0 MB
    onnx/tokenizer_config.json             234  B
    onnx/vocab.json                      779.4 KB
    tokenizer.json                         1.3 MB
    tokenizer_config.json                   26  B
    vocab.json                          1017.9 KB

Excluded (10 files, 4.7 GB):
  64-8bits.tflite                     119.4 MB   [LFS]
  64-fp16.tflite                      236.8 MB   [LFS]
  64.tflite                           472.8 MB   [LFS]
  flax_model.msgpack                  474.7 MB   [LFS]
  onnx/decoder_model.onnx             623.4 MB   [LFS]
  onnx/decoder_model_merged.onnx      624.8 MB   [LFS]
  onnx/decoder_with_past_model.onnx   623.4 MB   [LFS]
  pytorch_model.bin                   522.7 MB   [LFS]
  rust_model.ot                       670.0 MB   [LFS]
  tf_model.h5                         474.9 MB   [LFS]
```

#### With exclude filters
```bash
$ nix-hug ls openai-community/gpt2 --exclude '*.bin'
Files in openai-community/gpt2 (filtered):

Included (7 files, 526 MB):
  config.json                      1.2 KB
  generation_config.json           241  B
  merges.txt                       446 KB
  model.safetensors                523 MB  [LFS]
  tokenizer.json                   1.3 MB  [LFS]
  tokenizer_config.json            1.1 KB
  vocab.json                       1.0 MB

Excluded (1 file, 523 MB):
  pytorch_model.bin                523 MB  [LFS]
```

### `nix-hug update` - Update specific model (alias to add --update)

```bash
$ nix-hug update openai-community/gpt2
Checking openai-community/gpt2 for updates...
Current commit: abc123def456 (2024-01-15)
Latest commit:  xyz789ghi012 (2024-02-20)
Updating...
Downloaded to /nix/store/qrs123...-hf-model--openai-community--gpt2--base
Updated hug.lock with hash sha256-tuv456302809230jrf0iefwoidfjdw
```

## Error Scenarios

### Model not found
```bash
$ nix-hug add nonexistent/model
error: Model "nonexistent/model" not found (404).
If this is a private or gated model, you will need a proxy to download it.
Visit https://huggingface.co/nonexistent/model to validate the URL is correct.
```

### Invalid URL type
```bash
$ nix-hug add datasets/squad
error: Only model repositories are supported, not datasets/squad

$ nix-hug add spaces/stabilityai/stable-diffusion
error: Only model repositories are supported, stabilityai/stable-diffusion is a space.
```

### Old Nix version
```bash
$ nix-hug add openai-community/gpt2
error: the current version of nix is 2.18.1. `nix-hug` requires at least 2.26, 
which is the first version with support for `git-lfs` (mandatory to access 
Hugging Face repositories).

There are many ways in which you can run a newer version of `nix`:

1. Run `nix-shell -p nixVersions.latest`, which is 2.28.3 since nixpkgs-25.05
2. Download the latest version from https://nixos.org/download
3. Set `nix.package = pkgs.nixVersions.latest` in your NixOS configuration.
```

### Conflicting filters
```bash
$ nix-hug add org/repo --include '*.safetensors' --exclude '*.bin'
error: Cannot use both --include and --exclude filters

Choose either:
  --include to specify large files to download
  --exclude to specify large files to skip
```

### Lock file path handling
```bash
$ nix-hug add org/repo
No hug.lock found in current directory... Creating new lock file.

$ nix-hug add org/repo --lock-file ../other/hug.lock
Using lock file at ../other/hug.lock
...
```

## Complex Scenarios

### Multiple variants of same model
```bash
$ nix-hug variants openai-community/gpt2
Variants for openai-community/gpt2 in hug.lock:

base:
  Hash: sha256-NfzNLEJhHbZn/a5fmTcLpZhIupPPVzDa7muPQYHqC/w=
  Rev: 7fe295d8bc8fbac8041b60ab351882634165517f
  Ref: main
  Files: All files
  Store Path: /nix/store/abc123...-hf-model--openai-community--gpt2--base

VfJ9YLzmI95GTa8nGGrYR5:
  Hash: sha256-NfzNLEJhHbZn/a5fmTcLpZhIupPPVzDa7muPQYHqC/w=
  Rev: 7fe295d8bc8fbac8041b60ab351882634165517f
  Ref: main
  Filters: include=["*.safetensors"]
  Files: model.safetensors + 5 auto-included files
  Store Path: /nix/store/def456...-hf-model--openai-community--gpt2--VfJ9YLzmI95GTa8nGGrYR5
```

### Hash mismatch (upstream changed)
```bash
$ nix build .#myModel
error: hash mismatch in fixed-output derivation '/nix/store/...-hf-model--openai-community--gpt2--base'
  specified: sha256-ABC123...
  got:      sha256-XYZ789...

To update the hash, run:
  nix-hug update openai-community/gpt2
```
