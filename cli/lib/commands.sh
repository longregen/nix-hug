# shellcheck source=/dev/null
source "${NIX_HUG_LIB_DIR}/hash.sh"
# shellcheck source=/dev/null
source "${NIX_HUG_LIB_DIR}/nix-expr.sh"

# Pre-populate fetchurl store paths for LFS files so `nix build` skips downloads.
# Uses nix-store --add-fixed sha256, which produces the same store path as fetchurl.
# Args: store_path [file_tree_json]
#   If file_tree_json is empty, reads from $store_path/.nix-hug-filetree.json
prepopulate_lfs_store_paths() {
    local store_path="$1"
    local file_tree="${2:-}"

    if [[ -z "$file_tree" && -f "$store_path/.nix-hug-filetree.json" ]]; then
        file_tree=$(< "$store_path/.nix-hug-filetree.json")
    fi
    [[ -z "$file_tree" ]] && return 0

    local lfs_paths
    lfs_paths=$(echo "$file_tree" | jq -r '.[] | select(has("lfs")) | .path') || return 0
    [[ -z "$lfs_paths" ]] && return 0

    info "Registering LFS files for nix build..."
    while IFS= read -r lfs_path; do
        [[ -z "$lfs_path" ]] && continue
        local lfs_file="$store_path/$lfs_path"
        if [[ -f "$lfs_file" ]]; then
            nix-store --add-fixed sha256 "$lfs_file" >/dev/null 2>&1 || true
        fi
    done <<< "$lfs_paths"
}

