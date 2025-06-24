# Hash discovery and caching utilities

CACHE_INDEX_FILE="$CACHE_DIR/cache-index"
CACHE_LOCK_FILE="$CACHE_DIR/.lock"

# File locking utilities
acquire_cache_lock() {
    local timeout="${1:-30}"
    local count=0
    
    mkdir -p "$CACHE_DIR"
    
    while ! (set -C; echo $$ > "$CACHE_LOCK_FILE") 2>/dev/null; do
        if (( count++ > timeout )); then
            error "Failed to acquire cache lock after ${timeout}s"
            return 1
        fi
        sleep 0.1
    done
    
    # Set up cleanup trap
    trap 'release_cache_lock' EXIT INT TERM
}

release_cache_lock() {
    [[ -f "$CACHE_LOCK_FILE" ]] && rm -f "$CACHE_LOCK_FILE"
    trap - EXIT INT TERM
}

# Initialize cache directory and index
init_cache() {
    mkdir -p "$CACHE_DIR/data"
    [[ -f "$CACHE_INDEX_FILE" ]] || touch "$CACHE_INDEX_FILE"
}

# Get cached value if within TTL
cache_get() {
    local key="$1"
    local ttl_minutes="$2"
    
    init_cache
    
    local cache_file="$CACHE_DIR/data/$(echo -n "$key" | sha256sum | cut -d' ' -f1)"
    
    if [[ -f "$cache_file" ]]; then
        local file_age_minutes
        file_age_minutes=$(( ($(date +%s) - $(stat -c %Y "$cache_file")) / 60 ))
        
        if (( file_age_minutes < ttl_minutes )); then
            # Verify file integrity before reading
            if [[ -s "$cache_file" ]] && cat "$cache_file" 2>/dev/null; then
                return 0
            else
                debug "Cache file corrupted, removing: $cache_file"
                rm -f "$cache_file"
            fi
        else
            # Clean up expired cache entry with locking
            acquire_cache_lock 5 || return 1
            rm -f "$cache_file"
            
            # Safely update index
            local basename_file="$(basename "$cache_file")"
            local temp_index="$(mktemp)"
            grep -v "^$basename_file:" "$CACHE_INDEX_FILE" 2>/dev/null > "$temp_index" || true
            mv "$temp_index" "$CACHE_INDEX_FILE"
            
            release_cache_lock
        fi
    fi
    
    return 1
}

# Set cache value
cache_set() {
    local key="$1"
    local value="$2"
    
    init_cache
    
    # Validate input
    [[ -n "$key" && -n "$value" ]] || {
        error "cache_set: key and value cannot be empty"
        return 1
    }
    
    local cache_file="$CACHE_DIR/data/$(echo -n "$key" | sha256sum | cut -d' ' -f1)"
    local basename_file="$(basename "$cache_file")"
    
    # Acquire lock for atomic operations
    acquire_cache_lock 10 || return 1
    
    # Validate required variables
    if [[ -z "$value" ]]; then
        error "Cache value is empty for key: $key"
        release_cache_lock
        return 1
    fi
    
    # Write cache file atomically
    local temp_cache_file="$(mktemp)"
    if echo "$value" > "$temp_cache_file" && mv "$temp_cache_file" "$cache_file"; then
        # Update index atomically
        local temp_index="$(mktemp)"
        {
            grep -v "^$basename_file:" "$CACHE_INDEX_FILE" 2>/dev/null || true
            echo "$basename_file:$(date +%s):$key"
        } > "$temp_index" && mv "$temp_index" "$CACHE_INDEX_FILE"
    else
        error "Failed to write cache file: $cache_file"
        rm -f "$temp_cache_file"
        release_cache_lock
        return 1
    fi
    
    release_cache_lock
}

