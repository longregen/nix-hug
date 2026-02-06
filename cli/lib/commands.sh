# Command implementations

source "${NIX_HUG_LIB_DIR}/hash.sh"
source "${NIX_HUG_LIB_DIR}/nix-expr.sh"

# Fetch command implementation
cmd_fetch() {
    local url=""
    local ref="main"
    local filters=()
    local auto_confirm=false
    
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
    
    # Sanitize URL
    local sanitized_url
    sanitized_url=$(sanitize_hf_url "$url") || return 1
    
    # Parse URL
    local parsed
    parsed=$(parse_url "$sanitized_url") || return 1
    
    local repo_id repo_type
    repo_id=$(echo "$parsed" | jq -r '.repoId')
    repo_type=$(echo "$parsed" | jq -r '.type')
    
    local display_name
    display_name=$(get_display_name "$repo_id")
    info "Retrieving information for $display_name ($ref)..."
    
    # Create filter JSON
    local filter_json
    filter_json=$(create_filter_json_fast "${filters[@]}") || return 1
    
    # Show filter information
    if [[ "$filter_json" != "null" ]]; then
        info "Using filters: $filter_json"
    fi
    
    info "Resolving revision..."

    # Resolve ref to a commit hash via the API
    local resolved_rev="$ref"
    if [[ ! "$ref" =~ ^[0-9a-f]{40}$ ]]; then
        local api_url="https://huggingface.co/api/$repo_id"
        local api_response
        api_response=$(curl -sfL "$api_url") || {
            error "Failed to fetch repository info from $api_url"
            return 1
        }
        resolved_rev=$(echo "$api_response" | jq -r '.sha // empty') || true
        if [[ -z "$resolved_rev" ]]; then
            error "Could not resolve ref '$ref' to a commit hash"
            return 1
        fi
        debug "Resolved '$ref' to commit hash: $resolved_rev"
    fi

    info "Discovering required hashes..."

    # Use resolved commit hash in the file tree URL for stability
    local file_tree_url="https://huggingface.co/api/$repo_id/tree/$resolved_rev"

    local file_tree_hash
    file_tree_hash=$(discover_hash_fast "$file_tree_url") || {
        error "Failed to discover hash for file tree"
        return 1
    }
    debug "File tree hash: $file_tree_hash"

    # Branch based on repository type
    if [[ "$repo_type" == "datasets" ]]; then
        # Handle dataset
        info "Building dataset with discovered hashes..."

        local derivation_cache_key
        derivation_cache_key="dataset-derivation:$(echo -n "${repo_id}:${resolved_rev}:${filter_json}:${file_tree_hash}" | sha256sum | cut -d' ' -f1)"

        local cached_derivation_hash
        if cached_derivation_hash=$(cache_get "$derivation_cache_key" 1440); then
            debug "Using cached derivation hash: $cached_derivation_hash"

            # Try direct build with cached hash
            if build_and_report_dataset "$repo_id" "$resolved_rev" "$filter_json" "$file_tree_hash" "$cached_derivation_hash"; then
                return 0
            else
                warn "Cached derivation hash failed, discovering new hash..."
            fi
        fi

        # Discover derivation hash
        local derivation_hash
        derivation_hash=$(discover_dataset_derivation_hash "$repo_id" "$resolved_rev" "$filter_json" "$file_tree_hash") || return 1

        # Cache the discovered hash
        cache_set "$derivation_cache_key" "$derivation_hash"

        # Final build
        info "Building final dataset..."
        build_and_report_dataset "$repo_id" "$resolved_rev" "$filter_json" "$file_tree_hash" "$derivation_hash"
    else
        # Handle model
        info "Building model with discovered hashes..."

        local derivation_cache_key
        derivation_cache_key="derivation:$(echo -n "${repo_id}:${resolved_rev}:${filter_json}:${file_tree_hash}" | sha256sum | cut -d' ' -f1)"

        local cached_derivation_hash
        if cached_derivation_hash=$(cache_get "$derivation_cache_key" 1440); then
            debug "Using cached derivation hash: $cached_derivation_hash"

            # Try direct build with cached hash
            if build_and_report "$repo_id" "$resolved_rev" "$filter_json" "$file_tree_hash" "$cached_derivation_hash"; then
                return 0
            else
                warn "Cached derivation hash failed, discovering new hash..."
            fi
        fi

        # Discover derivation hash
        local derivation_hash
        derivation_hash=$(discover_derivation_hash "$repo_id" "$resolved_rev" "$filter_json" "$file_tree_hash") || return 1

        # Cache the discovered hash
        cache_set "$derivation_cache_key" "$derivation_hash"

        # Final build
        info "Building final model..."
        build_and_report "$repo_id" "$resolved_rev" "$filter_json" "$file_tree_hash" "$derivation_hash"
    fi
}

