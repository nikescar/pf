#!/bin/sh
# PF Blocklist Applier - Load provider-based tables into PF
# Loads all tables from output/tables/ directory

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
APPNAME="apply-blocklist"

# RFC 5424 syslog-style logging
log() {
    local level="$1"
    shift
    printf "%s %s %s: %s\n" "$(date +%Y-%m-%dT%H:%M:%S)" "$level" "$APPNAME" "$*"
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

# Load configuration
if [ ! -f "$ENV_FILE" ]; then
    log_error "$ENV_FILE not found"
    exit 1
fi

set -a
. "$ENV_FILE"
set +a

# Files
TABLES_DIR="$SCRIPT_DIR/output/tables"
PF_CONF="${PF_OUTPUT_FILE:-/etc/pf.conf}"

# Flags
DRY_RUN=0
FORCE=0
PURGE=0

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --force)
            FORCE=1
            shift
            ;;
        --purge)
            PURGE=1
            shift
            ;;
        *)
            echo "Usage: $0 [--dry-run] [--force] [--purge]"
            echo ""
            echo "Options:"
            echo "  --dry-run     Show what would be loaded without applying"
            echo "  --force       Force reload all tables"
            echo "  --purge       Remove all provider tables from PF"
            exit 1
            ;;
    esac
done

log_info "Starting PF table management"

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root (use doas)"
    exit 1
fi

# Purge mode - flush all provider tables
if [ $PURGE -eq 1 ]; then
    log_info "Purge mode: removing all provider tables from PF"

    purged=0
    failed=0

    # Get all active provider tables
    ACTIVE_TABLES=$(pfctl -sTables 2>/dev/null | grep -E "^(threat_|monitor_|sec_|crawler_)")

    if [ -z "$ACTIVE_TABLES" ]; then
        log_info "No provider tables found in PF"
        exit 0
    fi

    table_count=$(echo "$ACTIVE_TABLES" | wc -l | tr -d ' ')
    log_info "Found $table_count provider tables to purge"

    echo "$ACTIVE_TABLES" | while read -r table_name; do
        if pfctl -t "$table_name" -T flush >/dev/null 2>&1; then
            log_info "Flushed table: $table_name"
            purged=$((purged + 1))
        else
            log_error "Failed to flush table: $table_name"
            failed=$((failed + 1))
        fi
    done

    log_info "Purge complete"
    log_info "Tables flushed: $table_count"
    exit 0
fi

# Check tables directory exists
if [ ! -d "$TABLES_DIR" ]; then
    log_error "Tables directory not found: $TABLES_DIR"
    log_error "Run ./update-blocklist.sh first to generate tables"
    exit 1
fi

# Count available tables
TABLE_COUNT=$(find "$TABLES_DIR" -name "*.txt" -type f | wc -l | tr -d ' ')

if [ "$TABLE_COUNT" -eq 0 ]; then
    log_error "No table files found in $TABLES_DIR"
    log_error "Run ./update-blocklist.sh to generate tables"
    exit 1
fi

log_info "Found $TABLE_COUNT tables to load"

# Dry run mode
if [ $DRY_RUN -eq 1 ]; then
    log_info "Dry-run mode: showing tables without loading"
    echo ""
    printf "%-40s %10s\n" "Table Name" "Entries"
    printf "%-40s %10s\n" "----------" "-------"

    find "$TABLES_DIR" -name "*.txt" -type f | sort | while read -r file; do
        table_name=$(basename "$file" .txt)
        entry_count=$(wc -l < "$file" | tr -d ' ')
        printf "%-40s %10d\n" "$table_name" "$entry_count"
    done

    echo ""
    log_info "Total tables: $TABLE_COUNT"
    exit 0
fi

# Load each table
log_info "Loading tables into PF"

# Collect table files first to avoid subshell variable issue
TABLE_FILES=$(find "$TABLES_DIR" -name "*.txt" -type f | sort)

loaded=0
failed=0
total_entries=0

for file in $TABLE_FILES; do
    table_name=$(basename "$file" .txt)
    entry_count=$(wc -l < "$file" | tr -d ' ')

    # Skip empty tables
    if [ "$entry_count" -eq 0 ]; then
        log_warn "Skipping empty table: $table_name"
        continue
    fi

    # Load table into PF
    if pfctl -t "$table_name" -T replace -f "$file" >/dev/null 2>&1; then
        log_info "Loaded $table_name: $entry_count entries"
        loaded=$((loaded + 1))
        total_entries=$((total_entries + entry_count))
    else
        log_error "Failed to load table: $table_name"
        failed=$((failed + 1))
    fi
done

# Summary
log_info "Table loading complete"
log_info "Loaded: $loaded tables"
log_info "Failed: $failed tables"
log_info "Total entries: $total_entries"

if [ $failed -gt 0 ]; then
    log_warn "Some tables failed to load - check PF config"
    exit 1
fi

log_info "All tables loaded successfully"