# Clean up expired cache entries
cache_cleanup() {
    local max_age_minutes="${1:-1440}" # Default 24 hours
    
    init_cache
    
    # Acquire lock to prevent corruption during cleanup
    acquire_cache_lock 30 || {
        warn "Could not acquire lock for cache cleanup"
        return 1
    }
    
    local now="$(date +%s)"
    local temp_index="$(mktemp)"
    local cleanup_count=0
    
    # Process index file safely
    if [[ -f "$CACHE_INDEX_FILE" ]]; then
        while IFS=: read -r filename timestamp key; do
            [[ -n "$filename" ]] || continue
            
            local cache_file="$CACHE_DIR/data/$filename"
            
            # Validate timestamp
            if [[ "$timestamp" =~ ^[0-9]+$ ]]; then
                local age_minutes=$(( (now - timestamp) / 60 ))
                
                if (( age_minutes > max_age_minutes )); then
                    rm -f "$cache_file"
                    debug "Cleaned expired cache entry: $key (age: ${age_minutes}m)"
                    ((cleanup_count++))
                else
                    # Keep valid entries, but verify file still exists
                    if [[ -f "$cache_file" ]]; then
                        echo "$filename:$timestamp:$key" >> "$temp_index"
                    fi
                fi
            else
                # Remove entries with invalid timestamps
                rm -f "$cache_file"
                debug "Removed cache entry with invalid timestamp: $key"
                ((cleanup_count++))
            fi
        done < "$CACHE_INDEX_FILE"
        
        # Update index atomically
        mv "$temp_index" "$CACHE_INDEX_FILE"
        
        if (( cleanup_count > 0 )); then
            debug "Cache cleanup completed: removed $cleanup_count entries"
        fi
    fi
    
    release_cache_lock
}

# Verify cache integrity
cache_verify() {
    local repair="${1:-false}"
    
    init_cache
    
    acquire_cache_lock 30 || {
        error "Could not acquire lock for cache verification"
        return 1
    }
    
    local issues=0
    local temp_index="$(mktemp)"
    
    info "Verifying cache integrity..."
    
    if [[ -f "$CACHE_INDEX_FILE" ]]; then
        while IFS=: read -r filename timestamp key; do
            [[ -n "$filename" ]] || continue
            
            local cache_file="$CACHE_DIR/data/$filename"
            
            # Check if cache file exists and is readable
            if [[ ! -f "$cache_file" ]]; then
                debug "Missing cache file for index entry: $filename"
                ((issues++))
                continue
            fi
            
            # Check if file is readable and non-empty
            if [[ ! -s "$cache_file" ]] || ! cat "$cache_file" >/dev/null 2>&1; then
                debug "Corrupted cache file: $cache_file"
                ((issues++))
                if [[ "$repair" == "true" ]]; then
                    rm -f "$cache_file"
                    debug "Removed corrupted cache file: $cache_file"
                fi
                continue
            fi
            
            # Keep valid entries
            echo "$filename:$timestamp:$key" >> "$temp_index"
        done < "$CACHE_INDEX_FILE"
        
        if [[ "$repair" == "true" && $issues -gt 0 ]]; then
            mv "$temp_index" "$CACHE_INDEX_FILE"
            info "Repaired cache: fixed $issues issues"
        else
            rm -f "$temp_index"
            if [[ $issues -gt 0 ]]; then
                warn "Found $issues cache integrity issues. Run with repair=true to fix."
            else
                ok "Cache integrity verified: no issues found"
            fi
        fi
    fi
    
    release_cache_lock
    return $issues
}

# Discover hash for a URL using multiple methods
discover_hash_fast() {
    local url="$1"
    local cache_key="hash:$(echo -n "$url" | sha256sum | cut -d' ' -f1)"
    
    # Try cache first
    local cached_hash
    if cached_hash=$(cache_get "$cache_key" 1440); then
        debug "Using cached hash for $url"
        echo "$cached_hash"
        return 0
    fi
    
    debug "Discovering hash for $url"
    
    local hash=""
    
    # Method 1: Try nix-prefetch-url (fastest)
    if command -v nix-prefetch-url >/dev/null 2>&1; then
        if hash=$(nix-prefetch-url --type sha256 "$url" 2>/dev/null); then
            # Convert to SRI format if needed
            if [[ "$hash" != sha256-* ]]; then
                hash=$(nix --extra-experimental-features 'nix-command' hash convert --hash-algo sha256 --to sri "$hash" 2>/dev/null || echo "sha256-$hash")
            fi
        fi
    fi
    
    # Method 2: Use nix eval with fake hash to get real hash from error
    if [[ -z "$hash" ]]; then
        local output
        if output=$(nix --extra-experimental-features 'nix-command flakes' eval --impure --expr "builtins.fetchurl { url = \"$url\"; sha256 = \"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\"; }" 2>&1); then
            warn "Expected hash mismatch but eval succeeded for $url"
            return 1
        fi
        # Extract hash from error message
        hash=$(echo "$output" | grep -o 'sha256[-:][A-Za-z0-9+/=]*' | tail -1)
    fi
    
    if [[ -z "$hash" ]]; then
        error "Could not discover hash for $url"
        return 1
    fi
    
    # Cache the result
    cache_set "$cache_key" "$hash"
    debug "Cached hash for $url: $hash"
    
    echo "$hash"
}

