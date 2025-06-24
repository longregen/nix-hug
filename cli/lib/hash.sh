# Hash discovery and caching functions

# Discover hash for a URL using nix-prefetch-url
discover_hash() {
    local url="$1"
    local cache_key
    cache_key=$(echo -n "$url" | sha256sum | cut -d' ' -f1)
    local cache_file="$CACHE_DIR/hash-$cache_key"
    
    # Check cache first (24 hour TTL for hashes - they rarely change)
    if [[ -f "$cache_file" ]] && [[ $(find "$cache_file" -mtime -1 -print) ]]; then
        debug "Using cached hash for $url"
        cat "$cache_file"
        return 0
    fi
    
    debug "Discovering hash for $url"
    
    # Use nix-prefetch-url for hash discovery
    local hash
    if command -v nix-prefetch-url >/dev/null 2>&1; then
        # Try nix-prefetch-url first (faster and more reliable)
        if hash=$(nix-prefetch-url --type sha256 "$url" 2>/dev/null); then
            # Convert to SRI format
            hash=$(nix hash convert --hash-algo sha256 --to sri "$hash" 2>/dev/null)
            if [[ -z "$hash" ]]; then
                # Fallback if conversion fails
                hash="sha256-$hash"
            fi
        fi
    fi
    
    # Fallback to nix eval method if nix-prefetch-url failed
    if [[ -z "$hash" ]]; then
        local output
        if output=$(nix eval --impure --expr "builtins.fetchurl { url = \"$url\"; sha256 = \"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\"; }" 2>&1); then
            error "Expected hash mismatch but eval succeeded"
            return 1
        fi
        
        # Extract hash from error
        hash=$(echo "$output" | grep -o 'sha256[-:][A-Za-z0-9+/=]*' | tail -1)
    fi
    
    if [[ -z "$hash" ]]; then
        error "Could not discover hash for $url"
        return 1
    fi
    
    # Cache the result
    echo "$hash" > "$cache_file"
    debug "Cached hash for $url: $hash"
    
    echo "$hash"
}

# Get repository files with caching
get_repo_files() {
    local parsed="$1"
    local ref="$2"
    
    local org repo repo_id
    org=$(echo "$parsed" | jq -r '.org')
    repo=$(echo "$parsed" | jq -r '.repo')
    repo_id=$(echo "$parsed" | jq -r '.repoId')
    
    # Build cache key
    local cache_key
    cache_key=$(echo -n "${repo_id}:${ref}" | sha256sum | cut -d' ' -f1)
    local cache_file="$CACHE_DIR/files-$cache_key"
    
    # Check cache (1 hour TTL for file listings)
    if [[ -f "$cache_file" ]] && [[ $(find "$cache_file" -mmin -60 -print) ]]; then
        debug "Using cached file listing for $repo_id"
        cat "$cache_file"
        return 0
    fi
    
    # Fetch file tree
    local url="https://huggingface.co/api/models/${repo_id}/tree/${ref}"
    local response
    
    debug "Fetching file tree from $url"
    if ! response=$(curl -sfL "$url"); then
        error "Failed to fetch repository information"
        return 1
    fi
    
    # Cache the result
    echo "$response" > "$cache_file"
    
    echo "$response"
}
