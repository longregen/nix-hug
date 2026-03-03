# Bash completion for nix-hug

_nix_hug() {
    local cur prev words cword
    _init_completion || return

    # Commands
    local commands="fetch ls export import scan"

    # Global options
    local global_opts="--debug --help --version"

    # Command-specific options
    local fetch_opts="--ref --include --exclude --file --dry-run --help"
    local ls_opts="--ref --include --exclude --file --help"
    local export_opts="--ref --include --exclude --file --help"
    local import_opts="--ref --include --exclude --file --help"
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