# List command implementation
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
            --include|--exclude|--file)
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
    
    # Sanitize URL
    local sanitized_url
    sanitized_url=$(sanitize_hf_url "$url") || return 1
    
    # Parse URL and get file listing
    local parsed
    parsed=$(parse_url "$sanitized_url") || return 1
    
    local repo_id
    repo_id=$(echo "$parsed" | jq -r '.repoId')
    
    local files
    files=$(get_repo_files_fast "$repo_id" "$ref") || return 1
    
    # Get display name for output
    local display_name
    display_name=$(get_display_name "$repo_id")
    
    # Apply filters and display
    if [[ ${#filters[@]} -gt 0 ]]; then
        display_filtered_files "$files" "${filters[@]}"
    else
        display_files "$files" "Files in $display_name:"
    fi
}

# Helper function to build model and report results
build_and_report() {
    local repo_id="$1" ref="$2" filter_json="$3" file_tree_hash="$4" derivation_hash="$5"

    # Get bare repo path for Nix expression
    local bare_repo_path
    bare_repo_path=$(get_bare_repo_path "$repo_id")

    local expr
    expr=$(generate_fetch_model_expr "$bare_repo_path" "$ref" "$filter_json" "$file_tree_hash" "$derivation_hash")

    local store_path
    if store_path=$(build_model_with_expr "$expr" "Final build"); then
        ok "Model downloaded to: $store_path"

        # Use bare repo path for usage example
        generate_usage_example "$bare_repo_path" "$ref" "$filter_json" "$file_tree_hash" "$derivation_hash"
        return 0
    else
        error "Failed to build model: $store_path"
        return 1
    fi
}


# Helper function to build dataset and report results
build_and_report_dataset() {
    local repo_id="$1" ref="$2" filter_json="$3" file_tree_hash="$4" derivation_hash="$5"

    # Get bare repo path for Nix expression
    local bare_repo_path
    bare_repo_path=$(get_bare_repo_path "$repo_id")

    local expr
    expr=$(generate_fetch_dataset_expr "$bare_repo_path" "$ref" "$filter_json" "$file_tree_hash" "$derivation_hash")

    local store_path
    if store_path=$(build_dataset_with_expr "$expr" "Final build"); then
        ok "Dataset downloaded to: $store_path"

        # Use bare repo path for usage example
        generate_dataset_usage_example "$bare_repo_path" "$ref" "$filter_json" "$file_tree_hash" "$derivation_hash"
        return 0
    else
        error "Failed to build dataset: $store_path"
        return 1
    fi
}

# Helper function to discover dataset derivation hash
discover_dataset_derivation_hash() {
    local repo_id="$1" ref="$2" filter_json="$3" file_tree_hash="$4"

    # Get bare repo path for Nix expression
    local bare_repo_path
    bare_repo_path=$(get_bare_repo_path "$repo_id")

    local expr
    expr=$(generate_fetch_dataset_expr "$bare_repo_path" "$ref" "$filter_json" "$file_tree_hash" "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
    
    local build_output
    if build_output=$(build_dataset_with_expr "$expr" "Hash discovery" 2>&1); then
        # Unexpected success
        warn "Build succeeded unexpectedly during hash discovery"
        return 1
    else
        debug "Hash discovery output: $build_output"
        local derivation_hash
        derivation_hash=$(extract_derivation_hash "$build_output")
        
        if [[ -z "$derivation_hash" ]]; then
            error "Could not extract derivation hash from build output"
            echo "Build output:" >&2
            echo "$build_output" >&2
            return 1
        fi
        
        debug "Extracted derivation hash: $derivation_hash"
        echo "$derivation_hash"
    fi
}

# Helper function to discover derivation hash
discover_derivation_hash() {
    local repo_id="$1" ref="$2" filter_json="$3" file_tree_hash="$4"

    # Get bare repo path for Nix expression
    local bare_repo_path
    bare_repo_path=$(get_bare_repo_path "$repo_id")

    local expr
    expr=$(generate_fetch_model_expr "$bare_repo_path" "$ref" "$filter_json" "$file_tree_hash" "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
    
    local build_output
    if build_output=$(build_model_with_expr "$expr" "Hash discovery" 2>&1); then
        # Unexpected success
        warn "Build succeeded unexpectedly during hash discovery"
        return 1
    else
        debug "Hash discovery output: $build_output"
        local derivation_hash
        derivation_hash=$(extract_derivation_hash "$build_output")
        
        if [[ -z "$derivation_hash" ]]; then
            error "Could not extract derivation hash from build output"
            echo "Build output:" >&2
            echo "$build_output" >&2
            return 1
        fi
        
        debug "Extracted derivation hash: $derivation_hash"
        echo "$derivation_hash"
    fi
}

# Cache management command
cmd_cache() {
    local action=""
    local max_age="1440"  # 24 hours
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            clean|cleanup)
                action="clean"
                shift
                ;;
            verify)
                action="verify"
                shift
                ;;
            repair)
                action="repair"
                shift
                ;;
            stats)
                action="stats"
                shift
                ;;
            --max-age)
                max_age="$2"
                shift 2
                ;;
            --help|-h)
                show_cache_help
                return 0
                ;;
            *)
                error "Unknown cache action: $1"
                show_cache_help
                return 1
                ;;
        esac
    done
    
    [[ -z "$action" ]] && {
        show_cache_help
        return 1
    }
    
    case "$action" in
        clean)
            info "Cleaning cache entries older than ${max_age} minutes..."
            cache_cleanup "$max_age"
            ;;
        verify)
            cache_verify false
            ;;
        repair)
            cache_verify true
            ;;
        stats)
            show_cache_stats
            ;;
    esac
}

