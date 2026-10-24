#!/bin/sh
# PF Blocklist Applier - Download pre-generated blocklist from GitHub
# GitHub CI updates blocklist weekly, this script downloads and applies

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
BLOCKLIST_FILE="$SCRIPT_DIR/blocklist"
BLOCKLIST_INFO="$SCRIPT_DIR/blocklist.info.txt"
BACKUP_FILE="$SCRIPT_DIR/blocklist.bak"
BACKUP_INFO="$SCRIPT_DIR/blocklist.info.txt.bak"
PF_CONF="${PF_OUTPUT_FILE:-/etc/pf.conf}"

# Temp files
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Flags
CHECK_ONLY=0
DRY_RUN=0
FORCE=0
LOCAL_ONLY=0

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --check-only)
            CHECK_ONLY=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --force)
            FORCE=1
            shift
            ;;
        --local-only)
            LOCAL_ONLY=1
            shift
            ;;
        *)
            echo "Usage: $0 [--check-only] [--dry-run] [--force] [--local-only]"
            echo ""
            echo "Options:"
            echo "  --check-only  Download but don't reload PF"
            echo "  --dry-run     Show what would change without downloading"
            echo "  --force       Force download even if unchanged"
            echo "  --local-only  Skip download, load existing local blocklist"
            exit 1
            ;;
    esac
done

log_info "Starting PF blocklist application"

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root (use doas)"
    exit 1
fi

# Skip download if --local-only
if [ $LOCAL_ONLY -eq 0 ]; then
    # Check if repo URL is configured
    if [ -z "$PF_BLOCKLIST_REPO_URL" ] || [ "$PF_BLOCKLIST_REPO_URL" = "https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main" ]; then
        log_error "PF_BLOCKLIST_REPO_URL not configured in .env"
        log_error "Set it to: https://raw.githubusercontent.com/USER/REPO/BRANCH"
        exit 1
    fi

    # Construct download URLs
    BLOCKLIST_URL="${PF_BLOCKLIST_REPO_URL}/blocklist"
    BLOCKLIST_INFO_URL="${PF_BLOCKLIST_REPO_URL}/blocklist.info.txt"

    # Download remote blocklist
    log_info "Downloading blocklist from GitHub"
    if ! curl -fsSL "$BLOCKLIST_URL" -o "$TEMP_DIR/blocklist.remote" 2>/dev/null; then
        log_error "Failed to download blocklist from $BLOCKLIST_URL"
        log_error "Check PF_BLOCKLIST_REPO_URL in .env"
        exit 1
    fi

    # Download remote info file (optional)
    curl -fsSL "$BLOCKLIST_INFO_URL" -o "$TEMP_DIR/blocklist.info.txt.remote" 2>/dev/null || true

    # Get checksums
    REMOTE_HASH=$(cksum "$TEMP_DIR/blocklist.remote" | awk '{print $1}')
    LOCAL_HASH=""
    if [ -f "$BLOCKLIST_FILE" ]; then
        LOCAL_HASH=$(cksum "$BLOCKLIST_FILE" | awk '{print $1}')
    fi
else
    # Local-only mode: use existing blocklist
    log_info "Local-only mode: using existing blocklist"
    if [ ! -f "$BLOCKLIST_FILE" ]; then
        log_error "Blocklist file not found: $BLOCKLIST_FILE"
        exit 1
    fi
    # Set hashes to force reload
    REMOTE_HASH="local"
    LOCAL_HASH="force"
fi

# Dry run mode
if [ $DRY_RUN -eq 1 ]; then
    log_info "Comparing local and remote blocklists"
    if [ "$LOCAL_HASH" = "$REMOTE_HASH" ]; then
        log_info "No changes - blocklist is up to date"
    else
        log_info "Changes detected"
        LOCAL_COUNT=0
        if [ -f "$BLOCKLIST_FILE" ]; then
            LOCAL_COUNT=$(wc -l < "$BLOCKLIST_FILE" | tr -d ' ')
        fi
        REMOTE_COUNT=$(wc -l < "$TEMP_DIR/blocklist.remote" | tr -d ' ')
        log_info "Local entries: $LOCAL_COUNT"
        log_info "Remote entries: $REMOTE_COUNT"
        log_info "Difference: $(($REMOTE_COUNT - $LOCAL_COUNT))"

        # Show sample of changes
        if [ -f "$BLOCKLIST_FILE" ]; then
            log_info "Sample changes (first 10):"
            diff "$BLOCKLIST_FILE" "$TEMP_DIR/blocklist.remote" | grep '^[<>]' | head -10 || true
        fi
    fi
    exit 0
fi

# Check if changed
if [ "$LOCAL_HASH" = "$REMOTE_HASH" ] && [ $FORCE -eq 0 ]; then
    log_info "Blocklist is up to date (no changes)"
    exit 0
fi

