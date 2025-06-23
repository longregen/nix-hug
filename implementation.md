# nix-hug Implementation Decisions

This document provides implementation details and code snippets for engineers working on nix-hug.

## Core Components

### 1. Shared Utilities (`src/shared.py`)

The `src/shared.py` module contains all shared functionality used across CLI and builder components to ensure consistency:

```python
# Key shared functions:
from .shared import (
    generate_minihash, # Filter configuration hashing
    parse_repo_url,    # URL parsing and validation
    format_size,       # Human-readable size formatting
    apply_filters,     # File filtering with non-LFS override
    is_non_lfs_file,   # Essential file detection
    check_nix_version, # Version compatibility checking
    build_nix_expression, # Nix expression generation
    format_error_message, # User-friendly error formatting
    extract_hash_from_nix_error, # Hash extraction from build errors
    format_nix_version_error     # Version error formatting
)
```

**Design Principle**: All core logic is in `shared.py` to prevent code duplication between CLI display logic and FOD builder logic.

### 2. Non-LFS File Auto-Inclusion

A core design principle is that **non-LFS files are always included** regardless of user filters:

```python
def apply_filters(files, file_sizes, lfs_status, include=None, exclude=None, specific_files=None):
    """Apply filters with non-LFS override."""
    # Separate non-LFS files (always included)
    non_lfs_files = [f for f in files if is_non_lfs_file(f, lfs_status)]
    lfs_files = [f for f in files if not is_non_lfs_file(f, lfs_status)]
    
    # Apply filters only to LFS files
    # Non-LFS files are always included to prevent broken downloads
    
    return included_files, excluded_files, non_lfs_override_files
```

**Rationale**: Configuration files (config.json, tokenizer.json) are essential for model operation and are typically small (<10MB). This prevents user error from creating non-functional model downloads, and relative to the huge size of models, it's not a huge bandwidth waste.

### 3. Display Formatting

The CLI uses a structured display format that clearly separates explicitly included files from automatically included non-LFS files:

```python
# Dynamic column width calculation
max_filename_len = max(len(f) for f in files) if files else 30
col_width = max(30, max_filename_len + 2)

# Structured output
click.echo(f"Included ({len(included_files)} files, {format_size(included_size)}):")

if explicitly_included:
    click.echo(f"  Explicitly ({len(explicitly_included)} files, {format_size(explicit_size)}):")
    for file in sorted(explicitly_included):
        click.echo(f"    {file:<{col_width}} {format_table_size(size):>8} [LFS]")

if auto_included:
    click.echo(f"  Automatically ({len(auto_included)} files, {format_size(auto_size)}):")
    for file in sorted(auto_included):
        click.echo(f"    {file:<{col_width}} {format_table_size(size):>8}")
```

**Size Formatting**: Uses consistent right-aligned formatting with proper spacing:
- `format_table_size()` ensures "B" units align with "KB"/"MB"/"GB" units
- Dynamic column width must accomodate for folder path length

### 4. Real API Integration

File information now comes from actual HuggingFace API calls instead of hardcoded estimates:

```python
def get_file_info(repo_url: str, token: str = None):
    """Get file list, sizes, and LFS status from HuggingFace API."""
    api = HfApi(token=token)
    files_info = list(api.list_repo_tree(repo_url, token=token, recursive=True))
    
    files = []
    file_sizes = {}
    lfs_status = {}
    
    for file_info in files_info:
        if hasattr(file_info, 'size') and file_info.size is not None:
            files.append(file_info.path)
            file_sizes[file_info.path] = file_info.size
            lfs_status[file_info.path] = hasattr(file_info, 'lfs') and file_info.lfs is not None
    
    return files, file_sizes, lfs_status
```

**Benefits**:
- Accurate file sizes for bandwidth planning
- Correct LFS detection for filtering decisions
- Real-time repository state information

### 5. URL Parsing Implementation

