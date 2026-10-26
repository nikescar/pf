#!/bin/sh
# Common bash functions for PF blocklist management
# Sourced by pfhelper.sh and other scripts

#
# RFC 5424 syslog-style logging
#
log() {
    local level="$1"
    shift
    printf "%s %s %s: %s\n" "$(date +%Y-%m-%dT%H:%M:%S)" "$level" "${APPNAME:-pfhelper}" "$*"
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_trace() { log "TRACE" "$@"; }

#
# Get script directory (portable across different invocations)
#
get_script_dir() {
    cd "$(dirname "$0")" && pwd
}

#
# Load and validate .env file
# Usage: load_env [env_file_path]
#
load_env() {
    local env_file="${1:-$(get_script_dir)/.env}"

    if [ ! -f "$env_file" ]; then
        log_error ".env not found: $env_file"
        log_error "Copy .env.example to .env and configure"
        exit 1
    fi

    set -a
    . "$env_file"
    set +a

    log_trace "Loaded environment from: $env_file"
}

#
# Check if running as root, exit if not
# Usage: require_root
#
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This command must be run as root (use doas)"
        exit 1
    fi
}

#
# Ensure directory exists, create if needed
# Usage: ensure_dir "path/to/dir"
#
ensure_dir() {
    local dir="$1"

    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        log_trace "Created directory: $dir"
    fi
}

#
# Backup file with .bak extension (single backup, no timestamps)
# Usage: backup_file "file_path"
#
backup_file() {
    local file="$1"
    local backup="${file}.bak"

    if [ -f "$file" ]; then
        cp "$file" "$backup"
        log_trace "Backed up: $file -> $backup"
        return 0
    fi

    return 1
}

#
# Download file with timeout and validation
# Usage: download_file "url" "output_path" [timeout_seconds]
#
download_file() {
    local url="$1"
    local output="$2"
    local timeout="${3:-30}"

    if curl -sSL --max-time "$timeout" "$url" -o "$output" 2>/dev/null; then
        if [ -s "$output" ]; then
            return 0
        else
            log_warn "Downloaded file is empty: $output"
            rm -f "$output"
            return 1
        fi
    else
        log_warn "Failed to download: $url"
        return 1
    fi
}

#
# Check if required command exists
# Usage: require_command "jq" "curl" "pfctl"
#
require_command() {
    local missing=""

    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing="$missing $cmd"
        fi
    done

    if [ -n "$missing" ]; then
        log_error "Required commands not found:$missing"
        log_error "Install with: pkg_add$missing"
        exit 1
    fi
}
