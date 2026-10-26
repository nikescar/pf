#!/bin/sh
# PF Blocklist Updater - Provider-based blocking
# Downloads IPs from 45+ categorized providers and generates per-source tables

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
APPNAME="update-blocklist"

# RFC 5424 syslog-style logging
log() {
    local level="$1"
    shift
    printf "%s %s %s: %s\n" "$(date +%Y-%m-%dT%H:%M:%S)" "$level" "$APPNAME" "$*"
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_trace() { log "TRACE" "$@"; }

# Load configuration
if [ ! -f "$ENV_FILE" ]; then
    log_error "$ENV_FILE not found"
    exit 1
fi

set -a
. "$ENV_FILE"
set +a

# Source provider parser library
if [ ! -f "$SCRIPT_DIR/lib/parse-providers.sh" ]; then
    log_error "Provider parser library not found: $SCRIPT_DIR/lib/parse-providers.sh"
    exit 1
fi

. "$SCRIPT_DIR/lib/parse-providers.sh"

# Files
PROVIDERS_CONF="$SCRIPT_DIR/providers.conf"
TABLES_DIR="$SCRIPT_DIR/output/tables"
BLOCKLIST_FILE="$SCRIPT_DIR/output/blocklist"
BLOCKLIST_INFO="$SCRIPT_DIR/output/blocklist.info.txt"
BACKUP_FILE="$SCRIPT_DIR/output/blocklist.bak"
BACKUP_INFO="$SCRIPT_DIR/output/blocklist.info.txt.bak"

# Temp files
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

log_info "Starting provider-based blocklist update"

#
# Function: Download providers.conf
#
download_providers_conf() {
    local url="${PF_PROVIDERS_CONF_URL:-https://raw.githubusercontent.com/nikescar/cdn-lookup/main/providers.conf}"
    local max_age=$(( ${PF_PROVIDERS_CACHE_DAYS:-7} * 86400 ))
    local needs_download=1

    if [ -f "$PROVIDERS_CONF" ]; then
        local cache_age=$(( $(date +%s) - $(stat -f %m "$PROVIDERS_CONF" 2>/dev/null || stat -c %Y "$PROVIDERS_CONF" 2>/dev/null) ))
        if [ $cache_age -le $max_age ]; then
            needs_download=0
            local days_old=$(( cache_age / 86400 ))
            log_info "Using cached providers.conf (${days_old} days old)"
        fi
    fi

    if [ $needs_download -eq 1 ]; then
        log_info "Downloading providers.conf from $url"
        curl -sSL --max-time 30 "$url" > "$PROVIDERS_CONF.tmp"

        if [ -s "$PROVIDERS_CONF.tmp" ]; then
            mv "$PROVIDERS_CONF.tmp" "$PROVIDERS_CONF"
            local count=$(grep -cv '^#\|^$' "$PROVIDERS_CONF" || echo 0)
            log_info "Downloaded $count provider entries"
        else
            log_error "Failed to download providers.conf"
            rm -f "$PROVIDERS_CONF.tmp"
            exit 1
        fi
    fi
}

#
# Function: Generate aggregated blocklist (backward compatibility)
#
generate_aggregated_blocklist() {
    log_info "Generating aggregated blocklist for backward compatibility"

    # Combine all table files
    cat "$TABLES_DIR"/*.txt 2>/dev/null | \
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$' | \
        sort -u > "$TEMP_DIR/blocklist_combined.txt"

    local total=$(wc -l < "$TEMP_DIR/blocklist_combined.txt" | tr -d ' ')
    log_info "Aggregated blocklist: $total entries"

    if [ "$total" -eq 0 ]; then
        log_warn "Aggregated blocklist is empty"
        return 1
    fi

    # Move to output
    mv "$TEMP_DIR/blocklist_combined.txt" "$BLOCKLIST_FILE"

    # Generate info file
    {
        echo "# PF Blocklist Info - Provider-based"
        echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "# Total entries: $total"
        echo ""
        echo "## Per-category breakdown:"

        for category in threat monitor security crawler; do
            local cat_files=$(find "$TABLES_DIR" -name "${category}_*.txt" 2>/dev/null | wc -l | tr -d ' ')
            local cat_ips=$(cat "$TABLES_DIR/${category}"_*.txt 2>/dev/null | wc -l | tr -d ' ')
            echo "  - $category: $cat_files sources, $cat_ips IPs"
        done

        echo ""
        echo "## Per-source details:"
        find "$TABLES_DIR" -name "*.txt" -type f | sort | while read -r file; do
            local basename=$(basename "$file" .txt)
            local count=$(wc -l < "$file" | tr -d ' ')
            printf "  - %-40s %8d IPs\n" "$basename" "$count"
        done
    } > "$BLOCKLIST_INFO"

    log_info "Generated blocklist info: $BLOCKLIST_INFO"
}

#
# Main execution
#

# Backup existing files
if [ -f "$BLOCKLIST_FILE" ]; then
    cp "$BLOCKLIST_FILE" "$BACKUP_FILE"
    log_info "Backed up blocklist to $BACKUP_FILE"
fi

if [ -f "$BLOCKLIST_INFO" ]; then
    cp "$BLOCKLIST_INFO" "$BACKUP_INFO"
fi

# Create tables directory
mkdir -p "$TABLES_DIR"

# Download providers.conf
download_providers_conf

# Check required commands
for cmd in jq curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "Required command not found: $cmd"
        log_error "Please install: pkg_add $cmd"
        exit 1
    fi
done

# Process all providers
log_info "Processing providers from $PROVIDERS_CONF"
if ! process_providers "$PROVIDERS_CONF" "$TABLES_DIR"; then
    log_error "Failed to process providers"
    exit 1
fi

# Generate aggregated blocklist
if ! generate_aggregated_blocklist; then
    log_warn "Failed to generate aggregated blocklist (non-fatal)"
fi

log_info "Blocklist update complete"
log_info "Tables stored in: $TABLES_DIR"
log_info "Aggregated blocklist: $BLOCKLIST_FILE"
