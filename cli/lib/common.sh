VERSION="4.0.0"

declare -A LOG_LEVELS=(
    [TRACE]=0
    [DEBUG]=1
    [INFO]=2
    [OK]=3
    [WARN]=4
    [ERROR]=5
)

CURRENT_LOG_LEVEL="${CURRENT_LOG_LEVEL:-${LOG_LEVEL:-INFO}}"

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

export TMPDIR="${TMPDIR:-/tmp}"
mkdir -p "$TMPDIR" 2>/dev/null || export TMPDIR="/tmp"

NIX_HUG_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/nix-hug"
NIX_HUG_CONFIG_FILE="$NIX_HUG_CONFIG_DIR/config"

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    echo "$s"
}

load_config() {
    declare -gA NIX_HUG_CONFIG=()
    if [[ -f "$NIX_HUG_CONFIG_FILE" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
            [[ "$line" != *=* ]] && continue
            local key="${line%%=*}"
            local value="${line#*=}"
            key=$(trim "$key")
            value=$(trim "$value")
            [[ -z "$key" ]] && continue
            NIX_HUG_CONFIG["$key"]="$value"
        done < "$NIX_HUG_CONFIG_FILE"
    fi
}

get_config() {
    local key="$1"
    local default="${2:-}"
    local env_var="NIX_HUG_${key^^}"

    if [[ -n "${!env_var:-}" ]]; then
        echo "${!env_var}"
        return 0
    fi

    if [[ -n "${NIX_HUG_CONFIG[$key]:-}" ]]; then
        echo "${NIX_HUG_CONFIG[$key]}"
        return 0
    fi

    echo "$default"
}

load_config

PERSIST_DIR=$(get_config "persist_dir" "")
AUTO_PERSIST=$(get_config "auto_persist" "false")

NIX_STORE="${NIX_STORE_DIR:-/nix/store}"

extract_store_path() {
    local build_output="$1"
    local store_path
    store_path=$(echo "$build_output" | grep "^${NIX_STORE}/" | tail -1)
    if [[ -z "$store_path" ]]; then
        return 1
    fi
    echo "$store_path"
}

log() {
    local lvl=$1 msg=$2
    shift 2
    
    local current_level_num=${LOG_LEVELS[$CURRENT_LOG_LEVEL]:-1}
    local msg_level_num=${LOG_LEVELS[$lvl]:-0}
    
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

debug() { log DEBUG "$*"; }
info() { log INFO "$*"; }
ok() { log OK "$*"; }
warn() { log WARN "$*"; }
error() { log ERROR "$*"; }

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
    
    if ! curl -s --connect-timeout 5 --max-time 10 https://huggingface.co/ >/dev/null 2>&1; then
        warn "No internet connectivity to Hugging Face - some operations may fail"
    fi
    
    export NIX_HUG_DEPS_CHECKED=1
}

sanitize_hf_url() {
    local input_url="$1"
    local original_url="$input_url"
    
    input_url="${input_url#https://huggingface.co/}"
    input_url="${input_url#http://huggingface.co/}"
    input_url="${input_url#hf:}"
    input_url="${input_url#hf-datasets:}"
    input_url="${input_url#datasets/}"
    input_url="${input_url#models/}"
    
    input_url="${input_url%%/tree/*}"
    input_url="${input_url%%/blob/*}"
    input_url="${input_url%%/resolve/*}"
    input_url="${input_url%%/raw/*}"
    input_url="${input_url%%/commit/*}"
    input_url="${input_url%%/discussions/*}"
    input_url="${input_url%%/settings/*}"
    
    if [[ ! "$input_url" =~ / ]]; then
        error "Please specify the full repository path (e.g., 'stanfordnlp/imdb' or 'openai/gpt2')"
        return 1
    fi
    
    if [[ ! "$input_url" =~ ^([^/]+)/([^/]+)$ ]]; then
        error "Invalid repository format: $original_url"
        return 1
    fi
    
    local org="${BASH_REMATCH[1]}"
    local repo="${BASH_REMATCH[2]}"
    local repo_path="$org/$repo"
    
    debug "Checking repository type for: $repo_path"
    
    local dataset_url="https://huggingface.co/api/datasets/$repo_path"
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -L "$dataset_url" 2>/dev/null || echo "000")
    
    if [[ "$http_code" == "200" ]]; then
        debug "Detected as dataset repository"
        echo "datasets/$repo_path"
        return 0
    fi
    
    local model_url="https://huggingface.co/api/models/$repo_path"
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -L "$model_url" 2>/dev/null || echo "000")
    
    if [[ "$http_code" == "200" ]]; then
        debug "Detected as model repository"
        echo "models/$repo_path"
        return 0
    fi
    
    if [[ "$original_url" =~ dataset ]]; then
        debug "URL contains 'dataset', assuming dataset repository"
        echo "datasets/$repo_path"
        return 0
    fi
    
    debug "Could not determine type, defaulting to model repository"
    echo "models/$repo_path"
    return 0
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

parse_url() {
    local url="$1"
    
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

get_display_name() {
    local repo_id="$1"
    if [[ "$repo_id" =~ ^models/(.*)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "$repo_id"
    fi
}

get_bare_repo_path() {
    local repo_id="$1"
    if [[ "$repo_id" =~ ^(models|datasets)/(.*)$ ]]; then
        echo "${BASH_REMATCH[2]}"
    else
        echo "$repo_id"
    fi
}

get_flake_path() {
    if [[ -n "${NIX_HUG_FLAKE_PATH:-}" ]]; then
        echo "$NIX_HUG_FLAKE_PATH"
        return 0
    fi
    
    local current_dir="$PWD"
    while [[ "$current_dir" != "/" ]]; do
        if [[ -f "$current_dir/flake.nix" ]] && grep -q "nix-hug" "$current_dir/flake.nix" 2>/dev/null; then
            echo "$current_dir"
            return 0
        fi
        current_dir="$(dirname "$current_dir")"
    done
    
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

resolve_ref() {
    local ref="$1" repo_id="$2"
    if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
        echo "$ref"
        return 0
    fi
    local api_url="https://huggingface.co/api/$repo_id/revision/$ref"
    local api_response
    api_response=$(curl -sfL "$api_url") || {
        error "Failed to resolve ref '$ref' for $repo_id"
        return 1
    }
    local resolved
    resolved=$(echo "$api_response" | jq -r '.sha // empty') || true
    if [[ -z "$resolved" ]]; then
        error "Could not resolve ref '$ref' to a commit hash"
        return 1
    fi
    debug "Resolved '$ref' to commit hash: $resolved"
    echo "$resolved"
}

glob_to_regex() {
    printf '%s' "$1" | sed 's/\./\\./g; s/\*/\.\*/g; s/\?/\./g'
}
