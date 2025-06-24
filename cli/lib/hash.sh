CACHE_INDEX_FILE="$CACHE_DIR/cache-index"

init_cache() {
    mkdir -p "$CACHE_DIR/data"
    [[ -f "$CACHE_INDEX_FILE" ]] || touch "$CACHE_INDEX_FILE"
}

cache_get() {
    local key="$1"
    local ttl_minutes="$2"
    
    init_cache
    
    local cache_file="$CACHE_DIR/data/$(echo -n "$key" | sha256sum | cut -d' ' -f1)"
    
    if [[ -f "$cache_file" ]]; then
        local file_age_minutes
        file_age_minutes=$(( ($(date +%s) - $(stat -c %Y "$cache_file")) / 60 ))
        
        if (( file_age_minutes < ttl_minutes )); then
            cat "$cache_file"
            return 0
        else
            # Clean up expired cache
            rm -f "$cache_file"
            # Remove from index
            grep -v "^$(basename "$cache_file"):" "$CACHE_INDEX_FILE" > "$CACHE_INDEX_FILE.tmp" 2>/dev/null || true
            mv "$CACHE_INDEX_FILE.tmp" "$CACHE_INDEX_FILE" 2>/dev/null || true
        fi
    fi
    
    return 1
}

cache_set() {
    local key="$1"
    local value="$2"
    
    init_cache
    
    local cache_file="$CACHE_DIR/data/$(echo -n "$key" | sha256sum | cut -d' ' -f1)"
    
    echo "$value" > "$cache_file"
    
    local now
    now=$(date +%s)
    local basename_file
    basename_file=$(basename "$cache_file")
    
    grep -v "^$basename_file:" "$CACHE_INDEX_FILE" > "$CACHE_INDEX_FILE.tmp" 2>/dev/null || true
    echo "$basename_file:$now:$key" >> "$CACHE_INDEX_FILE.tmp"
    mv "$CACHE_INDEX_FILE.tmp" "$CACHE_INDEX_FILE"
}

cache_cleanup() {
    local max_age_minutes="${1:-1440}" # Default 24 hours
    
    init_cache
    
    local now
    now=$(date +%s)
    
    while IFS=: read -r filename timestamp key; do
        [[ -n "$filename" ]] || continue
        local age_minutes=$(( (now - timestamp) / 60 ))
        
        if (( age_minutes > max_age_minutes )); then
            rm -f "$CACHE_DIR/data/$filename"
            debug "Cleaned expired cache entry: $key"
        fi
    done < "$CACHE_INDEX_FILE"
    
    local temp_index
    temp_index=$(mktemp)
    while IFS=: read -r filename timestamp key; do
        [[ -n "$filename" ]] || continue
        if [[ -f "$CACHE_DIR/data/$filename" ]]; then
            echo "$filename:$timestamp:$key" >> "$temp_index"
        fi
    done < "$CACHE_INDEX_FILE"
    mv "$temp_index" "$CACHE_INDEX_FILE"
}

discover_hash_fast() {
    local url="$1"
    local cache_key
    cache_key="hash:$(echo -n "$url" | sha256sum | cut -d' ' -f1)"
    
    local cached_hash
    if cached_hash=$(cache_get "$cache_key" 1440); then
        debug "Using cached hash for $url"
        echo "$cached_hash"
        return 0
    fi
    
    debug "Discovering hash for $url"
    
    local hash
    if command -v nix-prefetch-url >/dev/null 2>&1; then
        if hash=$(timeout 30s nix-prefetch-url --type sha256 "$url" 2>/dev/null); then
            if [[ "$hash" != sha256-* ]]; then
                hash=$(nix hash convert --hash-algo sha256 --to sri "$hash" 2>/dev/null || echo "sha256-$hash")
            fi
        fi
    fi
    
    if [[ -z "$hash" ]]; then
        local output
        if output=$(timeout 30s nix eval --impure --expr "builtins.fetchurl { url = \"$url\"; sha256 = \"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\"; }" 2>&1); then
            error "Expected hash mismatch but eval succeeded"
            return 1
        fi
        hash=$(echo "$output" | grep -o 'sha256[-:][A-Za-z0-9+/=]*' | tail -1)
    fi
    
    if [[ -z "$hash" ]]; then
        error "Could not discover hash for $url"
        return 1
    fi
    
    cache_set "$cache_key" "$hash"
    debug "Cached hash for $url: $hash"
    
    echo "$hash"
}

