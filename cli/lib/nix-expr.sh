# Nix expression generation utilities

# Helper function to format fetchModel call with proper indentation
format_fetch_model_call() {
    local indent="$1"
    local lib="$2"
    local repo_id="$3"
    local ref="$4"
    local filter_json="$5"
    local repo_info_hash="$6"
    local file_tree_hash="$7"
    local derivation_hash="$8"
    
    local filter_line=""
    if [[ "$filter_json" != "null" ]]; then
        filter_line="${indent}  filters = $filter_json;"
    fi
    
    cat << EOF
${indent}$lib.fetchModel {
${indent}  url = "$repo_id";
${indent}  rev = "$ref";
$filter_line
${indent}  repoInfoHash = "$repo_info_hash";
${indent}  fileTreeHash = "$file_tree_hash";
${indent}  derivationHash = "$derivation_hash";
${indent}}
EOF
}

# Generate a fetchModel expression
generate_fetch_model_expr() {
    local repo_id="$1"
    local ref="$2"
    local filter_json="$3"
    local repo_info_hash="$4"
    local file_tree_hash="$5"
    local derivation_hash="$6"
    
    cat <<EOF
let
  flake = builtins.getFlake "$(get_flake_path)";
  lib = flake.lib.\${builtins.currentSystem};
in
  $(format_fetch_model_call "  " "lib" "$repo_id" "$ref" "$filter_json" "$repo_info_hash" "$file_tree_hash" "$derivation_hash")
EOF
}

# Build a model with the given parameters
build_model_with_expr() {
    local expr="$1"
    local operation_name="${2:-build}"
    
    debug "$operation_name expression: $expr"
    
    local build_output
    if build_output=$(nix --extra-experimental-features 'nix-command flakes' build --impure --expr "$expr" --no-link --print-out-paths 2>&1); then
        echo "$build_output"
        return 0
    else
        debug "$operation_name output: $build_output"
        echo "$build_output" >&2
        return 1
    fi
}

# Helper function to format fetchDataset call with proper indentation
format_fetch_dataset_call() {
    local indent="$1"
    local lib="$2"
    local repo_id="$3"
    local ref="$4"
    local filter_json="$5"
    local repo_info_hash="$6"
    local file_tree_hash="$7"
    local derivation_hash="$8"
    
    local filter_line=""
    if [[ "$filter_json" != "null" ]]; then
        filter_line="${indent}  filters = $filter_json;"
    fi
    
    cat << EOF
${indent}$lib.fetchDataset {
${indent}  url = "$repo_id";
${indent}  rev = "$ref";
$filter_line
${indent}  repoInfoHash = "$repo_info_hash";
${indent}  fileTreeHash = "$file_tree_hash";
${indent}  derivationHash = "$derivation_hash";
${indent}}
EOF
}

# Generate a fetchDataset expression
generate_fetch_dataset_expr() {
    local repo_id="$1"
    local ref="$2"
    local filter_json="$3"
    local repo_info_hash="$4"
    local file_tree_hash="$5"
    local derivation_hash="$6"
    
    cat <<EOF
let
  flake = builtins.getFlake "$(get_flake_path)";
  lib = flake.lib.\${builtins.currentSystem};
in
  $(format_fetch_dataset_call "  " "lib" "$repo_id" "$ref" "$filter_json" "$repo_info_hash" "$file_tree_hash" "$derivation_hash")
EOF
}

# Build a dataset with the given parameters
build_dataset_with_expr() {
    local expr="$1"
    local operation_name="${2:-build}"
    
    debug "$operation_name expression: $expr"
    
    local build_output
    if build_output=$(nix --extra-experimental-features 'nix-command flakes' build --impure --expr "$expr" --no-link --print-out-paths 2>&1); then
        echo "$build_output"
        return 0
    else
        debug "$operation_name output: $build_output"
        echo "$build_output" >&2
        return 1
    fi
}

# Extract derivation hash from build error output
extract_derivation_hash() {
    local build_output="$1"
    
    # Try to find SRI format hash first (sha256-...)
    local sri_hash
    sri_hash=$(echo "$build_output" | grep -o 'sha256-[A-Za-z0-9+/=]*' | tail -1)
    
    if [[ -n "$sri_hash" ]]; then
        echo "$sri_hash"
        return 0
    fi
    
    # Look for bare hash in quotes (52 characters, base32-encoded)
    local bare_hash
    bare_hash=$(echo "$build_output" | grep -oE "'[0-9a-z]{52}'" | sed "s/'//g" | tail -1)
    
    if [[ -n "$bare_hash" ]]; then
        # Convert to SRI format
        echo "sha256-$bare_hash"
        return 0
    fi
    
    # If no hash found, return empty
    return 1
}

# Generate dataset usage example
generate_dataset_usage_example() {
    local repo_id="$1"
    local ref="$2"
    local filter_json="$3"
    local repo_info_hash="$4"
    local file_tree_hash="$5"
    local derivation_hash="$6"
    
    echo -e "${BOLD}Usage:${NC}\n"
    
    local filter_line=""
    if [[ "$filter_json" != "null" ]]; then
        filter_line="  filters = $filter_json;"
    fi
    
    cat <<EOF
nix-hug-lib.fetchDataset {
  url = "$repo_id";
  rev = "$ref";
$filter_line
  repoInfoHash = "$repo_info_hash";
  fileTreeHash = "$file_tree_hash";
  derivationHash = "$derivation_hash";
}
EOF
}

# Generate model usage example
generate_usage_example() {
    local repo_id="$1"
    local ref="$2"
    local filter_json="$3"
    local repo_info_hash="$4"
    local file_tree_hash="$5"
    local derivation_hash="$6"
    
    echo -e "\n${BLUE}To use this model in a Nix expression:${NC}"
    
    local filter_line=""
    if [[ "$filter_json" != "null" ]]; then
        filter_line="    filters = $filter_json;"
    fi
    
    cat <<EOF
  let
    nix-hug = builtins.getFlake "github:nix-hug/nix-hug";
    lib = nix-hug.lib.\${builtins.currentSystem};
  in
    lib.fetchModel {
      url = "$repo_id";
      rev = "$ref";
$filter_line
      repoInfoHash = "$repo_info_hash";
      fileTreeHash = "$file_tree_hash";
      derivationHash = "$derivation_hash";
    }
EOF
}
