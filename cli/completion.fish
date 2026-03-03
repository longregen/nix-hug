# Fish completion for nix-hug

# Disable file completions by default
complete -c nix-hug -f

# Helper: true when no subcommand has been given yet
function __nix_hug_no_subcommand
    set -l cmd (commandline -opc)
    for c in fetch ls export import scan
        if contains -- $c $cmd
            return 1
        end
    end
    return 0
end

# Helper: true when the current subcommand matches
function __nix_hug_using_subcommand
    set -l cmd (commandline -opc)
    contains -- $argv[1] $cmd
end

# Global options
complete -c nix-hug -n __nix_hug_no_subcommand -l debug -d 'Enable debug output'
complete -c nix-hug -n __nix_hug_no_subcommand -l help -d 'Show help'
complete -c nix-hug -n __nix_hug_no_subcommand -l version -d 'Show version'

# Commands
complete -c nix-hug -n __nix_hug_no_subcommand -a fetch -d 'Fetch a Hugging Face repo into the Nix store'
complete -c nix-hug -n __nix_hug_no_subcommand -a ls -d 'List files in a Hugging Face repo'
complete -c nix-hug -n __nix_hug_no_subcommand -a export -d 'Export model/dataset from Nix store to HF cache'
complete -c nix-hug -n __nix_hug_no_subcommand -a import -d 'Import model/dataset from HF cache to Nix store'
complete -c nix-hug -n __nix_hug_no_subcommand -a scan -d 'Scan Hugging Face cache directory'

# fetch options
complete -c nix-hug -n '__nix_hug_using_subcommand fetch' -l ref -r -d 'Git ref to fetch'
complete -c nix-hug -n '__nix_hug_using_subcommand fetch' -l include -r -d 'Include filter pattern'
complete -c nix-hug -n '__nix_hug_using_subcommand fetch' -l exclude -r -d 'Exclude filter pattern'
complete -c nix-hug -n '__nix_hug_using_subcommand fetch' -l file -r -F -d 'Filter file'
complete -c nix-hug -n '__nix_hug_using_subcommand fetch' -l dry-run -d 'Show what would be fetched'
complete -c nix-hug -n '__nix_hug_using_subcommand fetch' -l help -d 'Show help'

# ls options
complete -c nix-hug -n '__nix_hug_using_subcommand ls' -l ref -r -d 'Git ref'
complete -c nix-hug -n '__nix_hug_using_subcommand ls' -l include -r -d 'Include filter pattern'
complete -c nix-hug -n '__nix_hug_using_subcommand ls' -l exclude -r -d 'Exclude filter pattern'
complete -c nix-hug -n '__nix_hug_using_subcommand ls' -l file -r -F -d 'Filter file'
complete -c nix-hug -n '__nix_hug_using_subcommand ls' -l help -d 'Show help'

# export options
complete -c nix-hug -n '__nix_hug_using_subcommand export' -l ref -r -d 'Git ref'
complete -c nix-hug -n '__nix_hug_using_subcommand export' -l include -r -d 'Include filter pattern'
complete -c nix-hug -n '__nix_hug_using_subcommand export' -l exclude -r -d 'Exclude filter pattern'
complete -c nix-hug -n '__nix_hug_using_subcommand export' -l file -r -F -d 'Filter file'
complete -c nix-hug -n '__nix_hug_using_subcommand export' -l help -d 'Show help'

# import options
complete -c nix-hug -n '__nix_hug_using_subcommand import' -l ref -r -d 'Git ref'
complete -c nix-hug -n '__nix_hug_using_subcommand import' -l include -r -d 'Include filter pattern'
complete -c nix-hug -n '__nix_hug_using_subcommand import' -l exclude -r -d 'Exclude filter pattern'
complete -c nix-hug -n '__nix_hug_using_subcommand import' -l file -r -F -d 'Filter file'
complete -c nix-hug -n '__nix_hug_using_subcommand import' -l help -d 'Show help'

# scan options
complete -c nix-hug -n '__nix_hug_using_subcommand scan' -l help -d 'Show help'
