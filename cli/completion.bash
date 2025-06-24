# Bash completion for nix-hug

_nix_hug() {
    local cur prev words cword
    _init_completion || return
    
    # Commands
    local commands="fetch ls"
    
    # Global options
    local global_opts="--debug --help --version"
    
    # Command-specific options
    local fetch_opts="--ref --include --exclude --file --yes -y"
    local ls_opts="--ref --include --exclude"
    
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
    esac
}

complete -F _nix_hug nix-hug