# Show cache command help
show_cache_help() {
    cat << EOH
${BOLD}Cache Management${NC}

${BOLD}USAGE:${NC}
    nix-hug cache <ACTION> [OPTIONS]

${BOLD}ACTIONS:${NC}
    clean       Remove expired cache entries
    verify      Check cache integrity
    repair      Fix cache corruption issues
    stats       Show cache statistics

${BOLD}OPTIONS:${NC}
    --max-age MINUTES   Age threshold for cleanup (default: 1440 = 24h)
    --help              Show this help

${BOLD}EXAMPLES:${NC}
    nix-hug cache clean
    nix-hug cache clean --max-age 60
    nix-hug cache verify
    nix-hug cache repair
    nix-hug cache stats
EOH
}

# Show cache statistics
show_cache_stats() {
    init_cache
    
    info "Cache Statistics:"
    echo
    
    local cache_dir_size=0
    local file_count=0
    local index_entries=0
    
    if [[ -d "$CACHE_DIR/data" ]]; then
        cache_dir_size=$(du -sb "$CACHE_DIR/data" 2>/dev/null | cut -f1 || echo 0)
        file_count=$(find "$CACHE_DIR/data" -type f 2>/dev/null | wc -l || echo 0)
    fi
    
    if [[ -f "$CACHE_INDEX_FILE" ]]; then
        index_entries=$(wc -l < "$CACHE_INDEX_FILE" 2>/dev/null || echo 0)
    fi
    
    echo "  Cache Directory: $CACHE_DIR"
    echo "  Total Size: $(format_size "$cache_dir_size")"
    echo "  Cache Files: $file_count"
    echo "  Index Entries: $index_entries"
    
    if [[ $file_count -ne $index_entries ]]; then
        warn "Index mismatch detected\! Run 'nix-hug cache verify' to check integrity."
    fi
    
    echo
    echo "Recent cache activity:"
    if [[ -f "$CACHE_INDEX_FILE" && -s "$CACHE_INDEX_FILE" ]]; then
        tail -5 "$CACHE_INDEX_FILE" | while IFS=: read -r filename timestamp key; do
            local date_str
            date_str=$(date -d "@$timestamp" 2>/dev/null || echo "unknown")
            echo "  $(echo "$key" | cut -c1-50)... ($date_str)"
        done
    else
        echo "  No cache entries found"
    fi
}
