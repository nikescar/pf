#!/bin/sh
# Generate /etc/pf.conf based on .env configuration
# Usage: ./gen-pf-conf.sh [--check-only]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$SCRIPT_DIR/pf.conf.template"
ENV_FILE="$SCRIPT_DIR/.env"

# Load .env configuration
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: $ENV_FILE not found. Copy .env.example to .env"
    exit 1
fi

# Export variables from .env (ignore comments and empty lines)
set -a
. "$ENV_FILE"
set +a

# Use PF_OUTPUT_FILE from .env, default to /etc/pf.conf if not set
OUTPUT="${PF_OUTPUT_FILE:-/etc/pf.conf}"
BACKUP="${OUTPUT}.bak.$(date +%Y%m%d-%H%M%S)"

echo "=== PF Config Generator ==="
echo ""

# Display configuration
echo "Configuration:"
echo "  Output file: $OUTPUT"
echo "  ISP interface: $PF_ISP_INTERFACE"
echo "  LAN interface: $PF_LAN_INTERFACE"
echo "  LAN enabled: $PF_LAN_ENABLED"
echo ""

# Check-only mode
if [ "$1" = "--check-only" ]; then
    echo "Check-only mode. Configuration loaded successfully."
    exit 0
fi

# Determine mode
if [ "$PF_LAN_ENABLED" -eq 1 ]; then
    MODE="WITH_LAN"
    echo "Mode: Router (ISP + LAN)"
else
    MODE="NO_LAN"
    echo "Mode: Single interface (ISP only)"
fi

echo ""

# Backup existing config
if [ -f "$OUTPUT" ]; then
    echo "Backing up: $BACKUP"
    cp "$OUTPUT" "$BACKUP"
fi

# Generate config
echo "Generating /etc/pf.conf..."

# Start with template
TMP_FILE=$(mktemp)
cp "$TEMPLATE" "$TMP_FILE"

# Replace interface placeholders
sed -i "s|PF_ISP_INTERFACE|$PF_ISP_INTERFACE|g" "$TMP_FILE"
sed -i "s|PF_LAN_INTERFACE|$PF_LAN_INTERFACE|g" "$TMP_FILE"
sed -i "s|SCRIPT_DIR|$SCRIPT_DIR|g" "$TMP_FILE"

# Replace security rule placeholders
sed -i "s|PF_MAX_MSS|${PF_MAX_MSS:-1440}|g" "$TMP_FILE"
sed -i "s|PF_CONNLIMIT_PER_IP|${PF_CONNLIMIT_PER_IP:-100}|g" "$TMP_FILE"
sed -i "s|PF_UDP_RATE_LIMIT|${PF_UDP_RATE_LIMIT:-256}|g" "$TMP_FILE"
sed -i "s|PF_SCANNER_CONN_RATE|${PF_SCANNER_CONN_RATE:-15}|g" "$TMP_FILE"

# Remove LAN sections if disabled
if [ "$MODE" = "NO_LAN" ]; then
    sed -i '/^### LAN_START ###/,/^### LAN_END ###/d' "$TMP_FILE"
    # Uncomment NO_LAN sections if they exist
    sed -i '/^### NO_LAN_START ###/d' "$TMP_FILE"
    sed -i '/^### NO_LAN_END ###/d' "$TMP_FILE"
    sed -i 's/^#\(antispoof quick for { lo }\)/\1/' "$TMP_FILE"
    sed -i 's/^#\(pass out on \$isp proto { tcp udp icmp }\)/\1/' "$TMP_FILE"
else
    # Remove NO_LAN sections
    sed -i '/^### NO_LAN_START ###/,/^### NO_LAN_END ###/d' "$TMP_FILE"
    # Remove LAN markers
    sed -i '/^### LAN_START ###/d' "$TMP_FILE"
    sed -i '/^### LAN_END ###/d' "$TMP_FILE"
fi

# Remove disabled security sections
[ "${PF_LIMIT_MSS:-0}" -eq 0 ] && \
    sed -i '/^### SEC_MSS_START ###/,/^### SEC_MSS_END ###/d' "$TMP_FILE"

[ "${PF_DROP_INVALID_STATE:-0}" -eq 0 ] && \
    sed -i '/^### SEC_STATE_START ###/,/^### SEC_STATE_END ###/d' "$TMP_FILE"

[ "${PF_DROP_NON_SYN:-0}" -eq 0 ] && \
    sed -i '/^### SEC_NONSYN_START ###/,/^### SEC_NONSYN_END ###/d' "$TMP_FILE"

[ "${PF_CONNLIMIT_PER_IP:-0}" -eq 0 ] && \
    sed -i '/^### SEC_CONNLIMIT_START ###/,/^### SEC_CONNLIMIT_END ###/d' "$TMP_FILE"

[ "${PF_GUARD_UDP_FLOOD:-0}" -eq 0 ] && \
    sed -i '/^### SEC_UDP_FLOOD_START ###/,/^### SEC_UDP_FLOOD_END ###/d' "$TMP_FILE"

[ "${PF_GUARD_PORT_SCANNER:-0}" -eq 0 ] && \
    sed -i '/^### SEC_SCANNER_START ###/,/^### SEC_SCANNER_END ###/d' "$TMP_FILE"

# Remove all remaining security markers
sed -i '/^### SEC_.*_START ###/d' "$TMP_FILE"
sed -i '/^### SEC_.*_END ###/d' "$TMP_FILE"

# Write output
mv "$TMP_FILE" "$OUTPUT"

# Validate
echo ""
echo "Validating..."
if pfctl -nvf "$OUTPUT" 2>&1 | grep -q "syntax error"; then
    echo "✗ Syntax error - restoring backup"
    pfctl -nvf "$OUTPUT" 2>&1 | grep "syntax error"
    [ -f "$BACKUP" ] && mv "$BACKUP" "$OUTPUT"
    exit 1
else
    echo "✓ Valid"
fi

echo ""
echo "=== Generated: $OUTPUT ==="
echo ""
echo "Security rules enabled:"
[ "${PF_LIMIT_MSS:-0}" -ne 0 ] && echo "  ✓ MSS limiting (max: ${PF_MAX_MSS})"
[ "${PF_DROP_INVALID_STATE:-0}" -ne 0 ] && echo "  ✓ Invalid state filtering"
[ "${PF_DROP_NON_SYN:-0}" -ne 0 ] && echo "  ✓ Non-SYN filtering"
[ "${PF_CONNLIMIT_PER_IP:-0}" -ne 0 ] && echo "  ✓ Connection limiting (${PF_CONNLIMIT_PER_IP}/IP)"
[ "${PF_GUARD_UDP_FLOOD:-0}" -ne 0 ] && echo "  ✓ UDP flood protection (${PF_UDP_RATE_LIMIT}/sec)"
[ "${PF_GUARD_PORT_SCANNER:-0}" -ne 0 ] && echo "  ✓ Port scanner detection (${PF_SCANNER_CONN_RATE}/sec)"
echo ""
echo "Apply: pfctl -f $OUTPUT"
echo "Verify: pfctl -sr | head -20"
