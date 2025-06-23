# nix-hug Design Decisions

## Core Design Principles

### 1. Bandwidth Preservation
**Decision**: Use Fixed Output Derivations (FODs) for all model fetching.

**Rationale**: 
- Models can be gigabytes in size
- nixpkgs updates shouldn't invalidate model downloads
- Python package updates shouldn't require re-downloading models
- FODs provide perfect caching based on content hash

### 2. Git-Native Approach
**Decision**: Use `builtins.fetchGit` with LFS support (Nix ≥2.26) when possible.

**Rationale**:
- Hugging Face uses Git repositories with LFS for models
- Maintains full Git semantics (commits, tags, branches)
- Future-proof as Nix improves Git LFS support
- Archive URLs lose version control capabilities

### 3. Lock File has a Hygienic Role for .nix Files
**Decision**: Lock file stores hashes and metadata but isn't required for operation.

**Rationale**:
- Users can specify hashes directly in Nix expressions
- Lock file provides convenience, not necessity
- Enables both imperative (CLI) and declarative (pure Nix) workflows
- Reduces complexity by avoiding lock file parsing in Nix

### 4. Non-LFS Files Always Included
**Decision**: Override user filters to always include non-LFS files.

**Rationale**:
- Config files (config.json, tokenizer.json) are essential for model operation
- These files are small (<10MB for text, <1MB for binary)
- Prevents user error from creating non-functional model downloads
- Simplifies mental model: filters only apply to large files

### 5. URL as Universal Parameter
**Decision**: Use `url` parameter accepting multiple formats instead of separate org/repo.

**Rationale**:
- Users often copy URLs from browsers
- Consistent with flake URL syntax (`github:owner/repo`)
- Single parameter is simpler than multiple
- Flexible parsing handles various formats

### 6. Three-Phase Fetching Strategy
**Decision**: Check store → check lock → build FOD.

**Rationale**:
- Store check provides instant returns for existing models
- Lock file lookup avoids FOD builds when hash is known
- FOD fallback ensures operation without lock file
- Optimizes for common case (model already downloaded)

### 7. Minihash for Variant Identification
**Decision**: Use 22-character base64 hash of filter configuration.

**Rationale**:
- Deterministic variant identification
- Short enough for paths and human reading
- Unique enough to avoid collisions
- Stable across different machines/times

### 8. Filter Presets in Library
**Decision**: Provide some filters, like `nix-hug.filters.safetensors`~style presets instead of format parameter.

**Rationale**:
- More flexible than hardcoded formats
- Users can see exactly what patterns are used
- Composable with custom patterns
- Reduces API surface complexity
- Best-effort approach, not comprehensive

## Security Decisions

### 1. No Token Storage
**Decision**: We can never store HF_TOKEN in Nix expressions or lock files. That means that the user will have to use some sort of proxy to access private/gated repos.

**Rationale**:
- `/nix/store` is world-readable
- Tokens are credentials that must remain secret

## Implementation Decisions

### 1. Git Check-Attr for LFS Detection
**Decision**: Create minimal Git repo to use `git check-attr` for LFS detection.

**Rationale**:
- Most accurate method (uses actual .gitattributes)
- Handles all edge cases and patterns correctly
- Same method Hugging Face's own tools use
- Worth the overhead for correctness

### 2. Stable Filter Serialization
**Decision**: Sort all lists lexicographically before hashing.

**Rationale**:
- Ensures same filters produce same minihash
- Order-independent filter specification
- Prevents duplicate variants from order differences
- Standard approach in content-addressed systems

### 3. CLI Updates Lock File, Library Reads Only
**Decision**: Only `nix-hug add` modifies hug.lock; library functions read-only.

**Rationale**:
- Preserves Nix purity (no side effects in builds)
- Clear separation of imperative (CLI) and declarative (Nix)
- Prevents race conditions in parallel builds
- Standard pattern in Nix ecosystem

## Trade-offs Acknowledged

### 1. Complexity vs Correctness
We chose correctness (git check-attr) over simplicity (size heuristics) for LFS detection, accepting implementation complexity.

### 2. Lock File Structure
Enhanced format with variants is more complex than simple format, but enables efficient filtered downloads without redundant fetching.

### 3. Non-LFS Override
Overriding user filters for non-LFS files may surprise users but prevents broken model downloads.

### 4. Git LFS Requirement
Requiring Nix ≥2.26 limits compatibility but ensures reliable operation with Hugging Face's infrastructure.

## Future Considerations

### 1. Incremental Updates
Current design re-fetches entire variant. Future optimization could fetch only changed files.

### 2. Parallel Downloads
FOD restrictions prevent parallel file downloads. Future Nix versions may enable this.