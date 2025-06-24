# Common constants and functions
VERSION="3.0.0"
DEBUG="${DEBUG:-false}"

declare -A LOG_LEVELS=(
    [TRACE]=0
    [DEBUG]=1
    [INFO]=2
    [OK]=3
    [WARN]=4
    [ERROR]=5
)

CURRENT_LOG_LEVEL="${LOG_LEVEL:-OK}"

if command -v tput >/dev/null 2>&1 && [[ -t 2 ]]; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    BLUE=$(tput setaf 4)
    YELLOW=$(tput setaf 3)
    BOLD=$(tput bold)
    DIM=$(tput dim)
    NC=$(tput sgr0)
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    YELLOW='\033[0;33m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
fi

# Cache directory
CACHE_DIR="${NIX_HUG_CACHE_DIR:-${HOME}/.cache/nix-hug}"
mkdir -p "$CACHE_DIR"

# Unified logging function with hierarchical levels
log() {
    local lvl=$1 msg=$2
    shift 2
    
    # Check if this log level should be shown
    local current_level_num=${LOG_LEVELS[$CURRENT_LOG_LEVEL]:-1}
    local msg_level_num=${LOG_LEVELS[$lvl]:-0}
    
    # Skip if message level is lower than current threshold
    (( msg_level_num < current_level_num )) && return
    
    local color=""
    case $lvl in
        DEBUG) color=$DIM ;;
        INFO) color=$BLUE ;;
        OK) color=$GREEN ;;
        WARN) color=$YELLOW ;;
        ERROR) color=$RED ;;
    esac
    
    printf '%s[%s]%s %b\n' "$color" "$lvl" "$NC" "$msg" >&2
}

# Convenience wrappers
debug() { log DEBUG "$*"; }
info() { log INFO "$*"; }
ok() { log OK "$*"; }
warn() { log WARN "$*"; }
error() { log ERROR "$*"; }

# Check required dependencies
check_dependencies() {
    local deps=(nix jq curl)
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            error "$dep is required but not found in PATH"
            exit 1
        fi
    done
}

format_size() {
    local bytes=$1
    if (( bytes < 1024 )); then
        echo "${bytes} B"
    elif (( bytes < 1048576 )); then
        echo "$((bytes / 1024)) KB"
    elif (( bytes < 1073741824 )); then
        awk "BEGIN { printf \"%.1f MB\", $bytes / 1048576 }"
    else
        awk "BEGIN { printf \"%.1f GB\", $bytes / 1073741824 }"
    fi
}

# Parse repository URL
parse_url() {
    local url="$1"
    local cleaned
    
    cleaned="${url#https://huggingface.co/}"
    cleaned="${cleaned#http://huggingface.co/}"
    cleaned="${cleaned#hf:}"
    
    IFS='/' read -r org repo _ <<< "$cleaned"
    
    if [[ -z "$org" ]] || [[ -z "$repo" ]]; then
        error "Invalid repository URL: $url"
        return 1
    fi
    
    repo="${repo%%/tree/*}"
    
    echo "{\"org\": \"$org\", \"repo\": \"$repo\", \"repoId\": \"$org/$repo\"}"
}

get_flake_path() {
    echo "${NIX_HUG_FLAKE_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
}
