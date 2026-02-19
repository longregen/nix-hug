format_fetch_call() {
    local indent="$1"
    local lib="$2"
    local nix_func="$3"
    local repo_id="$4"
    local ref="$5"
    local filter_json="$6"
    local file_tree_hash="$7"

    local filter_line=""
    if [[ "$filter_json" != "null" ]]; then
        filter_line=$'\n'"${indent}  filters = $filter_json;"
    fi

    cat << EOF
${indent}$lib.$nix_func {
${indent}  url = "$repo_id";
${indent}  rev = "$ref";$filter_line
${indent}  fileTreeHash = "$file_tree_hash";
${indent}}
EOF
}

generate_fetch_expr() {
    local nix_func="$1"
    local repo_id="$2"
    local ref="$3"
    local filter_json="$4"
    local file_tree_hash="$5"

    cat <<EOF
let
  flake = builtins.getFlake "$(get_flake_path)";
  lib = flake.lib.\${builtins.currentSystem};
in
  $(format_fetch_call "  " "lib" "$nix_func" "$repo_id" "$ref" "$filter_json" "$file_tree_hash")
EOF
}

build_with_expr() {
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
