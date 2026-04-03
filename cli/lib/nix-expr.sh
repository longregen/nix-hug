# Format a Nix function call with named attributes.
# Usage: format_nix_call indent lib func_name "key=value" "key=value" ...
# Special: a key named "filters" with value "null" is omitted.
format_nix_call() {
    local indent="$1" lib="$2" func="$3"
    shift 3

    local body=""
    for pair in "$@"; do
        local key="${pair%%=*}" val="${pair#*=}"
        [[ "$key" == "filters" && "$val" == "null" ]] && continue
        body+="${indent}  ${key} = ${val};"$'\n'
    done

    printf '%s%s.%s {\n%s%s}\n' "$indent" "$lib" "$func" "$body" "$indent"
}

format_fetch_call() {
    local indent="$1" lib="$2" nix_func="$3"
    local repo_id="$4" ref="$5" filter_json="$6" file_tree_hash="$7"

    format_nix_call "$indent" "$lib" "$nix_func" \
        "url=\"$repo_id\"" \
        "rev=\"$ref\"" \
        "filters=$filter_json" \
        "fileTreeHash=\"$file_tree_hash\""
}

format_git_fetch_call() {
    local indent="$1" lib="$2"
    local git_url="$3" rev="$4" lfs_url="$5" filter_json="$6"

    format_nix_call "$indent" "$lib" "fetchGitLFS" \
        "url=\"$git_url\"" \
        "rev=\"$rev\"" \
        "lfsUrl=\"$lfs_url\"" \
        "filters=$filter_json"
}

generate_fetch_expr() {
    local nix_func="$1" repo_id="$2" ref="$3" filter_json="$4" file_tree_hash="$5"

    cat <<EOF
let
  flake = builtins.getFlake "$(get_flake_path)";
  lib = flake.lib.\${builtins.currentSystem};
in
  $(format_fetch_call "  " "lib" "$nix_func" "$repo_id" "$ref" "$filter_json" "$file_tree_hash")
EOF
}

generate_git_fetch_expr() {
    local git_url="$1" rev="$2" lfs_url="$3" filter_json="$4"

    cat <<EOF
let
  flake = builtins.getFlake "$(get_flake_path)";
  lib = flake.lib.\${builtins.currentSystem};
in
  $(format_git_fetch_call "  " "lib" "$git_url" "$rev" "$lfs_url" "$filter_json")
EOF
}

build_with_expr() {
    local expr="$1"
    local operation_name="${2:-build}"

    debug "$operation_name expression: $expr"

    local build_output
    if build_output=$(nix --extra-experimental-features 'nix-command flakes' build --impure --expr "$expr" --no-link --print-out-paths); then
        echo "$build_output"
        return 0
    else
        return 1
    fi
}
