require_persist_dir() {
    if [[ -z "$PERSIST_DIR" ]]; then
        error "No persist directory configured."
        error "Set persist_dir in ${NIX_HUG_CONFIG_FILE}"
        error "  or export NIX_HUG_PERSIST_DIR=/path/to/storage"
        return 1
    fi
}

init_persist_dir() {
    require_persist_dir || return 1
    mkdir -p "$PERSIST_DIR"
}

manifest_path() {
    echo "$PERSIST_DIR/nix-hug-manifest.json"
}

manifest_read() {
    local mpath
    mpath=$(manifest_path)
    if [[ -f "$mpath" && -s "$mpath" ]]; then
        jq '.' "$mpath"
    else
        echo '[]'
    fi
}

manifest_write() {
    local mpath
    mpath=$(manifest_path)
    local data="${1:-$(cat)}"
    local tmp
    tmp=$(mktemp "$mpath.XXXXXX")
    if echo "$data" | jq '.' > "$tmp"; then
        mv "$tmp" "$mpath"
    else
        rm -f "$tmp"
        error "Failed to write manifest"
        return 1
    fi
}

manifest_lookup() {
    local repo_id="$1"
    local rev="${2:-}"
    local manifest
    manifest=$(manifest_read)

    if [[ -n "$rev" ]]; then
        echo "$manifest" | jq -e --arg id "$repo_id" --arg rev "$rev" \
            '[.[] | select(.repoId == $id and .rev == $rev)] | sort_by(.exportedAt) | last // empty' 2>/dev/null
    else
        echo "$manifest" | jq -e --arg id "$repo_id" \
            '[.[] | select(.repoId == $id)] | sort_by(.exportedAt) | last // empty' 2>/dev/null
    fi
}

manifest_add() {
    local repo_id="$1"
    local type="$2"
    local rev="$3"
    local filters="$4"
    local store_path="$5"

    local manifest
    manifest=$(manifest_read)

    local exported_at
    exported_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    manifest=$(echo "$manifest" | jq --arg id "$repo_id" --arg rev "$rev" \
        '[.[] | select(.repoId != $id or .rev != $rev)]')

    local entry
    entry=$(jq -n \
        --arg repoId "$repo_id" \
        --arg type "$type" \
        --arg rev "$rev" \
        --arg filters "$filters" \
        --arg storePath "$store_path" \
        --arg exportedAt "$exported_at" \
        '{
            repoId: $repoId,
            type: $type,
            rev: $rev,
            filters: (if $filters == "null" then null else $filters end),
            storePath: $storePath,
            exportedAt: $exportedAt
        }')

    manifest=$(echo "$manifest" | jq --argjson entry "$entry" '. + [$entry]')
    manifest_write "$manifest"
}

persist_export() {
    local store_path="$1"
    local repo_id="$2"
    local type="$3"
    local rev="$4"
    local filters="${5:-null}"

    init_persist_dir || return 1

    info "Exporting $store_path to persistent storage..."
    if nix --extra-experimental-features 'nix-command' copy --to "file://$PERSIST_DIR" "$store_path"; then
        manifest_add "$repo_id" "$type" "$rev" "$filters" "$store_path"
        ok "Exported to $PERSIST_DIR"
        return 0
    else
        error "Failed to export $store_path"
        return 1
    fi
}

confirm_import_trust() {
    [[ "${PERSIST_IMPORT_TRUSTED:-}" == "true" ]] && return 0

    warn "Importing uses --no-check-sigs (signatures are not verified)."
    warn "This trusts that the binary cache at $PERSIST_DIR has not been tampered with."

    if [[ -t 0 ]]; then
        printf '%s' "${YELLOW}Continue? [y/N] ${NC}" >&2
        local reply
        read -r reply
        case "$reply" in
            [yY]|[yY][eE][sS])
                PERSIST_IMPORT_TRUSTED=true
                return 0
                ;;
            *)
                info "Import cancelled."
                return 1
                ;;
        esac
    else
        error "Non-interactive session: pass --yes or --no-check-sigs to acknowledge unsigned import"
        return 1
    fi
}

persist_import() {
    local store_path="$1"

    require_persist_dir || return 1

    info "Importing $store_path from persistent storage..."
    if nix --extra-experimental-features 'nix-command' copy --no-check-sigs --from "file://$PERSIST_DIR" "$store_path"; then
        ok "Imported $store_path"
        return 0
    else
        error "Failed to import $store_path"
        return 1
    fi
}

persist_try_import() {
    local repo_id="$1"
    local rev="$2"

    [[ -z "$PERSIST_DIR" ]] && return 1

    PERSIST_IMPORT_TRUSTED=true

    local entry
    entry=$(manifest_lookup "$repo_id" "$rev") || return 1
    [[ -z "$entry" ]] && return 1

    local store_path
    store_path=$(echo "$entry" | jq -r '.storePath')

    if nix-store --check-validity "$store_path" 2>/dev/null; then
        debug "Store path already valid: $store_path"
        echo "$store_path"
        return 0
    fi

    if persist_import "$store_path"; then
        echo "$store_path"
        return 0
    fi

    return 1
}

persist_list() {
    require_persist_dir || return 1

    local manifest
    manifest=$(manifest_read)

    local count
    count=$(echo "$manifest" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        echo "No models in persistent storage."
        return 0
    fi

    printf '%s%-40s %-10s %-12s %-20s %s%s\n' "$BOLD" "REPOSITORY" "TYPE" "REV" "EXPORTED" "STATUS" "$NC"

    echo "$manifest" | jq -c '.[]' | while IFS= read -r entry; do
        local repo_id type rev exported store_path
        repo_id=$(echo "$entry" | jq -r '.repoId')
        type=$(echo "$entry" | jq -r '.type')
        rev=$(echo "$entry" | jq -r '.rev')
        exported=$(echo "$entry" | jq -r '.exportedAt')
        store_path=$(echo "$entry" | jq -r '.storePath')

        local short_rev="${rev:0:12}"
        local short_date="${exported%T*}"

        local status=""
        if nix-store --check-validity "$store_path" 2>/dev/null; then
            status="${GREEN}valid${NC}"
        else
            status="${DIM}gc'd${NC}"
        fi

        printf "  %-40s %-10s %-12s %-20s %b\n" "$repo_id" "$type" "$short_rev" "$short_date" "$status"
    done
}