```python
import re
from urllib.parse import urlparse

def parse_repo_url(url: str) -> str:
    """
    Parse various URL formats into canonical org/repo format.
    
    Examples:
        "org/repo" -> "org/repo"
        "https://huggingface.co/org/repo" -> "org/repo"
        "https://huggingface.co/org/repo/tree/main" -> "org/repo"
        "hf:org/repo" -> "org/repo"
    """
    # Remove common prefixes
    url = re.sub(r'^https?://(www\.)?huggingface\.co/', '', url)
    url = re.sub(r'^hf:', '', url)
    
    # Remove trailing paths (tree/main, blob/main, etc.)
    url = re.sub(r'/(tree|blob|resolve|discussions|commits)/.*', '', url)
    
    # Check for non-model repos
    if url.startswith(('datasets/', 'spaces/')):
        raise ValueError(f"Only model repositories are supported, not {url}")
    
    # Extract org/repo
    parts = url.strip('/').split('/')
    if len(parts) < 2:
        raise ValueError(f"Invalid repository URL format: {url}")
    
    return f"{parts[0]}/{parts[1]}"
```

### 2. Minihash Generation

```python
import hashlib
import base64
import json

def generate_minihash(filters: dict | None) -> str:
    """
    Generate deterministic 22-character identifier for filter configuration.
    """
    if not filters:
        return 'base'
    json_str = json.dumps(filters, sort_keys=True, separators=(',', ':'))
    hash_bytes = hashlib.sha256(json_str.encode('utf-8')).digest()
    # Base64 encode and take first 22 chars
    # (represents ~132 bits of the hash, sufficient for uniqueness)
    base64_hash = base64.b64encode(hash_bytes).decode('ascii')
    return base64_hash[22:]
```

### 4. Store Path Construction

```nix
# In Nix
let
  # Convert repo URL to store-friendly name
  repoToStoreName = url: let
    parts = lib.splitString "/" url;
    org = builtins.elemAt parts 0;
    repo = builtins.elemAt parts 1;
    variant = if (filters != null) then (minihash filters) else "main";
  in "hf-model--${org}--${repo}--${variant}";
in
  # ...
```

### 6. Three-Phase Fetch Implementation

```nix
# fetchModel implementation
{ lib, fetchGit, runCommand, python3, huggingface-hub }:

{ url
, hash ? lib.fakeHash
, rev ? null
, ref ? null
, filters ? null
}:

let
  # Parse URL into org/repo
  parsed = parseRepoUrl url;
  
  # Check if we need filtered download
  needsFiltered = filters != null;
  
  # Generate store name
  storeName = 
    if needsFiltered
    then "hf-model--${parsed.org}--${parsed.repo}--${minihash filters}"
    else "hf-model--${parsed.org}--${parsed.repo}--base";
  
  # Phase 1: Check if already in store
  storePath = "/nix/store/${hashToBase32 hash}-${storeName}";
  
  # Phase 2: Try lock file lookup (handled by caller)
  
  # Phase 3: Build FOD
  fod = 
    if needsFiltered || lib.versionOlder builtins.nixVersion "2.26"
    then
      # Use Python FOD builder for filtered or old Nix
      runCommand storeName {
        outputHash = hash;
        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
        
        nativeBuildInputs = [ python3 huggingface-hub ];
        
        NIX_HUG_REPO = "${parsed.org}/${parsed.repo}";
        NIX_HUG_REV = rev or ref or "main";
        NIX_HUG_FILTERS = builtins.toJSON (filters or {});
      } ''
        python3 ${./builder.py}
      ''
    else
      # Use native fetchGit for full repo with new Nix
      fetchGit {
        url = "https://huggingface.co/${parsed.org}/${parsed.repo}";
        ${if rev != null then "rev" else null} = rev;
        ${if ref != null then "ref" else null} = ref;
        lfs = true;
        name = storeName;
      };
in
  # Return immediately if store path exists, otherwise build
  if builtins.pathExists storePath
  then storePath
  else fod
```

### 7. Lock File Structure and Operations

The lock file (`hug.lock`) stores repository metadata and variant information to generate a cache for the HuggingFace library and avoid multiple API calls which are needed to determine file lists, sizes, LFS status, and hashes for each repository. The lock file caches this information locally to enable efficient cache population and incremental variant creation.

#### Lock File JSON Schema

