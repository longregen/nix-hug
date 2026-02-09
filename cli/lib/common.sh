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

CURRENT_LOG_LEVEL="${CURRENT_LOG_LEVEL:-${LOG_LEVEL:-INFO}}"

# Optimized color detection - only check once
if [[ -z "${NIX_HUG_COLORS_INITIALIZED:-}" ]]; then
    if command -v tput >/dev/null 2>&1 && [[ -t 2 ]]; then
        RED=$(tput setaf 1)
        GREEN=$(tput setaf 2)
        BLUE=$(tput setaf 4)
        YELLOW=$(tput setaf 3)
        BOLD=$(tput bold)
        DIM=$(tput dim)
        NC=$(tput sgr0)
    elif [[ -t 2 ]]; then
        RED=$'\033[0;31m'
        GREEN=$'\033[0;32m'
        BLUE=$'\033[0;34m'
        YELLOW=$'\033[0;33m'
        BOLD=$'\033[1m'
        DIM=$'\033[2m'
        NC=$'\033[0m'
    else
        RED=''
        GREEN=''
        BLUE=''
        YELLOW=''
        BOLD=''
        DIM=''
        NC=''
    fi
    export NIX_HUG_COLORS_INITIALIZED=1
fi

# Fix TMPDIR issues - ensure we have a working temp directory
export TMPDIR="${TMPDIR:-/tmp}"
mkdir -p "$TMPDIR" 2>/dev/null || export TMPDIR="/tmp"

# Cache directory
CACHE_DIR="${NIX_HUG_CACHE_DIR:-${HOME}/.cache/nix-hug}"
mkdir -p "$CACHE_DIR"

# Configuration file support
NIX_HUG_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/nix-hug"
NIX_HUG_CONFIG_FILE="$NIX_HUG_CONFIG_DIR/config"

# Trim leading and trailing whitespace from a string
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    echo "$s"
}

# Load config file (key=value format, ignores comments and blank lines)
load_config() {
    declare -gA NIX_HUG_CONFIG=()
    if [[ -f "$NIX_HUG_CONFIG_FILE" ]]; then
        while IFS= read -r line; do
            # Skip blank lines and comments
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
            # Require '=' separator
            [[ "$line" != *=* ]] && continue
            # Split on first '=' only
            local key="${line%%=*}"
            local value="${line#*=}"
            key=$(trim "$key")
            value=$(trim "$value")
            [[ -z "$key" ]] && continue
            NIX_HUG_CONFIG["$key"]="$value"
        done < "$NIX_HUG_CONFIG_FILE"
    fi
}

# Get config value (env var overrides config file)
get_config() {
    local key="$1"
    local default="${2:-}"
    local env_var="NIX_HUG_${key^^}"

    # Env var takes priority
    if [[ -n "${!env_var:-}" ]]; then
        echo "${!env_var}"
        return 0
    fi

    # Then config file
    if [[ -n "${NIX_HUG_CONFIG[$key]:-}" ]]; then
        echo "${NIX_HUG_CONFIG[$key]}"
        return 0
    fi

    # Default
    echo "$default"
}

# Load config on source
load_config

# Persist settings (env vars NIX_HUG_PERSIST_DIR / NIX_HUG_AUTO_PERSIST override config)
PERSIST_DIR=$(get_config "persist_dir" "")
AUTO_PERSIST=$(get_config "auto_persist" "false")

# Nix store prefix — respects NIX_STORE_DIR if set (defaults to /nix/store)
NIX_STORE="${NIX_STORE_DIR:-/nix/store}"

# Extract the store path from build output (nix build --print-out-paths)
# Handles custom NIX_STORE_DIR locations
extract_store_path() {
    local build_output="$1"
    local store_path
    store_path=$(echo "$build_output" | grep "^${NIX_STORE}/" | tail -1)
    if [[ -z "$store_path" ]]; then
        return 1
    fi
    echo "$store_path"
}

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

# Check required dependencies - optimized to check only once
check_dependencies() {
    [[ -n "${NIX_HUG_DEPS_CHECKED:-}" ]] && return 0
    
    local deps=(nix jq curl)
    local missing=()
    
    for dep in "${deps[@]}"; do
        command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required dependencies: ${missing[*]}"
        exit 1
    fi
    
    # Test network connectivity to Hugging Face
    if ! curl -s --connect-timeout 5 --max-time 10 https://huggingface.co/ >/dev/null 2>&1; then
        warn "No internet connectivity to Hugging Face - some operations may fail"
    fi
    
    export NIX_HUG_DEPS_CHECKED=1
}

