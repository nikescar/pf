#!/bin/sh
# PF Blocklist Updater - Run as root
# Downloads threat IPs from Firehol and other sources

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BLOCKLIST_FILE="$SCRIPT_DIR/blocklist"
TEMP_FILE="$SCRIPT_DIR/blocklist.tmp"
BACKUP_FILE="$SCRIPT_DIR/blocklist.$(date +%Y%m%d)"
PF_CONF="/etc/pf.conf"

echo "[$(date)] Starting blocklist update..."

# Backup existing blocklist
if [ -f "$BLOCKLIST_FILE" ]; then
    cp "$BLOCKLIST_FILE" "$BACKUP_FILE"
    echo "Backed up to $BACKUP_FILE"
fi

# Download threat feeds
echo "Downloading threat feeds..."
curl -sq \
    "https://pgl.yoyo.org/adservers/iplist.php?ipformat=&showintro=0&mimetype=plaintext" \
    "https://www.binarydefense.com/banlist.txt" \
    "https://rules.emergingthreats.net/blockrules/compromised-ips.txt" \
    "https://rules.emergingthreats.net/fwrules/emerging-Block-IPs.txt" \
    "https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level1.netset" \
    "https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level2.netset" \
    "https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level3.netset" | \
grep -Ev "^192\.168\.|^10\.|^172\.16\.|^127\.0\.0\.0|^0\.0\.0\.0|^#|#$" | \
grep -E "^[0-9]" | \
sort -u > "$TEMP_FILE"

# Validate non-empty
TOTAL_IPS=$(wc -l < "$TEMP_FILE" | tr -d ' ')

if [ "$TOTAL_IPS" -eq 0 ]; then
    echo "ERROR: Empty blocklist. Aborting."
    rm -f "$TEMP_FILE"
    exit 1
fi

echo "Downloaded $TOTAL_IPS unique threat IPs"

# Deploy
mv "$TEMP_FILE" "$BLOCKLIST_FILE"
echo "Deployed to $BLOCKLIST_FILE"

# Validate PF config
echo "Validating PF config..."
VALIDATION_OUTPUT=$(pfctl -nvf "$PF_CONF" 2>&1)
if echo "$VALIDATION_OUTPUT" | grep -q "syntax error"; then
    echo "ERROR: PF config has syntax errors. Restoring backup."
    echo "$VALIDATION_OUTPUT" | grep "syntax error"
    mv "$BACKUP_FILE" "$BLOCKLIST_FILE"
    exit 1
fi

# Reload PF rules
echo "Reloading PF rules..."
pfctl -f "$PF_CONF"

# Verify table loaded
ACTIVE_RULES=$(pfctl -t blacklist -T show 2>/dev/null | wc -l | tr -d ' ')
echo "PF reload complete. Blocking $ACTIVE_RULES IPs."

# Cleanup old backups (keep last 5)
ls -t "$SCRIPT_DIR"/blocklist.2* 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true

echo "[$(date)] Blocklist update complete."