# Blocklist changed or forced
if [ $LOCAL_ONLY -eq 1 ]; then
    log_info "Using local blocklist"
elif [ $FORCE -eq 1 ]; then
    log_info "Force update requested"
else
    log_info "Blocklist has updates"
fi

# Download mode: backup and install
if [ $LOCAL_ONLY -eq 0 ]; then
    # Backup current blocklist
    if [ -f "$BLOCKLIST_FILE" ]; then
        log_info "Backing up current blocklist to: $BACKUP_FILE"
        cp "$BLOCKLIST_FILE" "$BACKUP_FILE"
    fi

    # Backup current info file
    if [ -f "$BLOCKLIST_INFO" ]; then
        cp "$BLOCKLIST_INFO" "$BACKUP_INFO"
    fi

    # Install new blocklist
    mv "$TEMP_DIR/blocklist.remote" "$BLOCKLIST_FILE"
    if [ -f "$TEMP_DIR/blocklist.info.txt.remote" ]; then
        mv "$TEMP_DIR/blocklist.info.txt.remote" "$BLOCKLIST_INFO"
    fi
fi

# Show summary
ENTRY_COUNT=$(wc -l < "$BLOCKLIST_FILE" | tr -d ' ')
log_info "Total entries: $ENTRY_COUNT"

if [ -f "$BLOCKLIST_INFO" ]; then
    log_info "Recent additions (from blocklist.info.txt):"
    head -5 "$BLOCKLIST_INFO" || true
fi

# Reload PF if not check-only mode
if [ $CHECK_ONLY -eq 1 ]; then
    log_info "Check-only mode: PF not reloaded"
    log_info "To apply: pfctl -f $PF_CONF && pfctl -t blocklist -T replace -f $BLOCKLIST_FILE"
    exit 0
fi

# Validate PF config before reloading
log_info "Validating PF configuration"
if ! pfctl -nvf "$PF_CONF" >/dev/null 2>&1; then
    log_error "PF config validation failed"
    pfctl -nvf "$PF_CONF" 2>&1
    log_info "Restoring backup"
    [ -f "$BACKUP_FILE" ] && mv "$BACKUP_FILE" "$BLOCKLIST_FILE"
    exit 1
fi

log_info "PF configuration valid"

# Reload PF rules
log_info "Reloading PF rules"
if pfctl -f "$PF_CONF" 2>&1; then
    log_info "PF rules reloaded successfully"
else
    log_error "Failed to reload PF rules"
    log_info "Restoring backup"
    [ -f "$BACKUP_FILE" ] && mv "$BACKUP_FILE" "$BLOCKLIST_FILE"
    exit 1
fi

# Ensure blocklist table exists before loading
log_info "Ensuring blocklist table exists"
if ! pfctl -t blocklist -T show >/dev/null 2>&1; then
    log_info "Creating blocklist table"
    pfctl -t blocklist -T add 2>/dev/null || true
fi

# Explicitly load blocklist table with chunked loading for large files
log_info "Loading blocklist table"
ENTRY_COUNT=$(wc -l < "$BLOCKLIST_FILE" | tr -d ' ')
log_info "Entries to load: $ENTRY_COUNT"

if [ "$ENTRY_COUNT" -gt 50000 ]; then
    log_info "Using chunked loading (large blocklist)"
    # Split into 10k chunks (memory-friendly)
    split -l 10000 "$BLOCKLIST_FILE" "$TEMP_DIR/chunk."

    # Flush existing table
    pfctl -t blocklist -T flush 2>/dev/null || true

    # Count total chunks
    TOTAL_CHUNKS=$(ls -1 "$TEMP_DIR"/chunk.* 2>/dev/null | wc -l | tr -d ' ')

    # Load each chunk
    CHUNK_NUM=0
    for chunk in "$TEMP_DIR"/chunk.*; do
        CHUNK_NUM=$((CHUNK_NUM + 1))
        CHUNK_SIZE=$(wc -l < "$chunk" | tr -d ' ')
        log_info "Loading chunk $CHUNK_NUM/$TOTAL_CHUNKS ($CHUNK_SIZE entries)"
        if ! pfctl -t blocklist -T add -f "$chunk" >/dev/null 2>&1; then
            log_error "Failed to load chunk $CHUNK_NUM"
            exit 1
        fi
    done
    log_info "Blocklist table loaded (chunked)"
else
    # Small blocklist, load directly
    if pfctl -t blocklist -T replace -f "$BLOCKLIST_FILE" 2>&1; then
        log_info "Blocklist table loaded"
    else
        log_error "Failed to load blocklist table"
        exit 1
    fi
fi

# Show blocklist table stats
log_info "Blocklist table status:"
BLOCKLIST_COUNT=$(pfctl -t blocklist -T show 2>/dev/null | wc -l | tr -d ' ')
log_info "Loaded entries: $BLOCKLIST_COUNT"

log_info "Blocklist applied successfully"