# Sanitize HuggingFace URL by following redirects and detecting repo type
sanitize_hf_url() {
    local input_url="$1"
    local original_url="$input_url"
    
    # Remove common prefixes
    input_url="${input_url#https://huggingface.co/}"
    input_url="${input_url#http://huggingface.co/}"
    input_url="${input_url#hf:}"
    input_url="${input_url#hf-datasets:}"
    input_url="${input_url#datasets/}"
    input_url="${input_url#models/}"
    
    # Remove trailing path components (more comprehensive)
    input_url="${input_url%%/tree/*}"
    input_url="${input_url%%/blob/*}"
    input_url="${input_url%%/resolve/*}"
    input_url="${input_url%%/raw/*}"
    input_url="${input_url%%/commit/*}"
    input_url="${input_url%%/discussions/*}"
    input_url="${input_url%%/settings/*}"
    
    # Check if it already has models/ or datasets/ prefix
    if [[ "$input_url" =~ ^(models|datasets)/.*/.* ]]; then
        echo "$input_url"
        return 0
    fi
    
    # Handle single-word inputs (e.g., "imdb")
    if [[ ! "$input_url" =~ / ]]; then
        error "Please specify the full repository path (e.g., 'stanfordnlp/imdb' or 'openai/gpt2')"
        return 1
    fi
    
    # Extract org/repo pattern
    if [[ ! "$input_url" =~ ^([^/]+)/([^/]+)$ ]]; then
        error "Invalid repository format: $original_url"
        return 1
    fi
    
    local org="${BASH_REMATCH[1]}"
    local repo="${BASH_REMATCH[2]}"
    local repo_path="$org/$repo"
    
    debug "Checking repository type for: $repo_path"
    
    # First try datasets API (since we're prioritizing datasets)
    local dataset_url="https://huggingface.co/api/datasets/$repo_path"
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -L "$dataset_url" 2>/dev/null || echo "000")
    
    if [[ "$http_code" == "200" ]]; then
        debug "Detected as dataset repository"
        echo "datasets/$repo_path"
        return 0
    fi
    
    # Try models API
    local model_url="https://huggingface.co/api/models/$repo_path"
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -L "$model_url" 2>/dev/null || echo "000")
    
    if [[ "$http_code" == "200" ]]; then
        debug "Detected as model repository"
        echo "models/$repo_path"
        return 0
    fi
    
    # If original URL contains "dataset" anywhere, assume it's a dataset
    if [[ "$original_url" =~ dataset ]]; then
        debug "URL contains 'dataset', assuming dataset repository"
        echo "datasets/$repo_path"
        return 0
    fi
    
    # Default to models
    debug "Could not determine type, defaulting to model repository"
    echo "models/$repo_path"
    return 0
}

# Optimized size formatting using integer arithmetic where possible
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

# Parse repository URL - now expects sanitized URL with models/datasets prefix
parse_url() {
    local url="$1"
    
    # Extract type, org and repo from sanitized URL
    if [[ "$url" =~ ^(models|datasets)/([^/]+)/([^/]+)$ ]]; then
        local type="${BASH_REMATCH[1]}"
        local org="${BASH_REMATCH[2]}"
        local repo="${BASH_REMATCH[3]}"
        echo "{\"type\": \"$type\", \"org\": \"$org\", \"repo\": \"$repo\", \"repoId\": \"$type/$org/$repo\"}"
    else
        error "Invalid sanitized URL format: $url (expected {models|datasets}/org/repo)"
        return 1
    fi
}

# Compatibility wrapper - redirects to parse_url
parse_dataset_url() {
    parse_url "$1"
}

# Get display name for a repo (strips models/ prefix)
get_display_name() {
    local repo_id="$1"
    # Strip models/ prefix for display, keep datasets/ prefix
    if [[ "$repo_id" =~ ^models/(.*)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "$repo_id"
    fi
}

# Get bare repo path (org/repo) without type prefix
get_bare_repo_path() {
    local repo_id="$1"
    # Strip models/ or datasets/ prefix
    if [[ "$repo_id" =~ ^(models|datasets)/(.*)$ ]]; then
        echo "${BASH_REMATCH[2]}"
    else
        echo "$repo_id"
    fi
}

# Fixed get_flake_path function for external usage
get_flake_path() {
    # When installed via nix, use the flake path set by the wrapper
    if [[ -n "${NIX_HUG_FLAKE_PATH:-}" ]]; then
        echo "$NIX_HUG_FLAKE_PATH"
        return 0
    fi
    
    # Development mode - try to find flake.nix
    local current_dir="$PWD"
    while [[ "$current_dir" != "/" ]]; do
        if [[ -f "$current_dir/flake.nix" ]] && grep -q "nix-hug" "$current_dir/flake.nix" 2>/dev/null; then
            echo "$current_dir"
            return 0
        fi
        current_dir="$(dirname "$current_dir")"
    done
    
    # Fallback - assume we're in the project directory
    local script_dir
    if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
        if [[ -f "$script_dir/flake.nix" ]]; then
            echo "$script_dir"
            return 0
        fi
    fi
    
    error "Could not locate nix-hug flake.nix. Set NIX_HUG_FLAKE_PATH environment variable."
    return 1
}
