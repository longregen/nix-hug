source "${NIX_HUG_LIB_DIR}/hash.sh"
source "${NIX_HUG_LIB_DIR}/nix-expr.sh"
source "${NIX_HUG_LIB_DIR}/persist.sh"

cmd_fetch() {
    local url=""
    local ref="main"
    local filters=()
    local out_dir=""
    local override=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --ref)
                [[ -z "${2:-}" || "$2" == -* ]] && { error "--ref requires an argument"; return 1; }
                ref="$2"
                shift 2
                ;;
            --include|--exclude|--file)
                [[ -z "${2:-}" || "$2" == -* ]] && { error "$1 requires an argument"; return 1; }
                filters+=("$1" "$2")
                shift 2
                ;;
            --out|-o)
                [[ -z "${2:-}" || "$2" == -* ]] && { error "--out requires a directory argument"; return 1; }
                out_dir="$2"
                shift 2
                ;;
            --override)
                override=true
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

    if [[ "$override" == "true" && -z "$out_dir" ]]; then
        warn "--override has no effect without --out"
    fi

    if [[ -n "$out_dir" ]]; then
        validate_out_dir "$out_dir" || return 1
    fi

    local sanitized_url
    sanitized_url=$(sanitize_hf_url "$url") || return 1

    local parsed
    parsed=$(parse_url "$sanitized_url") || return 1

    local repo_id repo_type
    repo_id=$(echo "$parsed" | jq -r '.repoId')
    repo_type=$(echo "$parsed" | jq -r '.type')

    local display_name
    display_name=$(get_display_name "$repo_id")
    info "Retrieving information for $display_name ($ref)..."

    local filter_json
    filter_json=$(create_filter_json_fast "${filters[@]}") || return 1

    if [[ "$filter_json" != "null" ]]; then
        info "Using filters: $filter_json"
    fi

    info "Resolving revision..."

    local resolved_rev
    resolved_rev=$(resolve_ref "$ref" "$repo_id") || return 1

    info "Discovering file tree hash..."

    local file_tree_url="https://huggingface.co/api/$repo_id/tree/$resolved_rev"

    local file_tree_hash
    file_tree_hash=$(discover_hash_fast "$file_tree_url") || {
        error "Failed to discover hash for file tree"
        return 1
    }
    debug "File tree hash: $file_tree_hash"

    local type="model"
    [[ "$repo_type" == "datasets" ]] && type="dataset"

    info "Building ${type}..."
    build_and_report "$repo_id" "$resolved_rev" "$filter_json" "$file_tree_hash" "$out_dir" "$override" "$type"
}

