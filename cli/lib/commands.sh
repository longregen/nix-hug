# Command implementations

source "${NIX_HUG_LIB_DIR}/hash.sh"

cmd_fetch() {
    local url=""
    local ref="main"
    local filters=()
    local auto_confirm=false
    local dry_run=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --ref)
                ref="$2"
                shift 2
                ;;
            --include|--exclude|--file)
                filters+=("$1" "$2")
                shift 2
                ;;
            --yes|-y)
                auto_confirm=true
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            -*)
                error "Unknown option: $1"
                return 1
                ;;
            *)
                url="$1"
                shift
                ;;
        esac
    done
    
    [[ -z "$url" ]] && { error "No repository URL specified"; return 1; }
    
    # Parse URL
    local parsed
    parsed=$(parse_url "$url") || return 1
    
    local repo_id
    repo_id=$(echo "$parsed" | jq -r '.repoId')
    
    # Get repository info and build model
    info "Retrieving information for $repo_id ($ref)..."
    
    local filter_json
    filter_json=$(create_filter_json_fast "${filters[@]}")
    
    # Show filter information
    if [[ "$filter_json" != "null" ]]; then
        info "Using filters: $filter_json"
    fi
    
    # Dry run mode - just show what would be done
    if [[ "$dry_run" == "true" ]]; then
        info "DRY RUN MODE - No actual download will occur"
        echo "Would fetch: $repo_id"
        echo "Reference: $ref"
        if [[ "$filter_json" != "null" ]]; then
            echo "Filters: $filter_json"
        fi
        return 0
    fi
    
    info "Discovering required hashes..."
    
    # Step 1: Discover API hashes using fast methods
    local repo_info_url="https://huggingface.co/api/models/$repo_id"
    local file_tree_url="https://huggingface.co/api/models/$repo_id/tree/$ref"
    
    local repo_info_hash file_tree_hash
    repo_info_hash=$(discover_hash_fast "$repo_info_url") || {
        error "Failed to discover hash for repository info"
        return 1
    }
    debug "Repository info hash: $repo_info_hash"
    
    file_tree_hash=$(discover_hash_fast "$file_tree_url") || {
        error "Failed to discover hash for file tree"
        return 1
    }
    debug "File tree hash: $file_tree_hash"
    
    # Step 2: Try to get cached derivation hash or build optimally
    info "Building model with discovered hashes..."
    
    # Create cache key for derivation hash
    local derivation_cache_key
    derivation_cache_key="derivation:$(echo -n "${repo_id}:${ref}:${filter_json}:${repo_info_hash}:${file_tree_hash}" | sha256sum | cut -d' ' -f1)"
    
    # Try cached derivation hash first (24 hours = 1440 minutes)
    local cached_derivation_hash
    if cached_derivation_hash=$(cache_get "$derivation_cache_key" 1440); then
        debug "Using cached derivation hash: $cached_derivation_hash"
        
        # Direct build with cached hash
        local expr
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
    derivationHash = "$cached_derivation_hash";
  }
EOF
)
        debug "Direct build expression: $expr"
        
        local store_path
        if store_path=$(nix build --impure --expr "$expr" --no-link --print-out-paths 2>&1); then
            ok "Model downloaded to: $store_path"
            generate_usage_example "$repo_id" "$ref" "$filter_json" "$repo_info_hash" "$file_tree_hash" "$cached_derivation_hash"
            return 0
        else
            warn "Cached derivation hash failed, discovering new hash..."
            # Continue to hash discovery below
        fi
    fi
    
    # Step 3: Discover derivation hash (only if not cached or cache failed)
    local expr
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
    derivationHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  }
EOF
)
    debug "Hash discovery build expression: $expr"
    
    # This will fail with hash mismatch - extract the real derivation hash
    local build_output derivation_hash
    if build_output=$(nix build --impure --expr "$expr" --no-link 2>&1); then
        # Unexpected success - this shouldn't happen with fake hash
        warn "Build succeeded unexpectedly - using result $build_output"
        ok "Model downloaded to: $build_output"
        return 0
    else
        debug "Build output: $build_output"
        # Extract real hash from error
        derivation_hash=$(echo "$build_output" | grep -o 'sha256-[A-Za-z0-9+/=]*' | tail -1)
        
        if [[ -z "$derivation_hash" ]]; then
            error "Could not extract derivation hash from build output"
            echo "Build output:" >&2
            echo "$build_output" >&2
            return 1
        fi
        
        debug "Extracted derivation hash: $derivation_hash"
        
        # Cache the discovered derivation hash
        cache_set "$derivation_cache_key" "$derivation_hash"
        
        # Step 4: Build with all correct hashes
        info "Building final model..."
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
        debug "Final build expression: $expr"
        
        local store_path
        if store_path=$(nix build --impure --expr "$expr" --no-link --print-out-paths 2>&1); then
            ok "Model downloaded to: $store_path"
            generate_usage_example "$repo_id" "$ref" "$filter_json" "$repo_info_hash" "$file_tree_hash" "$derivation_hash"
        else
            error "Failed to build final model: $store_path"
            return 1
        fi
    fi
}

cmd_ls() {
    local url=""
    local ref="main"
    local filters=()
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --ref)
                ref="$2"
                shift 2
                ;;
            --include|--exclude)
                filters+=("$1" "$2")
                shift 2
                ;;
            -*)
                error "Unknown option: $1"
                return 1
                ;;
            *)
                url="$1"
                shift
                ;;
        esac
    done
    
    [[ -z "$url" ]] && { error "No repository URL specified"; return 1; }
    
    # Parse URL and get file listing
    local parsed
    parsed=$(parse_url "$url") || return 1
    
    local repo_id
    repo_id=$(echo "$parsed" | jq -r '.repoId')
    
    local files
    files=$(get_repo_files_fast "$repo_id" "$ref") || return 1
    
    # Apply filters and display
    if [[ ${#filters[@]} -gt 0 ]]; then
        display_filtered_files "$files" "${filters[@]}"
    else
        display_files "$files" "Files in $(echo "$parsed" | jq -r '.repoId'):"
    fi
}
