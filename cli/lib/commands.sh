# Command implementations

source "${NIX_HUG_LIB_DIR}/hash.sh"
source "${NIX_HUG_LIB_DIR}/nix-expr.sh"
source "${NIX_HUG_LIB_DIR}/persist.sh"

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
            --help|-h)
                show_fetch_help
                return 0
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

    info "Discovering file tree hash..."

    # Use resolved commit hash in the file tree URL for stability
    local file_tree_url="https://huggingface.co/api/$repo_id/tree/$resolved_rev"

    local file_tree_hash
    file_tree_hash=$(discover_hash_fast "$file_tree_url") || {
        error "Failed to discover hash for file tree"
        return 1
    }
    debug "File tree hash: $file_tree_hash"

    # Build (single pass — no derivation hash needed)
    if [[ "$repo_type" == "datasets" ]]; then
        info "Building dataset..."
        build_and_report_dataset "$repo_id" "$resolved_rev" "$filter_json" "$file_tree_hash"
    else
        info "Building model..."
        build_and_report "$repo_id" "$resolved_rev" "$filter_json" "$file_tree_hash"
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
            --help|-h)
                show_ls_help
                return 0
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
    local repo_id="$1" ref="$2" filter_json="$3" file_tree_hash="$4"

    # Get bare repo path for Nix expression and manifest ID
    local bare_repo_path
    bare_repo_path=$(get_bare_repo_path "$repo_id")

    # Auto-persist: try importing from persistent storage before building
    if [[ "$AUTO_PERSIST" == "true" ]]; then
        local imported_path
        if imported_path=$(persist_try_import "$bare_repo_path" "$ref"); then
            ok "Model restored from persistent storage: $imported_path"
            generate_usage_example "$bare_repo_path" "$ref" "$filter_json" "$file_tree_hash"
            return 0
        fi
    fi

    local expr
    expr=$(generate_fetch_model_expr "$bare_repo_path" "$ref" "$filter_json" "$file_tree_hash")

    local build_output
    if build_output=$(build_model_with_expr "$expr" "Build"); then
        local store_path
        if ! store_path=$(extract_store_path "$build_output"); then
            error "Could not find store path in build output"
            debug "Build output was: $build_output"
            return 1
        fi
        ok "Model downloaded to: $store_path"

        # Auto-persist: export after successful build
        if [[ "$AUTO_PERSIST" == "true" && -n "$PERSIST_DIR" ]]; then
            persist_export "$store_path" "$bare_repo_path" "model" "$ref" "$filter_json" || true
        fi

        # Use bare repo path for usage example
        generate_usage_example "$bare_repo_path" "$ref" "$filter_json" "$file_tree_hash"
        return 0
    else
        error "Failed to build model: $build_output"
        return 1
    fi
}


# Helper function to build dataset and report results
build_and_report_dataset() {
    local repo_id="$1" ref="$2" filter_json="$3" file_tree_hash="$4"

    # Get bare repo path for Nix expression and manifest ID
    local bare_repo_path
    bare_repo_path=$(get_bare_repo_path "$repo_id")

    # Auto-persist: try importing from persistent storage before building
    if [[ "$AUTO_PERSIST" == "true" ]]; then
        local imported_path
        if imported_path=$(persist_try_import "$bare_repo_path" "$ref"); then
            ok "Dataset restored from persistent storage: $imported_path"
            generate_dataset_usage_example "$bare_repo_path" "$ref" "$filter_json" "$file_tree_hash"
            return 0
        fi
    fi

    local expr
    expr=$(generate_fetch_dataset_expr "$bare_repo_path" "$ref" "$filter_json" "$file_tree_hash")

    local build_output
    if build_output=$(build_dataset_with_expr "$expr" "Build"); then
        local store_path
        if ! store_path=$(extract_store_path "$build_output"); then
            error "Could not find store path in build output"
            debug "Build output was: $build_output"
            return 1
        fi
        ok "Dataset downloaded to: $store_path"

        # Auto-persist: export after successful build
        if [[ "$AUTO_PERSIST" == "true" && -n "$PERSIST_DIR" ]]; then
            persist_export "$store_path" "$bare_repo_path" "dataset" "$ref" "$filter_json" || true
        fi

        # Use bare repo path for usage example
        generate_dataset_usage_example "$bare_repo_path" "$ref" "$filter_json" "$file_tree_hash"
        return 0
    else
        error "Failed to build dataset: $build_output"
        return 1
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

# Export command — fetch + persist to binary cache
cmd_export() {
    local url=""
    local ref="main"
    local filters=()

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
            --help|-h)
                show_export_help
                return 0
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

    [[ -z "$url" ]] && { error "No repository URL specified"; show_export_help; return 1; }
    require_persist_dir || return 1

    # Sanitize URL
    local sanitized_url
    sanitized_url=$(sanitize_hf_url "$url") || return 1

    local parsed
    parsed=$(parse_url "$sanitized_url") || return 1

    local repo_id repo_type
    repo_id=$(echo "$parsed" | jq -r '.repoId')
    repo_type=$(echo "$parsed" | jq -r '.type')

    local display_name
    display_name=$(get_display_name "$repo_id")
    info "Exporting $display_name ($ref)..."

    # Create filter JSON
    local filter_json
    filter_json=$(create_filter_json_fast "${filters[@]}") || return 1

    # Resolve ref
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
    fi

    # Discover file tree hash
    local file_tree_url="https://huggingface.co/api/$repo_id/tree/$resolved_rev"
    local file_tree_hash
    file_tree_hash=$(discover_hash_fast "$file_tree_url") || {
        error "Failed to discover hash for file tree"
        return 1
    }

    # Build
    local bare_repo_path
    bare_repo_path=$(get_bare_repo_path "$repo_id")

    local build_output
    if [[ "$repo_type" == "datasets" ]]; then
        local expr
        expr=$(generate_fetch_dataset_expr "$bare_repo_path" "$resolved_rev" "$filter_json" "$file_tree_hash")
        build_output=$(build_dataset_with_expr "$expr" "Build") || {
            error "Failed to build dataset"
            return 1
        }
    else
        local expr
        expr=$(generate_fetch_model_expr "$bare_repo_path" "$resolved_rev" "$filter_json" "$file_tree_hash")
        build_output=$(build_model_with_expr "$expr" "Build") || {
            error "Failed to build model"
            return 1
        }
    fi

    # Extract the actual store path from build output
    local store_path
    if ! store_path=$(extract_store_path "$build_output"); then
        error "Could not find store path in build output"
        return 1
    fi

    # Export to persistent storage — use bare org/repo as the manifest ID
    local type_label="model"
    [[ "$repo_type" == "datasets" ]] && type_label="dataset"
    persist_export "$store_path" "$bare_repo_path" "$type_label" "$resolved_rev" "$filter_json" || return 1

    ok "Store path: $store_path"
}