cmd_fetch() {
    local url=""
    local ref="main"
    local filters=()
    local dry_run=false
    local lfs_url_override=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --ref) require_arg "${2:-}" "--ref" || return 1; ref="$2"; shift 2 ;;
            --lfs-url) require_arg "${2:-}" "--lfs-url" || return 1; lfs_url_override="$2"; shift 2 ;;
            --include|--exclude|--file) require_arg "${2:-}" "$1" || return 1; filters+=("$1" "$2"); shift 2 ;;
            --dry-run) dry_run=true; shift ;;
            --help|-h) show_fetch_help; return 0 ;;
            -*) error "Unknown option: $1"; return 1 ;;
            *) url="$1"; shift ;;
        esac
    done

    [[ -z "$url" ]] && { error "No repository URL specified"; return 1; }

    if is_git_url "$url"; then
        cmd_fetch_git "$url" "$ref" "$dry_run" "$lfs_url_override" "${filters[@]}"
        return $?
    fi

    [[ -n "$lfs_url_override" ]] && { warn "--lfs-url is only used with git+ URLs"; }

    resolve_repo "$url" || return 1
    # shellcheck disable=SC2154  # set by resolve_repo
    local repo_id="$_repo_id" repo_type="$_repo_type"
    # shellcheck disable=SC2154
    local bare_repo_path="$_bare_repo_path"
    # shellcheck disable=SC2154
    info "Retrieving information for $_display_name ($ref)..."

    local filter_json
    filter_json=$(create_filter_json_fast "${filters[@]}") || return 1
    [[ "$filter_json" != "null" ]] && info "Using filters: $filter_json"

    info "Resolving revision..."
    local resolved_rev
    resolved_rev=$(resolve_ref "$ref" "$repo_id") || return 1

    info "Discovering file tree hash..."
    local file_tree_url="https://huggingface.co/api/$repo_id/tree/$resolved_rev?recursive=true"
    local file_tree_hash
    file_tree_hash=$(discover_hash_fast "$file_tree_url") || { error "Failed to discover hash for file tree"; return 1; }
    debug "File tree hash: $file_tree_hash"

    local type="model"
    [[ "$repo_type" == "datasets" ]] && type="dataset"
    local nix_func="fetchModel"
    [[ "$type" == "dataset" ]] && nix_func="fetchDataset"

    if [[ "$dry_run" == "true" ]]; then
        local files
        files=$(get_repo_files_fast "$repo_id" "$resolved_rev") || return 1

        local filtered_files
        if [[ ${#filters[@]} -gt 0 ]]; then
            filtered_files=$(filter_files_json "$files" "${filters[@]}")
        else
            filtered_files=$(echo "$files" | jq '[.[] | select(.type != "directory")]')
        fi

        local nix_expr
        nix_expr=$(format_fetch_call "" "nix-hug-lib" "$nix_func" "$bare_repo_path" "$resolved_rev" "$filter_json" "$file_tree_hash")

        if [[ ${#filters[@]} -gt 0 ]]; then
            display_filtered_files "$files" "${filters[@]}"
        else
            display_files "$filtered_files" "Files that would be fetched:"
        fi
        echo
        printf '%b\n' "${BOLD}Nix expression:${NC}"
        echo
        echo "$nix_expr"
        return 0
    fi

    info "Building ${type}..."
    build_and_report "$repo_id" "$resolved_rev" "$filter_json" "$file_tree_hash" "$type"
}

cmd_fetch_git() {
    local url="$1" ref="$2" dry_run="$3" lfs_url_override="$4"
    shift 4
    local filters=("$@")

    parse_git_url "$url" || return 1
    # shellcheck disable=SC2154
    local git_url="$_git_url"
    local lfs_url="${lfs_url_override:-$_git_lfs_url}"
    local git_ref="${_git_ref:-$ref}"
    # shellcheck disable=SC2154
    local org="$_git_org" repo="$_git_repo"

    if [[ -z "$lfs_url" ]]; then
        error "Could not derive LFS URL. Use --lfs-url to specify it."
        return 1
    fi

    info "Fetching git repo: $org/$repo ($git_ref)..."

    local filter_json
    filter_json=$(create_filter_json_fast "${filters[@]}") || return 1
    [[ "$filter_json" != "null" ]] && info "Using filters: $filter_json"

    info "Resolving revision..."
    local resolved_rev
    resolved_rev=$(resolve_git_ref "$git_ref" "$git_url") || return 1

    if [[ "$dry_run" == "true" ]]; then
        local nix_expr
        nix_expr=$(format_git_fetch_call "" "nix-hug-lib" "$git_url" "$resolved_rev" "$lfs_url" "$filter_json")
        printf '%b\n' "${BOLD}Nix expression:${NC}"
        echo
        echo "$nix_expr"
        return 0
    fi

    local store_name="git-${org}-${repo}-${resolved_rev}"
    local store_path
    if store_path=$(find_valid_store_path "$store_name"); then
        ok "Already in Nix store: $store_path"
        generate_git_usage_example "$git_url" "$resolved_rev" "$lfs_url" "$filter_json"
        return 0
    fi

    info "Building..."
    local expr
    expr=$(generate_git_fetch_expr "$git_url" "$resolved_rev" "$lfs_url" "$filter_json")

    local build_output
    build_output=$(build_with_expr "$expr" "Build") || {
        error "Failed to build git repo"
        return 1
    }

    store_path=$(extract_store_path "$build_output") || {
        error "Could not find store path in build output"
        debug "Build output was: $build_output"
        return 1
    }

    ok "Downloaded to: $store_path"
    generate_git_usage_example "$git_url" "$resolved_rev" "$lfs_url" "$filter_json"
}

cmd_ls() {
    local url=""
    local ref="main"
    local filters=()

    while [[ $# -gt 0 ]]; do
        case $1 in
            --ref) require_arg "${2:-}" "--ref" || return 1; ref="$2"; shift 2 ;;
            --include|--exclude|--file) require_arg "${2:-}" "$1" || return 1; filters+=("$1" "$2"); shift 2 ;;
            --help|-h) show_ls_help; return 0 ;;
            -*) error "Unknown option: $1"; return 1 ;;
            *) url="$1"; shift ;;
        esac
    done

    [[ -z "$url" ]] && { error "No repository URL specified"; return 1; }

    resolve_repo "$url" || return 1
    local files
    files=$(get_repo_files_fast "$_repo_id" "$ref") || return 1

    if [[ ${#filters[@]} -gt 0 ]]; then
        display_filtered_files "$files" "${filters[@]}"
    else
        display_files "$files" "Files in $_display_name:"
    fi
}

build_and_report() {
    local repo_id="$1" ref="$2" filter_json="$3" file_tree_hash="$4"
    local type="${5:-model}"

    local nix_func="fetchModel"
    [[ "$type" == "dataset" ]] && nix_func="fetchDataset"
    local label="${type^}"

    local bare_repo_path
    bare_repo_path=$(get_bare_repo_path "$repo_id")

    parse_bare_repo "$bare_repo_path" || return 1
    # shellcheck disable=SC2154  # set by parse_bare_repo
    local _check_store_name="hf-${type}-${_org}-${_repo}-${ref}"
    local store_path
    if store_path=$(find_valid_store_path "$_check_store_name"); then
        ok "Already in Nix store: $store_path"
        generate_usage_example "$nix_func" "$bare_repo_path" "$ref" "$filter_json" "$file_tree_hash"
        return 0
    fi

    local expr
    expr=$(generate_fetch_expr "$nix_func" "$bare_repo_path" "$ref" "$filter_json" "$file_tree_hash")

    local build_output
    build_output=$(build_with_expr "$expr" "Build") || {
        error "Failed to build ${type}"
        return 1
    }

    store_path=$(extract_store_path "$build_output") || {
        error "Could not find store path in build output"
        debug "Build output was: $build_output"
        return 1
    }

    ok "$label downloaded to: $store_path"
    generate_usage_example "$nix_func" "$bare_repo_path" "$ref" "$filter_json" "$file_tree_hash"
}

cmd_export() {
    local url=""
    local ref="main"
    local filters=()

    while [[ $# -gt 0 ]]; do
        case $1 in
            --ref) require_arg "${2:-}" "--ref" || return 1; ref="$2"; shift 2 ;;
            --include|--exclude|--file) require_arg "${2:-}" "$1" || return 1; filters+=("$1" "$2"); shift 2 ;;
            --help|-h) show_export_help; return 0 ;;
            -*) error "Unknown option: $1"; return 1 ;;
            *) url="$1"; shift ;;
        esac
    done

    [[ -z "$url" ]] && { error "No repository URL specified"; show_export_help; return 1; }

    # Try offline path: parse locally and check nix store
    if parse_bare_repo "$url" 2>/dev/null; then
        local store_path=""
        if store_path=$(find_store_path_by_repo "$_org" "$_repo"); then
            local basename="${store_path##*/}"
            local name="${basename#*-}"
            local rev="${name: -40}"
            local type_label="model"
            [[ "$name" == hf-dataset-* ]] && type_label="dataset"

            info "Found in Nix store: $store_path"
            export_to_hf_cache "$store_path" "$_org/$_repo" "$type_label" "$rev" || return 1
            ok "Store path: $store_path"
            return 0
        fi
    fi

    # Online path: resolve repo via API
    resolve_repo "$url" || return 1
    local repo_id="$_repo_id" bare_repo_path="$_bare_repo_path"
    info "Exporting $_display_name ($ref)..."

    local filter_json
    filter_json=$(create_filter_json_fast "${filters[@]}") || return 1

    local resolved_rev
    resolved_rev=$(resolve_ref "$ref" "$repo_id") || return 1

    local file_tree_url="https://huggingface.co/api/$repo_id/tree/$resolved_rev?recursive=true"
    local file_tree_hash
    file_tree_hash=$(discover_hash_fast "$file_tree_url") || { error "Failed to discover hash for file tree"; return 1; }

    local type_label="model"
    [[ "$_repo_type" == "datasets" ]] && type_label="dataset"

    local store_path=""
    parse_bare_repo "$bare_repo_path" || return 1
    local _check_store_name="hf-${type_label}-${_org}-${_repo}-${resolved_rev}"
    if store_path=$(find_valid_store_path "$_check_store_name"); then
        debug "Found existing store path: $store_path"
    fi

    if [[ -z "$store_path" ]]; then
        local nix_func="fetchModel"
        [[ "$_repo_type" == "datasets" ]] && nix_func="fetchDataset"

        local expr
        expr=$(generate_fetch_expr "$nix_func" "$bare_repo_path" "$resolved_rev" "$filter_json" "$file_tree_hash")

        local build_output
        build_output=$(build_with_expr "$expr" "Build") || {
            error "Failed to build $type_label"
            return 1
        }

        if ! store_path=$(extract_store_path "$build_output"); then
            error "Could not find store path in build output"
            return 1
        fi
    fi

    export_to_hf_cache "$store_path" "$bare_repo_path" "$type_label" "$resolved_rev" || return 1
    ok "Store path: $store_path"
}

export_to_hf_cache() {
    local store_path="$1"
    local bare_repo_path="$2"
    local type_label="$3"
    local resolved_rev="$4"

    local hf_cache
    hf_cache=$(resolve_hf_cache_dir)

    parse_bare_repo "$bare_repo_path" || return 1
    local org="$_org" repo="$_repo"

    local filetree="$store_path/.nix-hug-filetree.json"
    if [[ ! -f "$filetree" ]]; then
        error "Store path missing .nix-hug-filetree.json: $store_path"
        return 1
    fi

    local snapshot_dir repo_dir
    snapshot_dir=$(init_hf_cache_snapshot "$hf_cache" "$type_label" "$org" "$repo" "$resolved_rev")
    repo_dir="$(dirname "$(dirname "$snapshot_dir")")"
    mkdir -p "$repo_dir/blobs"

    # Pre-extract path and blob hash in a single jq call (LFS→lfs.oid, else→oid)
    local entries
    entries=$(jq -r '.[] | select(.type != "directory") | select(.path | startswith(".nix-hug-") | not)
        | [.path, (if .lfs then .lfs.oid else .oid end)] | @tsv' "$filetree")

    while IFS=$'\t' read -r fpath blob_hash; do
        [[ -z "$fpath" ]] && continue

        # Copy file to blobs/ if not already there
        if [[ ! -f "$repo_dir/blobs/$blob_hash" ]]; then
            cp -L "$store_path/$fpath" "$repo_dir/blobs/$blob_hash"
        fi

        # Create symlink in snapshot dir
        local snap_file="$snapshot_dir/$fpath"
        mkdir -p "$(dirname "$snap_file")"

        # Relative path from snapshots/$rev/$path to blobs/$hash
        # Base depth is 2 (../../blobs/$hash), +1 per directory level in path
        local depth rel_prefix="../.."
        depth=$(echo "$fpath" | tr -cd '/' | wc -c)
        local i
        for ((i = 0; i < depth; i++)); do
            rel_prefix="../$rel_prefix"
        done

        ln -sf "$rel_prefix/blobs/$blob_hash" "$snap_file"
    done <<< "$entries"

    ok "Exported to HF cache: $repo_dir"
    info "Snapshot: $snapshot_dir"
}

cmd_import() {
    local url=""
    local ref=""
    local filters=()

    while [[ $# -gt 0 ]]; do
        case $1 in
            --ref) require_arg "${2:-}" "--ref" || return 1; ref="$2"; shift 2 ;;
            --include|--exclude|--file) require_arg "${2:-}" "$1" || return 1; filters+=("$1" "$2"); shift 2 ;;
            --help|-h) show_import_help; return 0 ;;
            -*) error "Unknown option: $1"; return 1 ;;
            *) url="$1"; shift ;;
        esac
    done

    import_from_hf_cache "$url" "$ref" "${filters[@]}"
}

