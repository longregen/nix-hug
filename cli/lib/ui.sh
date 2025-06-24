# UI and formatting functions

show_help() {
    cat << EOF
${BOLD}nix-hug${NC} - Declarative Hugging Face model management for Nix

${BOLD}USAGE:${NC}
    nix-hug [OPTIONS] <COMMAND> [ARGS]

${BOLD}COMMANDS:${NC}
    fetch    Download model and generate Nix expression
    ls       List repository contents without downloading

${BOLD}OPTIONS:${NC}
    --debug     Show detailed execution steps
    --version   Show version information
    --help      Show this help message

${BOLD}EXAMPLES:${NC}
    nix-hug fetch openai-community/gpt2
    nix-hug fetch openai-community/gpt2 --include '*.safetensors'
    nix-hug ls openai-community/gpt2 --exclude '*.bin'

For detailed command help, see the README or run:
    nix-hug <command> --help
EOF
}

# Display file listing
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


# Generate usage example after fetch
generate_usage_example() {
    local repo_id="$1"
    local ref="$2"
    local filter_json="$3"
    local repo_info_hash="$4"
    local file_tree_hash="$5"
    local derivation_hash="$6"
    
    cat << EOF

${GREEN}Download complete!${NC}

${BOLD}Usage in your Nix configuration:${NC}

\`\`\`nix
{
  inputs.nix-hug.url = "github:longregen/nix-hug";
  
  outputs = { self, nixpkgs, nix-hug }: {
    packages.x86_64-linux.myModel = 
      nix-hug.lib.x86_64-linux.fetchModel {
        url = "$repo_id";
        rev = "$ref";
$(if [[ "$filter_json" != "null" ]]; then echo "        filters = $filter_json;"; fi)
        repoInfoHash = "$repo_info_hash";
        fileTreeHash = "$file_tree_hash";
        derivationHash = "$derivation_hash";
      };
  };
}
\`\`\`

${BOLD}Or use directly:${NC}

nix-hug.lib.fetchModel {
  url = "$repo_id";
  rev = "$ref";
$(if [[ "$filter_json" != "null" ]]; then echo "  filters = $filter_json;"; fi)
  repoInfoHash = "$repo_info_hash";
  fileTreeHash = "$file_tree_hash";
  derivationHash = "$derivation_hash";
};
EOF
}


# Display filtered files
display_filtered_files() {
    local files="$1"
    shift
    local filters=("$@")
    
    # Apply filters using jq
    local filter_type=""
    local patterns=()
    
    # Parse filter arguments
    for ((i=0; i<${#filters[@]}; i+=2)); do
        local flag="${filters[i]}"
        local pattern="${filters[i+1]}"
        
        case "$flag" in
            --include)
                filter_type="include"
                ;;
            --exclude)
                filter_type="exclude"
                ;;
        esac
        
        # Convert glob to regex
        pattern=$(echo "$pattern" | sed 's/\*/\.\*/g; s/\?/\./g; s/$/$/;')
        patterns+=("$pattern")
    done
    
    # Apply filter with jq - include non-LFS files for include/exclude filters
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
    else
        filtered_files="$files"
    fi
    
    echo "Files matching filters: ${filters[*]}"
    display_files "$filtered_files" ""
}