```json
{
  "version": 1,
  "models": {
    "org/repo": {
      "repo": {
        "lastUpdated": "2025-06-20T15:37:51.933339+00:00Z",
        "refs": {
          "main": "commit-hash",
          "v1.0": "other-commit-hash"
        },
        "snapshots": {
          "commit-hash": {
            "lastUpdated": "2025-06-20T15:37:51.933339+00:00Z",
            "repo_files": {
              "filename.txt": {
                "hash": "git-blob-id",
                "lfs": false,
                "size": 1234
              },
              "model.safetensors": {
                "hash": "git-blob-id", 
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
          "rev": "commit-hash",
          "ref": "main",
          "lastUpdated": "2025-06-20T15:37:51.933339+00:00Z",
          "filtered_files": ["filename.txt", "model.safetensors"],
          "storePath": "/nix/store/hash-hf-model--org--repo--base"
        },
        "variant-key": {
          "hash": "sha256-...",
          "rev": "commit-hash", 
          "ref": "main",
          "lastUpdated": "2025-06-20T15:37:51.933339+00:00Z",
          "filtered_files": ["model.safetensors"],
          "filters": {
            "include": ["*.safetensors"]
          },
          "storePath": "/nix/store/hash-hf-model--org--repo--variant-key"
        }
      }
    }
  }
}
```

#### Field Descriptions

**Top Level**:
- `version`: Schema version (currently 1)
- `models`: Map of repository URLs to their data

**Repository Level** (`models["org/repo"]`):
- `repo`: Repository metadata and file information
- `variants`: Map of variant keys to their build information

**Repository Metadata** (`repo`):
- `lastUpdated`: ISO timestamp of last repository update
- `revisions`: Map of Git commit hashes to revision data
- `refs`: Map of Git references (branches, tags) to revision hashes

**Revision Data** (`revisions["commit-hash"]`):
- `lastUpdated`: ISO timestamp of when this revision was fetched
- `repo_files`: Complete file metadata for this revision

**File Metadata** (`repo_files["filename"]`):
- `hash`: Git blob ID for integrity verification
- `lfs`: Boolean indicating if file is stored in Git LFS
- `size`: File size in bytes

**Variant Data** (`variants["variant-key"]`):
- `hash`: Nix store hash for this variant's FOD
- `rev`: Git commit hash this variant was built from
- `ref`: Git reference used for this variant
- `lastUpdated`: ISO timestamp of variant creation
- `filtered_files`: List of files included in this variant
- `filters`: Filter configuration used (optional, only for non-base variants)
- `storePath`: Nix store path for this variant (optional)


#### Cache Population Benefits

The lock file structure enables efficient cache population:

1. **Avoid Redundant API Calls**: File metadata is cached locally instead of fetching from HuggingFace APIs repeatedly
2. **Incremental Variant Creation**: New variants can reuse existing files from the cache without re-downloading
3. **Integrity Verification**: Git blob IDs allow verification of cached files
4. **Efficient Filtering**: `filtered_files` lists enable precise cache population for each variant

The `populate_cache_from_lock` function uses this metadata to create HuggingFace cache structures that allow `huggingface_hub` to find and reuse previously downloaded files.

### 8. CLI Error Formatting

```python
def format_error_with_help(error_type: str, repo: str, details: dict) -> str:
    """Format user-friendly error messages with actionable help."""
    
    if error_type == "not_found":
        return f"""Model "{repo}" not found (404).
If this is a private or gated model, you will need a proxy to download it.
Visit https://huggingface.co/{repo} to validate the URL is correct."""
    
    elif error_type == "unauthorized":
        return f"""error: 403 unable to download {repo}
If this is a private or gated model, you will need a proxy to download it.
Visit https://huggingface.co/{repo} to validate the URL is correct."""
    
    elif error_type == "hash_mismatch":
        return f"""error: hash mismatch in fixed-output derivation
  specified: {details['expected']}
  got:       {details['actual']}

To update the hash, run:
  nix-hug update {repo}"""
    
    elif error_type == "old_nix":
        return f"""error: the current version of nix is {details['version']}. `nix-hug` requires at least 2.26, 
which is the first version with support for `git-lfs` (mandatory to access 
Hugging Face repositories).

There are many ways in which you can run a newer version of `nix`:

1. Run `nix-shell -p nixVersions.latest`, which is 2.28.3 since nixpkgs-25.05
2. Download the latest version from https://nixos.org/download
3. Set `nix.package = pkgs.nixVersions.latest` in your NixOS configuration."""
```

