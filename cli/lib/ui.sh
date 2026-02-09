# UI and formatting functions

source "${NIX_HUG_LIB_DIR}/nix-expr.sh"

show_help() {
    cat << EOF
${BOLD}nix-hug${NC} - Declarative Hugging Face model management for Nix

${BOLD}USAGE:${NC}
    nix-hug [OPTIONS] <COMMAND> [ARGS]

${BOLD}COMMANDS:${NC}
    fetch           Download model or dataset and generate Nix expression
    ls              List repository contents without downloading
    cache           Manage local cache (clean, verify, stats)
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
    --yes, -y           Auto-confirm operations

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
    nix-hug fetch microsoft/DialoGPT-medium --yes
    nix-hug fetch rajpurkar/squad --include '*.json'
    nix-hug fetch stanfordnlp/imdb --include '*.parquet'

${BOLD}PERSIST EXAMPLES:${NC}
    nix-hug export openai-community/gpt2
    nix-hug import openai-community/gpt2
    nix-hug import --all
    nix-hug store ls
    nix-hug store path

For more information, visit: https://github.com/longregen/nix-hug
EOF
}

# Help for fetch command
show_fetch_help() {
    cat << EOF
${BOLD}Fetch Model or Dataset${NC}

${BOLD}USAGE:${NC}
    nix-hug fetch <URL> [OPTIONS]

${BOLD}DESCRIPTION:${NC}
    Downloads a Hugging Face model or dataset and generates a pinned
    Nix expression for reproducible builds.

${BOLD}OPTIONS:${NC}
    --ref REF           Use specific git reference (default: main)
    --include PATTERN   Include LFS files matching glob pattern
    --exclude PATTERN   Exclude LFS files matching glob pattern
    --file FILENAME     Include specific file by name
    --yes, -y           Auto-confirm operations
    --help              Show this help

${BOLD}EXAMPLES:${NC}
    nix-hug fetch openai-community/gpt2
    nix-hug fetch openai-community/gpt2 --ref abc123...
    nix-hug fetch openai-community/gpt2 --include '*.safetensors'
    nix-hug fetch microsoft/DialoGPT-medium --yes
EOF
}

# Help for ls command
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

# Help for export command
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
    Set persist_dir in ~/.config/nix-hug/config or NIX_HUG_PERSIST_DIR env var.

${BOLD}EXAMPLES:${NC}
    nix-hug export openai-community/gpt2
    nix-hug export openai-community/gpt2 --include '*.safetensors'
    NIX_HUG_PERSIST_DIR=/persist/models nix-hug export stas/tiny-random-llama-2
EOF
}

# Help for import command
show_import_help() {
    cat << EOF
${BOLD}Import Model/Dataset from Persistent Storage${NC}

${BOLD}USAGE:${NC}
    nix-hug import [<URL> [--ref REF]] [--all]

${BOLD}DESCRIPTION:${NC}
    Restores a previously exported model/dataset from the persistent
    binary cache back into the Nix store.

${BOLD}OPTIONS:${NC}
    --all       Import all entries from the manifest
    --ref REF   Match a specific revision
    --yes, -y, --no-check-sigs
                Skip trust confirmation (acknowledge unsigned import)
    --help      Show this help

${BOLD}EXAMPLES:${NC}
    nix-hug import openai-community/gpt2
    nix-hug import openai-community/gpt2 --ref abc123...
    nix-hug import --all
    nix-hug import --all --yes
EOF
}

# Help for store command
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

# Display file listing with optimized formatting
display_files() {
    local files="$1"
    local header="$2"
    
    echo "$header"
    echo
    
    local total_size=0
    local lfs_count=0
    local lfs_size=0
    
    # Process files in a single pass
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

# Generate usage example after fetch - optimized template
generate_usage_example() {
    local repo_id="$1"
    local ref="$2"
    local filter_json="$3"
    local file_tree_hash="$4"

    cat << EOF
${BOLD}Usage:${NC}

$(format_fetch_model_call "" "nix-hug-lib" "$repo_id" "$ref" "$filter_json" "$file_tree_hash");
EOF
}

# Generate dataset usage example after fetch
generate_dataset_usage_example() {
    local repo_id="$1"
    local ref="$2"
    local filter_json="$3"
    local file_tree_hash="$4"

    cat << EOF
${BOLD}Usage:${NC}

$(format_fetch_dataset_call "" "nix-hug-lib" "$repo_id" "$ref" "$filter_json" "$file_tree_hash");
EOF
}

# Display filtered files with improved logic
display_filtered_files() {
    local files="$1"
    shift
    local filters=("$@")
    
    # Parse filter arguments
    local filter_type=""
    local patterns=()
    
    for ((i=0; i<${#filters[@]}; i+=2)); do
        local flag="${filters[i]}"
        local pattern="${filters[i+1]}"
        
        case "$flag" in
            --include) filter_type="include" ;;
            --exclude) filter_type="exclude" ;;
            --file) filter_type="file" ;;
        esac
        
        # Convert glob to regex for jq
        pattern=$(echo "$pattern" | sed 's/\*/\.\*/g; s/\?/\./g; s/$/$/;')
        patterns+=("$pattern")
    done
    
    # Apply filter with jq
    local filtered_files
    if [[ "$filter_type" == "include" ]]; then
        local pattern_regex
        pattern_regex=$(IFS='|'; echo "${patterns[*]}")
        # Include matching LFS files + all non-LFS files
        filtered_files=$(echo "$files" | jq --arg regex "$pattern_regex" '[.[] | select((.path | test($regex)) or (has("lfs") | not))]')
    elif [[ "$filter_type" == "exclude" ]]; then
        local pattern_regex
        pattern_regex=$(IFS='|'; echo "${patterns[*]}")
        # Exclude matching LFS files but keep all non-LFS files
        filtered_files=$(echo "$files" | jq --arg regex "$pattern_regex" '[.[] | select((.path | test($regex) | not) or (has("lfs") | not))]')
    elif [[ "$filter_type" == "file" ]]; then
        # For --file, match exact filename
        local filename="${filters[1]}"
        filtered_files=$(echo "$files" | jq --arg file "$filename" '[.[] | select(.path == $file)]')
    else
        filtered_files="$files"
    fi
    
    echo "Files matching filters: ${filters[@]@Q}"
    display_files "$filtered_files" ""
}