import_from_hf_cache() {
    local repo_id="${1:-}"
    local ref="${2:-}"
    shift 2 || true
    local filters=()
    [[ $# -gt 0 ]] && filters=("$@")

    if [[ -z "$repo_id" ]]; then
        error "No repository URL specified"
        show_import_help
        return 1
    fi

    parse_bare_repo "$repo_id" || return 1
    # shellcheck disable=SC2154  # set by parse_bare_repo
    local org="$_org" repo="$_repo" type_hint="$_type_hint"

    local hf_cache
    hf_cache=$(resolve_hf_cache_dir)

    local cache_repo_dir="" detected_type=""

    if [[ "$type_hint" == "models" && -d "$hf_cache/models--${org}--${repo}" ]]; then
        cache_repo_dir="$hf_cache/models--${org}--${repo}"
        detected_type="model"
    elif [[ "$type_hint" == "datasets" && -d "$hf_cache/datasets--${org}--${repo}" ]]; then
        cache_repo_dir="$hf_cache/datasets--${org}--${repo}"
        detected_type="dataset"
    elif [[ -d "$hf_cache/models--${org}--${repo}" ]]; then
        cache_repo_dir="$hf_cache/models--${org}--${repo}"
        detected_type="model"
    elif [[ -d "$hf_cache/datasets--${org}--${repo}" ]]; then
        cache_repo_dir="$hf_cache/datasets--${org}--${repo}"
        detected_type="dataset"
    else
        error "Repository $org/$repo not found in HF cache at $hf_cache"
        error "Expected: $hf_cache/models--${org}--${repo} or $hf_cache/datasets--${org}--${repo}"
        return 1
    fi

    debug "Found $detected_type in cache: $cache_repo_dir"

    local resolved_rev=""
    if [[ -n "$ref" ]]; then
        if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
            resolved_rev="$ref"
        elif [[ -f "$cache_repo_dir/refs/$ref" ]]; then
            resolved_rev=$(cat "$cache_repo_dir/refs/$ref")
        else
            error "Ref '$ref' not found in $cache_repo_dir/refs/"
            local available
            available=$(for f in "$cache_repo_dir/refs/"*; do [[ -f "$f" ]] && printf '%s, ' "${f##*/}"; done)
            [[ -n "$available" ]] && error "Available refs: ${available%, }"
            return 1
        fi
    else
        if [[ -f "$cache_repo_dir/refs/main" ]]; then
            resolved_rev=$(cat "$cache_repo_dir/refs/main")
        else
            local snapshots=()
            for s in "$cache_repo_dir/snapshots/"*/; do
                local _s="${s%/}"; [[ -d "$s" ]] && snapshots+=("${_s##*/}")
            done
            if [[ ${#snapshots[@]} -eq 1 ]]; then
                resolved_rev="${snapshots[0]}"
            elif [[ ${#snapshots[@]} -eq 0 ]]; then
                error "No snapshots found in $cache_repo_dir/snapshots/"
                return 1
            else
                error "No 'main' ref found and multiple snapshots exist. Use --ref to specify."
                error "Available revisions: ${snapshots[*]}"
                return 1
            fi
        fi
    fi

    local snapshot_dir="$cache_repo_dir/snapshots/$resolved_rev"
    if [[ ! -d "$snapshot_dir" ]]; then
        error "Snapshot directory not found: $snapshot_dir"
        return 1
    fi

    local store_name="hf-${detected_type}-${org}-${repo}-${resolved_rev}"

    local nix_func="fetchModel"
    [[ "$detected_type" == "dataset" ]] && nix_func="fetchDataset"

    local filter_json="null"
    if [[ ${#filters[@]} -gt 0 ]]; then
        filter_json=$(create_filter_json_fast "${filters[@]}") || filter_json="null"
    fi

    # Single network call: fetch file tree JSON (used for metadata, hash, and LFS pre-population)
    local api_file_tree="" file_tree_hash=""
    info "Fetching file tree..."
    api_file_tree=$(get_repo_files_fast "${detected_type}s/${org}/${repo}" "$resolved_rev" 2>/dev/null) || true
    if [[ -n "$api_file_tree" ]]; then
        file_tree_hash=$(printf '%s' "$api_file_tree" \
            | nix --extra-experimental-features 'nix-command' hash file \
                --type sha256 --sri --mode flat /dev/stdin 2>/dev/null) || file_tree_hash=""
    fi

    local store_path
    if store_path=$(find_valid_store_path "$store_name"); then

        ok "Already in Nix store: $store_path"
        generate_cache_usage_example "$store_path" "$nix_func" "$org/$repo" "$resolved_rev" "$filter_json" "$file_tree_hash"
        return 0
    fi

    info "Importing $org/$repo ($detected_type) rev ${resolved_rev:0:12}..."

    # Build flat layout matching fetchModel/fetchDataset output
    local tmp_dir
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/nix-hug-from-cache.XXXXXX")

    if [[ ${#filters[@]} -gt 0 ]]; then
        local filter_type="" patterns=()
        for ((i=0; i<${#filters[@]}; i+=2)); do
            local flag="${filters[i]}" pattern="${filters[i+1]}"
            case "$flag" in
                --include)
                    [[ -n "$filter_type" && "$filter_type" != "include" ]] && { error "Cannot mix --include, --exclude, and --file filters"; rm -rf "$tmp_dir"; return 1; }
                    filter_type="include"; patterns+=("$pattern") ;;
                --exclude)
                    [[ -n "$filter_type" && "$filter_type" != "exclude" ]] && { error "Cannot mix --include, --exclude, and --file filters"; rm -rf "$tmp_dir"; return 1; }
                    filter_type="exclude"; patterns+=("$pattern") ;;
                --file)
                    [[ -n "$filter_type" && "$filter_type" != "file" ]] && { error "Cannot mix --include, --exclude, and --file filters"; rm -rf "$tmp_dir"; return 1; }
                    filter_type="file"; patterns+=("$pattern") ;;
            esac
        done

        local copy_failures=0 copied=0
        while IFS= read -r -d '' file; do
            local relpath="${file#"$snapshot_dir"/}"
            local matched=false
            case "$filter_type" in
                include)
                    for pat in "${patterns[@]}"; do
                        # shellcheck disable=SC2254,SC2053  # intentional glob matching
                        [[ "$relpath" == $pat || "${relpath##*/}" == $pat ]] && { matched=true; break; }
                    done
                    ;;
                exclude)
                    matched=true
                    for pat in "${patterns[@]}"; do
                        # shellcheck disable=SC2254,SC2053  # intentional glob matching
                        [[ "$relpath" == $pat || "${relpath##*/}" == $pat ]] && { matched=false; break; }
                    done
                    ;;
                file)
                    for pat in "${patterns[@]}"; do
                        [[ "$relpath" == "$pat" ]] && { matched=true; break; }
                    done
                    ;;
            esac
            if [[ "$matched" == "true" ]]; then
                local dst="$tmp_dir/$relpath"
                mkdir -p "$(dirname "$dst")"
                if cp -L "$file" "$dst" 2>/dev/null; then
                    copied=$((copied + 1))
                else
                    warn "Could not copy $relpath (broken symlink or missing blob)"
                    copy_failures=$((copy_failures + 1))
                fi
            fi
        done < <(find -L "$snapshot_dir" -type f -print0 2>/dev/null)

        if [[ $copied -eq 0 ]]; then
            error "No files to import (filters may have excluded everything, or all symlinks broken)"
            rm -rf "$tmp_dir"
            return 1
        fi
        [[ $copy_failures -gt 0 ]] && warn "$copy_failures file(s) could not be copied"
        info "Prepared $copied files..."
    else
        info "Copying files..."
        cp -rL "$snapshot_dir/." "$tmp_dir/"
    fi

    # Create metadata files matching fetch layout
    printf '{"id":"%s","sha":"%s"}' "$org/$repo" "$resolved_rev" > "$tmp_dir/.nix-hug-repoinfo.json"

    if [[ -n "$api_file_tree" ]]; then
        printf '%s' "$api_file_tree" > "$tmp_dir/.nix-hug-filetree.json"
    fi

    info "Adding to Nix store..."

    local store_path
    store_path=$(nix --extra-experimental-features 'nix-command' store add \
        --name "$store_name" "$tmp_dir") || true

    rm -rf "$tmp_dir"

    if [[ -z "$store_path" ]]; then
        error "Failed to add to Nix store"
        return 1
    fi

    prepopulate_lfs_store_paths "$store_path" "$api_file_tree"

    ok "Added to Nix store: $store_path"
    generate_cache_usage_example "$store_path" "$nix_func" "$org/$repo" "$resolved_rev" "$filter_json" "$file_tree_hash"
}

cmd_scan() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h) show_scan_help; return 0 ;;
            -*) error "Unknown option: $1"; return 1 ;;
            *) error "Unexpected argument: $1"; return 1 ;;
        esac
    done

    local hf_cache
    hf_cache=$(resolve_hf_cache_dir)

    if [[ ! -d "$hf_cache" ]]; then
        info "HuggingFace cache not found at: $hf_cache"
        info "Models are typically cached in \$HF_HUB_CACHE or \$XDG_CACHE_HOME/huggingface/hub/"
        return 0
    fi

    local found=false

    info "Scanning $hf_cache"
    echo
    printf '  %s%-42s %-9s %-14s %9s %6s %-6s %s%s\n' \
        "$BOLD" "REPOSITORY" "TYPE" "REV" "SIZE" "FILES" "STORE" "REFS" "$NC"

    local dir
    for dir in "$hf_cache"/{models,datasets}--*--*/; do
        [[ -d "$dir" ]] || continue

        local dirname="${dir%/}"
        dirname="${dirname##*/}"

        # Parse type, org, repo from dirname: {models|datasets}--{org}--{repo}
        local type_prefix remainder org repo
        if [[ "$dirname" =~ ^(models|datasets)--(.+) ]]; then
            type_prefix="${BASH_REMATCH[1]}"
            remainder="${BASH_REMATCH[2]}"
        else
            debug "Skipping unrecognized directory: $dirname"
            continue
        fi

        if [[ "$remainder" =~ ^([^-]+(-[^-]+)*)--(.+)$ ]]; then
            org="${BASH_REMATCH[1]}"
            repo="${BASH_REMATCH[3]}"
        else
            debug "Could not parse org/repo from: $remainder"
            continue
        fi

        local type="model"
        [[ "$type_prefix" == "datasets" ]] && type="dataset"
        local repo_id="$org/$repo"

        unset ref_map 2>/dev/null
        declare -A ref_map=()
        if [[ -d "$dir/refs" ]]; then
            local ref_file
            for ref_file in "$dir/refs/"*; do
                [[ -f "$ref_file" ]] || continue
                local ref_name ref_hash
                ref_name="${ref_file##*/}"
                ref_hash=$(< "$ref_file") || continue
                ref_map["$ref_hash"]+="${ref_name} "
            done
        fi

        if [[ ! -d "$dir/snapshots" ]]; then
            debug "No snapshots directory in: $dirname"
            continue
        fi

        local snap_dir
        for snap_dir in "$dir/snapshots/"*/; do
            [[ -d "$snap_dir" ]] || continue

            local rev="${snap_dir%/}"
            rev="${rev##*/}"

            if [[ ! "$rev" =~ ^[0-9a-f]{7,}$ ]]; then
                debug "Skipping non-hash snapshot: $rev"
                continue
            fi

            found=true

            local file_count total_bytes
            read -r file_count total_bytes < <(
                find -L "$snap_dir" -type f -printf '%s\n' 2>/dev/null \
                | awk '{s+=$1; c++} END {print c+0, s+0}'
            )

            local ref_labels=""
            if [[ -n "${ref_map[$rev]:-}" ]]; then
                ref_labels="${ref_map[$rev]% }"  # trim trailing space
            fi

            local in_store=false
            find_valid_store_path "hf-${type}-${org}-${repo}-${rev}" >/dev/null && in_store=true

            local short_rev="${rev:0:12}"
            [[ ${#rev} -gt 12 ]] && short_rev="${short_rev}..."
            local formatted_size
            formatted_size=$(format_size "$total_bytes")
            local store_marker=""
            [[ "$in_store" == "true" ]] && store_marker="${GREEN}yes${NC}"
            printf "  %-42s %-9s %-14s %9s %6d %-6b ${DIM}%s${NC}\n" \
                "$repo_id" "$type" "$short_rev" "$formatted_size" "$file_count" "$store_marker" "$ref_labels"
        done

        unset ref_map 2>/dev/null
    done

    if [[ "$found" != "true" ]]; then
        info "No models or datasets found in $hf_cache"
    fi
}
