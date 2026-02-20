source "${NIX_HUG_LIB_DIR}/nix-expr.sh"

show_help() {
    cat << EOF
${BOLD}nix-hug${NC} - Declarative Hugging Face model management for Nix

${BOLD}USAGE:${NC}
    nix-hug [OPTIONS] <COMMAND> [ARGS]

${BOLD}COMMANDS:${NC}
    fetch           Download model or dataset and generate Nix expression
    ls              List repository contents without downloading
    export          Fetch and persist model/dataset to local binary cache
    import          Restore model/dataset from persistent storage
    store           Manage persistent storage (ls, path)

${BOLD}OPTIONS:${NC}
    --debug     Show detailed execution steps
    --version   Show version information
    --help      Show this help message

${BOLD}FETCH OPTIONS:${NC}
    --ref REF           Use specific git reference (default: main)
    --include PATTERN   Include files matching glob pattern
    --exclude PATTERN   Exclude files matching glob pattern
    --file FILENAME     Include specific file by name
    --out DIR, -o DIR   Copy result to a regular folder (avoids ~/.cache/nix bloat)
    --override          Allow overwriting a non-empty --out directory

${BOLD}LS OPTIONS:${NC}
    --ref REF           Use specific git reference (default: main)
    --include PATTERN   Include files matching glob pattern
    --exclude PATTERN   Exclude files matching glob pattern
    --file FILENAME     Show specific file by name

${BOLD}EXAMPLES:${NC}
    nix-hug fetch openai-community/gpt2
    nix-hug fetch openai-community/gpt2 --include '*.safetensors'
    nix-hug ls openai-community/gpt2 --exclude '*.bin'
    nix-hug ls google-bert/bert-base-uncased --file config.json
    nix-hug fetch rajpurkar/squad --include '*.json'
    nix-hug fetch stanfordnlp/imdb --include '*.parquet'

${BOLD}DOWNLOAD TO A FOLDER:${NC}
    # Fetch directly into a regular writable folder:
    nix-hug fetch openai-community/gpt2 --out ~/models/gpt2
    nix-hug fetch mistralai/Mistral-7B-Instruct-v0.3 --include '*.safetensors' --out ~/models/mistral

    # Add back to Nix store later (content-addressed, see 'import --help'):
    nix-hug import --path ~/models/gpt2

    # Or symlink from the store path (no extra disk space):
    nix-hug fetch openai-community/gpt2
    ln -s /nix/store/...-gpt2 ~/models/gpt2

    # Point HuggingFace tools directly at the store path:
    HF_HUB_CACHE=/nix/store/...-gpt2 python my_script.py

${BOLD}PERSIST & OFFLINE BUILDS:${NC}
    # To preserve exact store paths (e.g. for offline nix build), use export/import:
    nix-hug export openai-community/gpt2
    nix-hug import openai-community/gpt2
    nix-hug import --all
    nix-hug store ls
    nix-hug store path

For more information, visit: https://github.com/longregen/nix-hug
EOF
}

show_fetch_help() {
    cat << EOF
${BOLD}Fetch Model or Dataset${NC}

${BOLD}USAGE:${NC}
    nix-hug fetch <URL> [OPTIONS]

${BOLD}DESCRIPTION:${NC}
    Downloads a Hugging Face model or dataset and generates a pinned
    Nix expression for reproducible builds.

    With --out, the result is also copied to a regular writable folder.
    Use 'nix-hug import --path DIR' to add it back to the Nix store.

${BOLD}OPTIONS:${NC}
    --ref REF           Use specific git reference (default: main)
    --include PATTERN   Include LFS files matching glob pattern
    --exclude PATTERN   Exclude LFS files matching glob pattern
    --file FILENAME     Include specific file by name
    --out DIR, -o DIR   Copy result to a regular writable folder
    --override          Allow overwriting a non-empty --out directory
    --help              Show this help

${BOLD}EXAMPLES:${NC}
    nix-hug fetch openai-community/gpt2
    nix-hug fetch openai-community/gpt2 --ref abc123...
    nix-hug fetch openai-community/gpt2 --include '*.safetensors'
    nix-hug fetch openai-community/gpt2 --out ~/models/gpt2
EOF
}

show_ls_help() {
    cat << EOF
${BOLD}List Repository Contents${NC}

${BOLD}USAGE:${NC}
    nix-hug ls <URL> [OPTIONS]

${BOLD}DESCRIPTION:${NC}
    Lists files in a Hugging Face repository without downloading.

${BOLD}OPTIONS:${NC}
    --ref REF           Use specific git reference (default: main)
    --include PATTERN   Include LFS files matching glob pattern
    --exclude PATTERN   Exclude LFS files matching glob pattern
    --file FILENAME     Show specific file by name
    --help              Show this help

${BOLD}EXAMPLES:${NC}
    nix-hug ls openai-community/gpt2
    nix-hug ls openai-community/gpt2 --ref abc123...
    nix-hug ls openai-community/gpt2 --exclude '*.bin'
    nix-hug ls google-bert/bert-base-uncased --file config.json
EOF
}

