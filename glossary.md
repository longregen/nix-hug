# nix-hug Glossary

## Core Concepts

### **Base Variant**
The default variant of a model stored in `hug.lock` with no filters applied. Downloaded using `fetchGit` with LFS support when available (Nix ≥2.26). Identified by the key `"base"` in the lock file.

### **Filter**
A mechanism to selectively download files from a Hugging Face repository. Filters can be:
- `include`: List of regex patterns for files to include
- `exclude`: List of regex patterns for files to exclude  
- `files`: Explicit list of file paths to download

### **Fixed Output Derivation (FOD)**
A Nix derivation with a known output hash. Used to ensure reproducibility and enable caching. Models are fetched as FODs to preserve bandwidth across nixpkgs updates.

### **hug.lock**
JSON file storing metadata about fetched models. Contains:
- Model repository URLs
- Commit hashes (rev)
- Output hashes for FODs
- Filter specifications
- File metadata of the remote repo (sizes, LFS status)

### **LFS (Large File Storage)**
Git extension for versioning large files. On Hugging Face:
- Binary files >1MB use LFS
- Text files >10MB use LFS
- Handled automatically by Git when Nix ≥2.26

### **Minihash**
A 22-character identifier for filter variants, computed as:
```
base64(sha256(canonical_json(sorted_filters)))[22:]
```
Used as the variant key in `hug.lock` and appended to store paths.

### **Non-LFS Files**
Files stored directly in Git rather than LFS. Always included regardless of filter rules. Typically includes:
- Configuration files (config.json, tokenizer.json)
- Small text files
- Metadata files

### **Ref**
Git reference (branch or tag name). Defaults to `"main"`. Examples:
- `main` (default branch)
- `v1.0` (tag)
- `feature-branch` (branch)

### **Repo Files**
Complete file listing cached in `hug.lock` including:
- File paths
- File sizes in bytes
- LFS status (true/false)

Used to determine filter behavior without network requests.

### **Rev**
Git commit hash. The exact commit fetched from the repository. Stored in `hug.lock` to ensure reproducibility.

### **Store Path**
Location in `/nix/store` where models are stored. Format:
```
/nix/store/[hash]-hf-model--[org]--[repo](--[variant])/
```

### **Three-Phase Fetching**
Optimization strategy:
1. Check if store path exists (instant return)
2. Look up hash in `hug.lock`
3. Fall back to FOD build if needed

### **URL**
Repository identifier accepting multiple formats:
- `org/repo` (assumes huggingface.co)
- `https://huggingface.co/org/repo`
- `hf:org/repo`
- Browser URLs (auto-cleaned)

### **Variant**
A specific configuration of a model defined by its filters. Stored in `hug.lock` under:
- `"base"` for no filters
- Minihash for filtered versions