### 9. HF Cache Structure Builder

```nix
# buildCache implementation
{ lib, linkFarm, symlinkJoin }:

models:
let
  # HuggingFace cache structure:
  # hub/
  #   models--org--repo/
  #     snapshots/
  #       {revision}/
  #         {model files}
  #     refs/
  #       main
  
  # Create structure for one model
  modelToCache = model: let
    # Extract metadata from model path
    metadata = builtins.fromJSON 
      (builtins.readFile "${model}/.nix-hug-metadata.json");
    
    # Parse org/repo from store path
    # /nix/store/hash-hf-model--org--repo--minihash -> org/repo
    nameParts = lib.splitString "--" (baseNameOf model);
    org = builtins.elemAt nameParts 1;
    repo = builtins.elemAt nameParts 2;
    
    # Get revision (from metadata or default)
    revision = metadata.rev or "main";
  in
    linkFarm "model-${org}-${repo}" [
      {
        name = "hub/models--${org}--${repo}/snapshots/${revision}";
        path = model;
      }
      {
        name = "hub/models--${org}--${repo}/refs/main";
        path = builtins.toFile "ref" revision;
      }
    ];
  
  # Combine all models
  cacheEntries = map modelToCache models;
in
  symlinkJoin {
    name = "hf-hub-cache";
    paths = cacheEntries;
  }
```

## Testing Considerations

### 1. Mock HuggingFace for Tests

```python
class MockHuggingFaceHub:
    """Mock for testing without real HF API calls."""
    
    def __init__(self, test_repos):
        self.repos = test_repos
    
    def list_repo_files(self, repo_id, revision="main"):
        if repo_id not in self.repos:
            raise HTTPError(404, "Not found")
        return self.repos[repo_id]["files"]
    
    def snapshot_download(self, repo_id, **kwargs):
        # Create fake files based on test data
        pass
```

### 2. Deterministic Tests

- Always use sorted operations for reproducibility
- Fix timestamps in lock files for testing
- Use known hashes for test fixtures

### 3. Error Path Testing

Test all error conditions:
- Network failures
- Authentication errors  
- Hash mismatches
- Invalid URLs
- Missing dependencies

## Performance Optimizations

### 1. Parallel Metadata Fetching

When listing files, fetch metadata in parallel:

```python
import asyncio
import aiohttp

async def fetch_file_metadata(session, repo, files):
    tasks = []
    for file in files:
        task = fetch_single_file_metadata(session, repo, file)
        tasks.append(task)
    
    return await asyncio.gather(*tasks)
```

### 2. Lazy Lock File Loading

Only parse lock file when needed:

```python
class LazyHugLock:
    def __init__(self, path):
        self.path = path
        self._data = None
    
    @property
    def data(self):
        if self._data is None:
            self._data = self._load()
        return self._data
```

### 3. Store Path Caching

Cache store path checks to avoid repeated filesystem access:

```nix
let
  # Memoize store path existence checks
  pathExistsCache = {};
  
  cachedPathExists = path:
    pathExistsCache.${path} or 
    (pathExistsCache.${path} = builtins.pathExists path);
in
  # Use cachedPathExists instead of builtins.pathExists
```

## Security Considerations

### 1. Token Handling

- Never log tokens
- Clear tokens from memory after use
- Validate token format before use
- Use secure token transmission (HTTPS only)

### 2. Path Traversal Prevention

```python
def safe_join_path(base, *paths):
    """Safely join paths preventing traversal attacks."""
    result = os.path.join(base, *paths)
    real_base = os.path.realpath(base)
    real_result = os.path.realpath(result)
    
    if not real_result.startswith(real_base):
        raise ValueError("Path traversal detected")
    
    return result
```

### 3. Lock File Validation

Validate lock file structure on load:

```python
def validate_lock_data(data):
    """Validate lock file structure and contents."""
    assert data.get("version") == 1
    assert isinstance(data.get("models"), dict)
    
    for repo, variants in data["models"].items():
        assert "/" in repo  # Must be org/repo format
        for variant_key, variant_data in variants.items():
            assert "hash" in variant_data
            assert "rev" in variant_data
            assert variant_data["hash"].startswith("sha256-")
```