show_export_help() {
    cat << EOF
${BOLD}Export Model/Dataset to Persistent Storage${NC}

${BOLD}USAGE:${NC}
    nix-hug export <URL> [OPTIONS]

${BOLD}DESCRIPTION:${NC}
    Fetches the model/dataset (like 'fetch') and copies the store path
    to a local Nix binary cache for persistence across garbage collection.

${BOLD}OPTIONS:${NC}
    --ref REF           Use specific git reference (default: main)
    --include PATTERN   Include files matching glob pattern
    --exclude PATTERN   Exclude files matching glob pattern
    --file FILENAME     Include specific file by name
    --help              Show this help

${BOLD}CONFIGURATION:${NC}
    Set persist_dir in ${NIX_HUG_CONFIG_FILE} or NIX_HUG_PERSIST_DIR env var.

${BOLD}EXAMPLES:${NC}
    nix-hug export openai-community/gpt2
    nix-hug export openai-community/gpt2 --include '*.safetensors'
    NIX_HUG_PERSIST_DIR=/persist/models nix-hug export stas/tiny-random-llama-2
EOF
}

show_import_help() {
    cat << EOF
${BOLD}Import Model/Dataset from Persistent Storage${NC}

${BOLD}USAGE:${NC}
    nix-hug import [<URL> [--ref REF]] [--all] [--path DIR]

${BOLD}DESCRIPTION:${NC}
    Restores a previously exported model/dataset back into the Nix store.

    Without --path, restores from the persistent binary cache (exact
    store path preserved — use this for offline nix build / nix develop).

    With --path, imports a directory created by 'fetch --out'. The files
    are added as a content-addressed store path, which will differ from
    the original derivation output path. This is useful for getting the
    files back into /nix/store for direct use, but will not satisfy
    derivation references from flake expressions. For exact store path
    restoration, use 'nix-hug export' / 'nix-hug import' instead.

${BOLD}OPTIONS:${NC}
    --all       Import all entries from the manifest
    --ref REF   Match a specific revision
    --path DIR  Import from a directory created by fetch --out
    --yes, -y, --no-check-sigs
                Skip trust confirmation (acknowledge unsigned import)
    --help      Show this help

${BOLD}EXAMPLES:${NC}
    nix-hug import openai-community/gpt2
    nix-hug import openai-community/gpt2 --ref abc123...
    nix-hug import --all
    nix-hug import --all --yes
    nix-hug import --path ~/models/gpt2
EOF
}

show_store_help() {
    cat << EOF
${BOLD}Persistent Storage Management${NC}

${BOLD}USAGE:${NC}
    nix-hug store <ACTION>

${BOLD}ACTIONS:${NC}
    ls, list    List all models/datasets in persistent storage
    path        Print the configured persist directory

${BOLD}EXAMPLES:${NC}
    nix-hug store ls
    nix-hug store path
EOF
}

display_files() {
    local files="$1"
    local header="$2"
    
    echo "$header"
    echo
    
    local total_size=0
    local lfs_count=0
    local lfs_size=0
    
    while IFS= read -r file; do
        local path size is_lfs
        path=$(echo "$file" | jq -r '.path')
        size=$(echo "$file" | jq -r '.size // 0')
        is_lfs=$(echo "$file" | jq -r 'has("lfs")')
        
        total_size=$((total_size + size))
        
        if [[ "$is_lfs" == "true" ]]; then
            lfs_count=$((lfs_count + 1))
            lfs_size=$((lfs_size + size))
            printf "  %-50s %10s   ${DIM}[LFS]${NC}\n" "$path" "$(format_size "$size")"
        else
            printf "  %-50s %10s\n" "$path" "$(format_size "$size")"
        fi
    done < <(echo "$files" | jq -c '.[]')
    
    echo
    echo -n "Total: $(format_size "$total_size")"
    if [[ $lfs_count -gt 0 ]]; then
        echo " ($lfs_count LFS files: $(format_size "$lfs_size"))"
    else
        echo
    fi
}

generate_usage_example() {
    local nix_func="$1"
    local repo_id="$2"
    local ref="$3"
    local filter_json="$4"
    local file_tree_hash="$5"

    cat << EOF
${BOLD}Usage:${NC}

$(format_fetch_call "" "nix-hug-lib" "$nix_func" "$repo_id" "$ref" "$filter_json" "$file_tree_hash");
EOF
}

display_filtered_files() {
    local files="$1"
    shift
    local filters=("$@")
    
    local filter_type=""
    local patterns=()
    local file_names=()

    for ((i=0; i<${#filters[@]}; i+=2)); do
        local flag="${filters[i]}"
        local pattern="${filters[i+1]}"

        case "$flag" in
            --include) filter_type="include" ;;
            --exclude) filter_type="exclude" ;;
            --file) filter_type="file" ;;
        esac

        if [[ "$flag" == "--file" ]]; then
            file_names+=("$pattern")
        else
            patterns+=("$(glob_to_regex "$pattern")$")
        fi
    done

    local filtered_files
    if [[ "$filter_type" == "include" ]]; then
        local pattern_regex
        pattern_regex=$(IFS='|'; echo "${patterns[*]}")
        filtered_files=$(echo "$files" | jq --arg regex "$pattern_regex" '[.[] | select((.path | test($regex)) or (has("lfs") | not))]')
    elif [[ "$filter_type" == "exclude" ]]; then
        local pattern_regex
        pattern_regex=$(IFS='|'; echo "${patterns[*]}")
        filtered_files=$(echo "$files" | jq --arg regex "$pattern_regex" '[.[] | select((.path | test($regex) | not) or (has("lfs") | not))]')
    elif [[ "$filter_type" == "file" ]]; then
        local names_json
        names_json=$(printf '%s\n' "${file_names[@]}" | jq -R . | jq -s .)
        filtered_files=$(echo "$files" | jq --argjson names "$names_json" '[.[] | select(.path as $p | $names | any(. == $p))]')
    else
        filtered_files="$files"
    fi
    
    echo "Files matching filters: ${filters[@]@Q}"
    display_files "$filtered_files" ""
}
