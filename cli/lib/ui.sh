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

For more information, visit: https://github.com/longregen/nix-hug
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
    local derivation_hash="$5"

    cat << EOF
${BOLD}Usage:${NC}

$(format_fetch_model_call "" "nix-hug-lib" "$repo_id" "$ref" "$filter_json" "$file_tree_hash" "$derivation_hash");
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