# Import command — restore from persistent binary cache
cmd_import() {
    local url=""
    local ref=""
    local import_all=false
    local auto_confirm=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --all)
                import_all=true
                shift
                ;;
            --ref)
                ref="$2"
                shift 2
                ;;
            --yes|-y|--no-check-sigs)
                auto_confirm=true
                shift
                ;;
            --help|-h)
                show_import_help
                return 0
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

    require_persist_dir || return 1

    # Confirm trust for --no-check-sigs (unless --yes was passed)
    if [[ "$auto_confirm" == "true" ]]; then
        PERSIST_IMPORT_TRUSTED=true
    else
        confirm_import_trust || return 1
    fi

    if [[ "$import_all" == "true" ]]; then
        # Import all entries
        local manifest
        manifest=$(manifest_read)
        local count
        count=$(echo "$manifest" | jq 'length')

        if [[ "$count" -eq 0 ]]; then
            echo "No models in persistent storage to import."
            return 0
        fi

        local failures=0
        while IFS= read -r entry; do
            local store_path repo_id
            store_path=$(echo "$entry" | jq -r '.storePath')
            repo_id=$(echo "$entry" | jq -r '.repoId')

            # Skip if already valid
            if nix-store --check-validity "$store_path" 2>/dev/null; then
                debug "$repo_id already valid in store"
                continue
            fi

            if persist_import "$store_path"; then
                ok "Restored: $repo_id → $store_path"
            else
                warn "Failed to restore: $repo_id"
                failures=$((failures + 1))
            fi
        done < <(echo "$manifest" | jq -c '.[]')

        if [[ "$failures" -gt 0 ]]; then
            error "$failures import(s) failed"
            return 1
        fi
        return 0
    fi

    [[ -z "$url" ]] && { error "No repository URL specified (use --all to import everything)"; show_import_help; return 1; }

    # Sanitize URL
    local sanitized_url
    sanitized_url=$(sanitize_hf_url "$url") || return 1

    local parsed
    parsed=$(parse_url "$sanitized_url") || return 1

    local repo_id bare_repo_path
    repo_id=$(echo "$parsed" | jq -r '.repoId')
    bare_repo_path=$(get_bare_repo_path "$repo_id")

    # Look up in manifest — try the ref as-is first
    local entry=""
    if [[ -n "$ref" ]]; then
        entry=$(manifest_lookup "$bare_repo_path" "$ref" 2>/dev/null) || true
    fi

    # If not found and ref is a branch name, try resolving via API
    if [[ -z "$entry" && -n "$ref" && ! "$ref" =~ ^[0-9a-f]{40}$ ]]; then
        local api_url="https://huggingface.co/api/$repo_id"
        local api_response resolved_rev
        if api_response=$(curl -sfL "$api_url" 2>/dev/null); then
            resolved_rev=$(echo "$api_response" | jq -r '.sha // empty') || true
            if [[ -n "$resolved_rev" ]]; then
                entry=$(manifest_lookup "$bare_repo_path" "$resolved_rev" 2>/dev/null) || true
            fi
        fi
    fi

    # If no ref given, look up most recent entry
    if [[ -z "$entry" && -z "$ref" ]]; then
        entry=$(manifest_lookup "$bare_repo_path" 2>/dev/null) || true
    fi

    if [[ -z "$entry" ]]; then
        error "No entry found for $repo_id in persistent storage"
        return 1
    fi

    local store_path
    store_path=$(echo "$entry" | jq -r '.storePath')

    # Check if already valid
    if nix-store --check-validity "$store_path" 2>/dev/null; then
        ok "Already in store: $store_path"
        return 0
    fi

    persist_import "$store_path" || return 1
    ok "Restored: $store_path"
}

# Store management command
cmd_store() {
    local action=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            ls|list)
                action="ls"
                shift
                ;;
            path)
                action="path"
                shift
                ;;
            --help|-h)
                show_store_help
                return 0
                ;;
            *)
                error "Unknown store action: $1"
                show_store_help
                return 1
                ;;
        esac
    done

    [[ -z "$action" ]] && {
        show_store_help
        return 1
    }

    case "$action" in
        ls)
            persist_list
            ;;
        path)
            if [[ -z "$PERSIST_DIR" ]]; then
                error "No persist directory configured"
                return 1
            fi
            echo "$PERSIST_DIR"
            ;;
    esac
}