get_repo_files_fast() {
    local repo_id="$1"
    local ref="$2"
    
    local cache_key="files:${repo_id}:${ref}"
    
    local cached_files
    if cached_files=$(cache_get "$cache_key" 60); then
        debug "Using cached file listing for $repo_id"
        echo "$cached_files"
        return 0
    fi
    
    local url="https://huggingface.co/api/models/${repo_id}/tree/${ref}"
    local response
    
    debug "Fetching file tree from $url"
    if ! response=$(timeout 30s curl -sfL "$url"); then
        error "Failed to fetch repository information"
        return 1
    fi
    
    cache_set "$cache_key" "$response"
    
    echo "$response"
}

create_filter_json_fast() {
    local filters=("$@")
    
    [[ ${#filters[@]} -eq 0 ]] && { echo "null"; return; }
    
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
        esac
        
        if [[ "$flag" == "--file" ]]; then
            pattern=$(printf '%s' "$pattern" | sed 's/\\/\\\\/g; s/"/\\"/g')
        else
            pattern=$(printf '%s' "$pattern" | sed 's/\*/\.\*/g; s/\?/\./g; s/\\/\\\\/g; s/"/\\"/g')
        fi
        
        patterns+=("\"$pattern\"")
    done
    
    [[ ${#patterns[@]} -gt 0 ]] && printf '{ %s = [ %s ]; }\n' "$type" "${patterns[*]}" || echo "null"
}

build_model_fast() {
    local repo_id="$1"
    local ref="$2"
    local filter_json="$3"
    local repo_info_hash="$4"
    local file_tree_hash="$5"
    
    local expr
    expr=$(cat <<EOF
let
  flake = builtins.getFlake "$(get_flake_path)";
  lib = flake.lib.\${builtins.currentSystem};
  
  result = lib.fetchModel {
    url = "$repo_id";
    rev = "$ref";
    filters = $filter_json;
    repoInfoHash = "$repo_info_hash";
    fileTreeHash = "$file_tree_hash";
    derivationHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  };
in result
EOF
)
    
    debug "Build expression: $expr"
    
    local build_output derivation_hash
    if build_output=$(nix build --impure --expr "$expr" --no-link --print-out-paths 2>&1); then
        ok "Model downloaded to: $build_output"
        echo "$build_output"
        return 0
    else
        debug "Build output: $build_output"
        derivation_hash=$(echo "$build_output" | grep -o 'sha256-[A-Za-z0-9+/=]*' | tail -1)
        
        if [[ -z "$derivation_hash" ]]; then
            error "Could not extract derivation hash from build output"
            return 1
        fi
        
        debug "Extracted derivation hash: $derivation_hash"
        
        expr=$(cat <<EOF
let
  flake = builtins.getFlake "$(get_flake_path)";
  lib = flake.lib.\${builtins.currentSystem};
in
  lib.fetchModel {
    url = "$repo_id";
    rev = "$ref";
    filters = $filter_json;
    repoInfoHash = "$repo_info_hash";
    fileTreeHash = "$file_tree_hash";
    derivationHash = "$derivation_hash";
  }
EOF
)
        
        local store_path
        if store_path=$(nix build --impure --expr "$expr" --no-link --print-out-paths 2>&1); then
            ok "Model downloaded to: $store_path"
            echo "$store_path"
            echo "$derivation_hash"
            return 0
        else
            error "Failed to build final model: $store_path"
            return 1
        fi
    fi
}