cmd_ls() {
    local url=""
    local ref="main"
    local filters=()

    while [[ $# -gt 0 ]]; do
        case $1 in
            --ref)
                [[ -z "${2:-}" || "$2" == -* ]] && { error "--ref requires an argument"; return 1; }
                ref="$2"
                shift 2
                ;;
            --include|--exclude|--file)
                [[ -z "${2:-}" || "$2" == -* ]] && { error "$1 requires an argument"; return 1; }
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

    local sanitized_url
    sanitized_url=$(sanitize_hf_url "$url") || return 1

    local parsed
    parsed=$(parse_url "$sanitized_url") || return 1

    local repo_id
    repo_id=$(echo "$parsed" | jq -r '.repoId')

    local files
    files=$(get_repo_files_fast "$repo_id" "$ref") || return 1

    local display_name
    display_name=$(get_display_name "$repo_id")

    if [[ ${#filters[@]} -gt 0 ]]; then
        display_filtered_files "$files" "${filters[@]}"
    else
        display_files "$files" "Files in $display_name:"
    fi
}

validate_out_dir() {
    local out_dir="$1"
    local resolved_out
    resolved_out=$(realpath -m "$out_dir" 2>/dev/null || echo "$out_dir")
    case "$resolved_out" in
        /|/home|/nix|/nix/store|/etc|/usr|/var|/tmp|/boot|/dev|/proc|/sys|/run|/opt|/srv|/lib|/lib64|/sbin|/bin|/root|/mnt|/media)
            error "Refusing to use system directory as output: $resolved_out"
            return 1
            ;;
    esac
    if [[ "$resolved_out" == "$HOME" ]]; then
        error "Refusing to use home directory as output: $resolved_out"
        return 1
    fi
}

copy_to_out_dir() {
    local store_path="$1" out_dir="$2" override="$3"
    local repo_id="${4:-}" type="${5:-}" rev="${6:-}" filters="${7:-null}"

    validate_out_dir "$out_dir" || return 1

    if [[ -d "$out_dir" ]] && [[ -n "$(ls -A "$out_dir" 2>/dev/null)" ]]; then
        if [[ "$override" != "true" ]]; then
            error "Output directory is not empty: $out_dir"
            error "Use --override to replace it"
            return 1
        fi
        info "Overriding existing output directory..."
        rm -rf "$out_dir"
    fi

    mkdir -p "$out_dir"
    cp -rT "$store_path" "$out_dir"
    chmod -R u+w "$out_dir"

    jq -n \
        --arg repoId "$repo_id" \
        --arg type "$type" \
        --arg rev "$rev" \
        --arg filters "$filters" \
        --arg storePath "$store_path" \
        --arg exportedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{repoId:$repoId,type:$type,rev:$rev,filters:$filters,storePath:$storePath,exportedAt:$exportedAt}' \
        > "$out_dir/.nix-hug.json"

    local src_count dst_count
    src_count=$(find "$store_path" -type f | wc -l)
    dst_count=$(find "$out_dir" -type f | wc -l)
    if (( dst_count != src_count + 1 )); then
        warn "File count mismatch: source=$src_count, target=$((dst_count - 1))"
    fi

    ok "Copied to: $out_dir"
    info "To add back to Nix store: nix-hug import --path '$out_dir'"
}

build_and_report() {
    local repo_id="$1" ref="$2" filter_json="$3" file_tree_hash="$4"
    local out_dir="${5:-}" override="${6:-false}" type="${7:-model}"

    local nix_func="fetchModel"
    [[ "$type" == "dataset" ]] && nix_func="fetchDataset"
    local label="${type^}"

    local bare_repo_path
    bare_repo_path=$(get_bare_repo_path "$repo_id")

    if [[ "$AUTO_PERSIST" == "true" ]]; then
        local imported_path
        if imported_path=$(persist_try_import "$bare_repo_path" "$ref"); then
            ok "$label restored from persistent storage: $imported_path"
            if [[ -n "$out_dir" ]]; then
                copy_to_out_dir "$imported_path" "$out_dir" "$override" \
                    "$bare_repo_path" "$type" "$ref" "$filter_json" || return 1
            fi
            generate_usage_example "$nix_func" "$bare_repo_path" "$ref" "$filter_json" "$file_tree_hash"
            return 0
        fi
    fi

    local expr
    expr=$(generate_fetch_expr "$nix_func" "$bare_repo_path" "$ref" "$filter_json" "$file_tree_hash")

    local build_output build_failed=false tmp_cache=""
    if [[ -n "$out_dir" ]]; then
        tmp_cache=$(mktemp -d "${TMPDIR:-/tmp}/nix-hug-cache.XXXXXX")
    fi

    if [[ -n "$tmp_cache" ]]; then
        build_output=$(XDG_CACHE_HOME="$tmp_cache" build_with_expr "$expr" "Build") || build_failed=true
    else
        build_output=$(build_with_expr "$expr" "Build") || build_failed=true
    fi

    [[ -n "$tmp_cache" ]] && rm -rf "$tmp_cache"

    if [[ "$build_failed" == "false" ]]; then
        local store_path
        if ! store_path=$(extract_store_path "$build_output"); then
            error "Could not find store path in build output"
            debug "Build output was: $build_output"
            return 1
        fi
        ok "$label downloaded to: $store_path"

        if [[ -n "$out_dir" ]]; then
            copy_to_out_dir "$store_path" "$out_dir" "$override" \
                "$bare_repo_path" "$type" "$ref" "$filter_json" || return 1
        fi

        if [[ "$AUTO_PERSIST" == "true" && -n "$PERSIST_DIR" ]]; then
            persist_export "$store_path" "$bare_repo_path" "$type" "$ref" "$filter_json" || true
        fi

        generate_usage_example "$nix_func" "$bare_repo_path" "$ref" "$filter_json" "$file_tree_hash"
        return 0
    else
        error "Failed to build ${type}: $build_output"
        return 1
    fi
}

cmd_export() {
    local url=""
    local ref="main"
    local filters=()

    while [[ $# -gt 0 ]]; do
        case $1 in
            --ref)
                [[ -z "${2:-}" || "$2" == -* ]] && { error "--ref requires an argument"; return 1; }
                ref="$2"
                shift 2
                ;;
            --include|--exclude|--file)
                [[ -z "${2:-}" || "$2" == -* ]] && { error "$1 requires an argument"; return 1; }
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

    local filter_json
    filter_json=$(create_filter_json_fast "${filters[@]}") || return 1

    local resolved_rev
    resolved_rev=$(resolve_ref "$ref" "$repo_id") || return 1

    local file_tree_url="https://huggingface.co/api/$repo_id/tree/$resolved_rev"
    local file_tree_hash
    file_tree_hash=$(discover_hash_fast "$file_tree_url") || {
        error "Failed to discover hash for file tree"
        return 1
    }

    local bare_repo_path
    bare_repo_path=$(get_bare_repo_path "$repo_id")

    local type_label="model"
    [[ "$repo_type" == "datasets" ]] && type_label="dataset"

    local nix_func="fetchModel"
    [[ "$repo_type" == "datasets" ]] && nix_func="fetchDataset"

    local expr
    expr=$(generate_fetch_expr "$nix_func" "$bare_repo_path" "$resolved_rev" "$filter_json" "$file_tree_hash")

    local build_output
    build_output=$(build_with_expr "$expr" "Build") || {
        error "Failed to build $type_label"
        return 1
    }

    local store_path
    if ! store_path=$(extract_store_path "$build_output"); then
        error "Could not find store path in build output"
        return 1
    fi

    persist_export "$store_path" "$bare_repo_path" "$type_label" "$resolved_rev" "$filter_json" || return 1

    ok "Store path: $store_path"
}

cmd_import() {
    local url=""
    local ref=""
    local import_all=false
    local auto_confirm=false
    local import_path=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --all)
                import_all=true
                shift
                ;;
            --ref)
                [[ -z "${2:-}" || "$2" == -* ]] && { error "--ref requires an argument"; return 1; }
                ref="$2"
                shift 2
                ;;
            --path)
                [[ -z "${2:-}" || "$2" == -* ]] && { error "--path requires a directory argument"; return 1; }
                import_path="$2"
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

    if [[ -n "$import_path" ]]; then
        if [[ ! -f "$import_path/.nix-hug.json" ]]; then
            error "Not a nix-hug export directory (missing .nix-hug.json): $import_path"
            return 1
        fi
        local meta original_store_path store_name store_path
        meta=$(jq '.' "$import_path/.nix-hug.json")
        original_store_path=$(echo "$meta" | jq -r '.storePath // empty')
        info "Importing $(echo "$meta" | jq -r '.repoId') from $import_path..."

        local tmp_meta
        tmp_meta=$(mktemp "${TMPDIR:-/tmp}/nix-hug-meta.XXXXXX")
        cp "$import_path/.nix-hug.json" "$tmp_meta"

        # shellcheck disable=SC2064
        trap "cp '${tmp_meta}' '${import_path}/.nix-hug.json' 2>/dev/null; rm -f '${tmp_meta}'" INT TERM
        rm -f "$import_path/.nix-hug.json"

        local add_err
        add_err=$(mktemp "${TMPDIR:-/tmp}/nix-hug-add-err.XXXXXX")
        if [[ -n "$original_store_path" ]]; then
            store_name="${original_store_path##*/}"
            store_name="${store_name#*-}"
            store_path=$(nix --extra-experimental-features 'nix-command' store add --name "$store_name" "$import_path" 2>"$add_err") || true
        else
            store_path=$(nix --extra-experimental-features 'nix-command' store add "$import_path" 2>"$add_err") || true
        fi

        cp "$tmp_meta" "$import_path/.nix-hug.json"
        rm -f "$tmp_meta"
        trap - INT TERM

        if [[ -z "$store_path" ]]; then
            error "Failed to add directory to Nix store"
            [[ -s "$add_err" ]] && error "$(cat "$add_err")"
            rm -f "$add_err"
            return 1
        fi
        rm -f "$add_err"

        ok "Added to Nix store: $store_path"
        return 0
    fi

    require_persist_dir || return 1

    if [[ "$import_all" != "true" && -z "$url" ]]; then
        error "No repository URL specified (use --all to import everything)"
        show_import_help
        return 1
    fi

    if [[ "$auto_confirm" == "true" ]]; then
        PERSIST_IMPORT_TRUSTED=true
    else
        confirm_import_trust || return 1
    fi

    if [[ "$import_all" == "true" ]]; then
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

    local sanitized_url
    sanitized_url=$(sanitize_hf_url "$url") || return 1

    local parsed
    parsed=$(parse_url "$sanitized_url") || return 1

    local repo_id bare_repo_path
    repo_id=$(echo "$parsed" | jq -r '.repoId')
    bare_repo_path=$(get_bare_repo_path "$repo_id")

    local entry=""
    if [[ -n "$ref" ]]; then
        entry=$(manifest_lookup "$bare_repo_path" "$ref" 2>/dev/null) || true
    fi

    if [[ -z "$entry" && -n "$ref" && ! "$ref" =~ ^[0-9a-f]{40}$ ]]; then
        local resolved_rev
        if resolved_rev=$(resolve_ref "$ref" "$repo_id" 2>/dev/null); then
            entry=$(manifest_lookup "$bare_repo_path" "$resolved_rev" 2>/dev/null) || true
        fi
    fi

    if [[ -z "$entry" && -z "$ref" ]]; then
        entry=$(manifest_lookup "$bare_repo_path" 2>/dev/null) || true
    fi

    if [[ -z "$entry" ]]; then
        error "No entry found for $repo_id in persistent storage"
        return 1
    fi

    local store_path
    store_path=$(echo "$entry" | jq -r '.storePath')

    if nix-store --check-validity "$store_path" 2>/dev/null; then
        ok "Already in store: $store_path"
        return 0
    fi

    persist_import "$store_path" || return 1
    ok "Restored: $store_path"
}

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
