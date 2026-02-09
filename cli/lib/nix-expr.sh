# Nix expression generation utilities

# Helper function to format fetchModel call with proper indentation
format_fetch_model_call() {
    local indent="$1"
    local lib="$2"
    local repo_id="$3"
    local ref="$4"
    local filter_json="$5"
    local file_tree_hash="$6"

    local filter_line=""
    if [[ "$filter_json" != "null" ]]; then
        filter_line=$'\n'"${indent}  filters = $filter_json;"
    fi

    cat << EOF
${indent}$lib.fetchModel {
${indent}  url = "$repo_id";
${indent}  rev = "$ref";$filter_line
${indent}  fileTreeHash = "$file_tree_hash";
${indent}}
EOF
}

# Generate a fetchModel expression
generate_fetch_model_expr() {
    local repo_id="$1"
    local ref="$2"
    local filter_json="$3"
    local file_tree_hash="$4"

    cat <<EOF
let
  flake = builtins.getFlake "$(get_flake_path)";
  lib = flake.lib.\${builtins.currentSystem};
in
  $(format_fetch_model_call "  " "lib" "$repo_id" "$ref" "$filter_json" "$file_tree_hash")
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
    local file_tree_hash="$6"

    local filter_line=""
    if [[ "$filter_json" != "null" ]]; then
        filter_line=$'\n'"${indent}  filters = $filter_json;"
    fi

    cat << EOF
${indent}$lib.fetchDataset {
${indent}  url = "$repo_id";
${indent}  rev = "$ref";$filter_line
${indent}  fileTreeHash = "$file_tree_hash";
${indent}}
EOF
}

# Generate a fetchDataset expression
generate_fetch_dataset_expr() {
    local repo_id="$1"
    local ref="$2"
    local filter_json="$3"
    local file_tree_hash="$4"

    cat <<EOF
let
  flake = builtins.getFlake "$(get_flake_path)";
  lib = flake.lib.\${builtins.currentSystem};
in
  $(format_fetch_dataset_call "  " "lib" "$repo_id" "$ref" "$filter_json" "$file_tree_hash")
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

# Generate dataset usage example
generate_dataset_usage_example() {
    local repo_id="$1"
    local ref="$2"
    local filter_json="$3"
    local file_tree_hash="$4"

    echo -e "${BOLD}Usage:${NC}\n"

    local filter_line=""
    if [[ "$filter_json" != "null" ]]; then
        filter_line=$'\n'"  filters = $filter_json;"
    fi

    cat <<EOF
nix-hug-lib.fetchDataset {
  url = "$repo_id";
  rev = "$ref";$filter_line
  fileTreeHash = "$file_tree_hash";
}
EOF
}

# Generate model usage example
generate_usage_example() {
    local repo_id="$1"
    local ref="$2"
    local filter_json="$3"
    local file_tree_hash="$4"

    echo -e "\n${BLUE}To use this model in a Nix expression:${NC}"

    local filter_line=""
    if [[ "$filter_json" != "null" ]]; then
        filter_line=$'\n'"    filters = $filter_json;"
    fi

    cat <<EOF
  let
    nix-hug = builtins.getFlake "github:nix-hug/nix-hug";
    lib = nix-hug.lib.\${builtins.currentSystem};
  in
    lib.fetchModel {
      url = "$repo_id";
      rev = "$ref";$filter_line
      fileTreeHash = "$file_tree_hash";
    }
EOF
}
