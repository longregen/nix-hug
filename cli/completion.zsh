#compdef nix-hug

_nix_hug() {
    local -a commands global_opts
    commands=(
        'fetch:Fetch a Hugging Face repo into the Nix store'
        'ls:List files in a Hugging Face repo'
        'export:Export model/dataset from Nix store to HF cache'
        'import:Import model/dataset from HF cache to Nix store'
        'scan:Scan Hugging Face cache directory'
    )
    global_opts=(
        '--debug[Enable debug output]'
        '--help[Show help]'
        '--version[Show version]'
    )

    local -a fetch_opts=(
        '--ref[Git ref to fetch]:ref:'
        '--include[Include filter pattern]:pattern:'
        '--exclude[Exclude filter pattern]:pattern:'
        '--file[Filter file]:file:_files'
        '--dry-run[Show what would be fetched]'
        '--help[Show help]'
    )
    local -a ls_opts=(
        '--ref[Git ref]:ref:'
        '--include[Include filter pattern]:pattern:'
        '--exclude[Exclude filter pattern]:pattern:'
        '--file[Filter file]:file:_files'
        '--help[Show help]'
    )
    local -a export_opts=(
        '--ref[Git ref]:ref:'
        '--include[Include filter pattern]:pattern:'
        '--exclude[Exclude filter pattern]:pattern:'
        '--file[Filter file]:file:_files'
        '--help[Show help]'
    )
    local -a import_opts=(
        '--ref[Git ref]:ref:'
        '--include[Include filter pattern]:pattern:'
        '--exclude[Exclude filter pattern]:pattern:'
        '--file[Filter file]:file:_files'
        '--help[Show help]'
    )
    local -a scan_opts=(
        '--help[Show help]'
    )

    if (( CURRENT == 2 )); then
        _describe -t commands 'nix-hug command' commands
        _arguments -s $global_opts
        return
    fi

    case "$words[2]" in
        fetch)  _arguments -s $fetch_opts ;;
        ls)     _arguments -s $ls_opts ;;
        export) _arguments -s $export_opts ;;
        import) _arguments -s $import_opts ;;
        scan)   _arguments -s $scan_opts ;;
    esac
}

_nix_hug "$@"