# Get repository files with caching
get_repo_files_fast() {
    local repo_id="$1"
    local ref="$2"
    
    local cache_key="files:${repo_id}:${ref}"
    
    # Try cache first (shorter TTL for file listings)
    local cached_files
    if cached_files=$(cache_get "$cache_key" 60); then
        debug "Using cached file listing for $repo_id"
        echo "$cached_files"
        return 0
    fi
    
    # repo_id now includes the type prefix (models/org/repo or datasets/org/repo)
    local url="https://huggingface.co/api/${repo_id}/tree/${ref}?recursive=true"
    
    debug "Fetching file tree from $url"
    local response
    local http_code
    local temp_response="$(mktemp)"
    
    http_code=$(curl -w "%{http_code}" -o "$temp_response" -sfL "$url" 2>/dev/null || echo "000")
    
    if [[ "$http_code" != "200" ]]; then
        if [[ "$http_code" == "404" ]]; then
            error "Repository not found: $repo_id"
        else
            error "Failed to fetch repository information (HTTP $http_code)"
        fi
        rm -f "$temp_response"
        return 1
    fi
    
    # Verify file exists and is readable
    if [[ ! -s "$temp_response" ]]; then
        error "Empty response from API"
        rm -f "$temp_response"
        return 1
    fi
    
    response=$(cat "$temp_response")
    rm -f "$temp_response"
    
    # Validate JSON response
    if ! echo "$response" | jq empty 2>/dev/null; then
        error "Invalid JSON response from $url"
        return 1
    fi
    
    cache_set "$cache_key" "$response"
    echo "$response"
}

# Create filter JSON with improved validation
create_filter_json_fast() {
    local filters=("$@")
    
    [[ ${#filters[@]} -eq 0 ]] && { echo "null"; return; }
    
    # Validate filter arguments come in pairs
    if (( ${#filters[@]} % 2 != 0 )); then
        error "Filter arguments must come in pairs (flag value)"
        return 1
    fi
    
    local type="" patterns=()
    
    for ((i=0; i<${#filters[@]}; i+=2)); do
        local flag="${filters[i]}" pattern="${filters[i+1]}"
        
        case "$flag" in
            --include)
                [[ -n "$type" && "$type" != "include" ]] && { error "Cannot mix filter types"; return 1; }
                type="include"
                ;;
            --exclude)
                [[ -n "$type" && "$type" != "exclude" ]] && { error "Cannot mix filter types"; return 1; }
                type="exclude"
                ;;
            --file)
                [[ -n "$type" && "$type" != "files" ]] && { error "Cannot mix filter types"; return 1; }
                type="files"
                ;;
            *)
                error "Unknown filter flag: $flag"
                return 1
                ;;
        esac
        
        # Escape pattern for JSON
        if [[ "$flag" == "--file" ]]; then
            # File patterns are literal
            pattern=$(printf '%s' "$pattern" | sed 's/\\/\\\\/g; s/"/\\"/g')
        else
            # Convert glob patterns to regex
            pattern=$(printf '%s' "$pattern" | sed 's/\*/\.\*/g; s/\?/\./g; s/\\/\\\\/g; s/"/\\"/g')
        fi
        
        patterns+=("\"$pattern\"")
    done
    
    if [[ ${#patterns[@]} -gt 0 ]]; then
        printf '{ %s = [ %s ]; }\n' "$type" "$(IFS=' '; echo "${patterns[*]}")"
    else
        echo "null"
    fi
}
