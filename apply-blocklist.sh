#!/bin/sh
# PF Blocklist Applier - Pull pre-generated blocklist from git
# GitHub CI updates blocklist weekly, this script pulls and applies

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

# Load configuration
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: $ENV_FILE not found"
    exit 1
fi

set -a
. "$ENV_FILE"
set +a

# Files
BLOCKLIST_FILE="$SCRIPT_DIR/blocklist"
BLOCKLIST_INFO="$SCRIPT_DIR/blocklist.info.txt"
BACKUP_FILE="$SCRIPT_DIR/blocklist.$(date +%Y%m%d-%H%M%S)"
PF_CONF="${PF_OUTPUT_FILE:-/etc/pf.conf}"

# Flags
CHECK_ONLY=0
DRY_RUN=0

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
        *)
            echo "Usage: $0 [--check-only] [--dry-run]"
            echo ""
            echo "Options:"
            echo "  --check-only  Pull updates but don't reload PF"
            echo "  --dry-run     Show what would change without pulling"
            exit 1
            ;;
    esac
done

echo "=== PF Blocklist Applier ==="
echo ""

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use doas)"
    echo "Usage: doas $0"
    exit 1
fi

# Check git status
if [ ! -d "$SCRIPT_DIR/.git" ]; then
    echo "ERROR: Not a git repository"
    exit 1
fi

cd "$SCRIPT_DIR"

# Dry run: fetch and show diff
if [ $DRY_RUN -eq 1 ]; then
    echo "Fetching latest changes..."
    git fetch origin main 2>&1 | grep -v "^From" || true

    echo ""
    echo "Changes in blocklist:"
    if git diff --quiet HEAD origin/main -- blocklist blocklist.info.txt; then
        echo "  No changes"
    else
        echo ""
        git diff --stat HEAD origin/main -- blocklist blocklist.info.txt
        echo ""
        echo "Blocklist entries changed:"
        git diff HEAD origin/main -- blocklist | grep -E '^\+[0-9]|^-[0-9]' | head -10
        local total_changes=$(git diff HEAD origin/main -- blocklist | grep -E '^\+[0-9]|^-[0-9]' | wc -l | tr -d ' ')
        if [ "$total_changes" -gt 10 ]; then
            echo "  ... and $((total_changes - 10)) more"
        fi
    fi
    exit 0
fi

# Check for uncommitted changes
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "ERROR: Uncommitted changes in working directory"
    echo "Commit or stash changes before applying blocklist"
    git status --short
    exit 1
fi

# Backup current blocklist
if [ -f "$BLOCKLIST_FILE" ]; then
    echo "Backing up current blocklist: $BACKUP_FILE"
    cp "$BLOCKLIST_FILE" "$BACKUP_FILE"
fi

# Record blocklist hash before pull
BEFORE_HASH=""
if [ -f "$BLOCKLIST_FILE" ]; then
    BEFORE_HASH=$(cksum "$BLOCKLIST_FILE" | awk '{print $1}')
fi

# Pull latest changes
echo "Pulling latest blocklist from git..."
PULL_OUTPUT=$(git pull origin main 2>&1)

# Check if pull was successful
if [ $? -ne 0 ]; then
    echo "ERROR: git pull failed"
    echo "$PULL_OUTPUT"
    exit 1
fi

# Check if blocklist changed
AFTER_HASH=""
if [ -f "$BLOCKLIST_FILE" ]; then
    AFTER_HASH=$(cksum "$BLOCKLIST_FILE" | awk '{print $1}')
fi

if [ "$BEFORE_HASH" = "$AFTER_HASH" ]; then
    echo "✓ Blocklist is up to date (no changes)"
    exit 0
fi

# Blocklist changed
echo "✓ Blocklist updated"

# Show summary
if [ -f "$BLOCKLIST_FILE" ]; then
    ENTRY_COUNT=$(wc -l < "$BLOCKLIST_FILE" | tr -d ' ')
    echo "  Entries: $ENTRY_COUNT"
fi

if [ -f "$BLOCKLIST_INFO" ]; then
    echo ""
    echo "Recent additions (from blocklist.info.txt):"
    head -5 "$BLOCKLIST_INFO"
fi

# Reload PF if not check-only mode
if [ $CHECK_ONLY -eq 1 ]; then
    echo ""
    echo "✓ Check-only mode: PF not reloaded"
    echo "  To apply: pfctl -f $PF_CONF"
    exit 0
fi

# Validate PF config before reloading
echo ""
echo "Validating PF configuration..."
if ! pfctl -nvf "$PF_CONF" >/dev/null 2>&1; then
    echo "✗ PF config validation failed"
    pfctl -nvf "$PF_CONF" 2>&1
    echo ""
    echo "Restoring backup..."
    [ -f "$BACKUP_FILE" ] && mv "$BACKUP_FILE" "$BLOCKLIST_FILE"
    exit 1
fi

echo "✓ PF config valid"

# Reload PF rules
echo "Reloading PF rules..."
if pfctl -f "$PF_CONF" 2>&1; then
    echo "✓ PF rules reloaded successfully"
else
    echo "✗ Failed to reload PF rules"
    echo "Restoring backup..."
    [ -f "$BACKUP_FILE" ] && mv "$BACKUP_FILE" "$BLOCKLIST_FILE"
    exit 1
fi

# Explicitly load blocklist table
echo "Loading blocklist table..."
if pfctl -t blacklist -T replace -f "$BLOCKLIST_FILE" 2>&1; then
    echo "✓ Blocklist table loaded"

    # Show blacklist table stats
    echo ""
    echo "Blacklist table status:"
    BLACKLIST_COUNT=$(pfctl -t blacklist -T show 2>/dev/null | wc -l | tr -d ' ')
    echo "  Loaded entries: $BLACKLIST_COUNT"
else
    echo "✗ Failed to load blocklist table"
    exit 1
fi

echo ""
echo "=== Blocklist applied successfully ==="
