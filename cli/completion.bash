# Bash completion for nix-hug

_nix_hug() {
    local cur prev words cword
    _init_completion || return
    
    # Commands
    local commands="fetch ls export import store"

    # Global options
    local global_opts="--debug --help --version"

    # Command-specific options
    local fetch_opts="--ref --include --exclude --file --out -o --override --help"
    local ls_opts="--ref --include --exclude --file --help"
    local export_opts="--ref --include --exclude --file --help"
    local import_opts="--all --ref --path --yes -y --no-check-sigs --help"
    local store_actions="ls list path"
    
    # Complete commands
    if [[ $cword -eq 1 ]]; then
        COMPREPLY=($(compgen -W "$commands $global_opts" -- "$cur"))
        return
    fi
    
    # Complete command options
    case "${words[1]}" in
        fetch)
            case "$prev" in
                --out|-o)
                    COMPREPLY=($(compgen -d -- "$cur"))
                    return
                    ;;
            esac
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
            case "$prev" in
                --path)
                    COMPREPLY=($(compgen -d -- "$cur"))
                    return
                    ;;
            esac
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "$import_opts" -- "$cur"))
            fi
            ;;
        store)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=($(compgen -W "$store_actions" -- "$cur"))
            fi
            ;;
    esac
}

complete -F _nix_hug nix-hug
