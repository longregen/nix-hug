# Bash completion for nix-hug

_nix_hug_cached_repos() {
    local hf_cache="${HF_HUB_CACHE:-${HF_HOME:+$HF_HOME/hub}}"
    hf_cache="${hf_cache:-${XDG_CACHE_HOME:-$HOME/.cache}/huggingface/hub}"
    [[ -d "$hf_cache" ]] || return

    local dir
    for dir in "$hf_cache"/{models,datasets}--*--*/; do
        [[ -d "$dir" ]] || continue
        local name="${dir%/}"
        name="${name##*/}"
        # models--org--repo -> org/repo
        name="${name#models--}"
        name="${name#datasets--}"
        # first -- becomes /
        echo "${name/--//}"
    done
}

_nix_hug() {
    local cur prev words cword
    _init_completion || return

    # Commands
    local commands="fetch ls export import import-all scan"

    # Global options
    local global_opts="--debug --help --version"

    # Command-specific options
    local fetch_opts="--ref --include --exclude --file --dry-run --help"
    local ls_opts="--ref --include --exclude --file --help"
    local export_opts="--ref --include --exclude --file --help"
    local import_opts="--ref --include --exclude --file --help"
    local import_all_opts="-y --yes --help"
    local scan_opts="--help"

    # Complete commands
    if [[ $cword -eq 1 ]]; then
        COMPREPLY=($(compgen -W "$commands $global_opts" -- "$cur"))
        return
    fi

    # Complete command options
    case "${words[1]}" in
        fetch)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "$fetch_opts" -- "$cur"))
            fi
            ;;
        ls)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "$ls_opts" -- "$cur"))
            fi
            ;;
        export)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "$export_opts" -- "$cur"))
            fi
            ;;
        import)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "$import_opts" -- "$cur"))
            else
                COMPREPLY=($(compgen -W "$(_nix_hug_cached_repos)" -- "$cur"))
            fi
            ;;
        import-all)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "$import_all_opts" -- "$cur"))
            fi
            ;;
        scan)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "$scan_opts" -- "$cur"))
            fi
            ;;
    esac
}

complete -F _nix_hug nix-hug
