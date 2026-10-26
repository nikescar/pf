#!/bin/sh
# Generate /etc/pf.conf based on .env configuration
# Usage: ./generate-pfconf.sh [--check-only]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$SCRIPT_DIR/pf.conf.template"
ENV_FILE="$SCRIPT_DIR/.env"
APPNAME="generate-pfconf"

# RFC 5424 syslog-style logging
log() {
    local level="$1"
    shift
    printf "%s %s %s: %s\n" "$(date +%Y-%m-%dT%H:%M:%S)" "$level" "$APPNAME" "$*"
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

# Load .env configuration
if [ ! -f "$ENV_FILE" ]; then
    log_error "$ENV_FILE not found. Copy .env.example to .env"
    exit 1
fi

# Export variables from .env (ignore comments and empty lines)
set -a
. "$ENV_FILE"
set +a

# Use PF_OUTPUT_FILE from .env, default to /etc/pf.conf if not set
OUTPUT="${PF_OUTPUT_FILE:-/etc/pf.conf}"
BACKUP="${OUTPUT}.bak"

log_info "Starting PF configuration generation"

# Display configuration
log_info "Output file: $OUTPUT"
log_info "ISP interface: $PF_ISP_INTERFACE"
log_info "LAN interface: $PF_LAN_INTERFACE"
log_info "LAN enabled: $PF_LAN_ENABLED"

# Check-only mode
if [ "$1" = "--check-only" ]; then
    log_info "Check-only mode. Configuration loaded successfully"
    exit 0
fi

# Determine mode
if [ "$PF_LAN_ENABLED" -eq 1 ]; then
    MODE="WITH_LAN"
    log_info "Mode: Router (ISP + LAN)"
else
    MODE="NO_LAN"
    log_info "Mode: Single interface (ISP only)"
fi

# Backup existing config
if [ -f "$OUTPUT" ]; then
    log_info "Backing up existing config to: $BACKUP"
    cp "$OUTPUT" "$BACKUP"
fi

# Generate config
log_info "Generating configuration from template"

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
log_info "Validating configuration syntax"
if pfctl -nvf "$OUTPUT" 2>&1 | grep -q "syntax error"; then
    log_error "Syntax validation failed - restoring backup"
    pfctl -nvf "$OUTPUT" 2>&1 | grep "syntax error"
    [ -f "$BACKUP" ] && mv "$BACKUP" "$OUTPUT"
    exit 1
else
    log_info "Configuration syntax valid"
fi

log_info "Generated configuration: $OUTPUT"

# Summary of enabled security rules
log_info "Security rules summary:"
[ "${PF_LIMIT_MSS:-0}" -ne 0 ] && log_info "  MSS limiting enabled (max: ${PF_MAX_MSS})"
[ "${PF_DROP_INVALID_STATE:-0}" -ne 0 ] && log_info "  Invalid state filtering enabled"
[ "${PF_DROP_NON_SYN:-0}" -ne 0 ] && log_info "  Non-SYN filtering enabled"
[ "${PF_CONNLIMIT_PER_IP:-0}" -ne 0 ] && log_info "  Connection limiting enabled (${PF_CONNLIMIT_PER_IP} per IP)"
[ "${PF_GUARD_UDP_FLOOD:-0}" -ne 0 ] && log_info "  UDP flood protection enabled (${PF_UDP_RATE_LIMIT} packets/sec)"
[ "${PF_GUARD_PORT_SCANNER:-0}" -ne 0 ] && log_info "  Port scanner detection enabled (${PF_SCANNER_CONN_RATE} connections/sec)"

# Auto-apply if running as root
if [ "$(id -u)" -eq 0 ]; then
    log_info "Applying configuration to PF"
    if pfctl -f "$OUTPUT" 2>&1; then
        log_info "Configuration applied successfully"
    else
        log_error "Failed to apply configuration"
        [ -f "$BACKUP" ] && mv "$BACKUP" "$OUTPUT"
        exit 1
    fi

    # Load provider tables if they exist
    if [ -d "$SCRIPT_DIR/output/tables" ] && [ -f "$SCRIPT_DIR/apply-blocklist.sh" ]; then
        TABLE_COUNT=$(find "$SCRIPT_DIR/output/tables" -name "*.txt" -type f 2>/dev/null | wc -l | tr -d ' ')
        if [ "$TABLE_COUNT" -gt 0 ]; then
            log_info "Loading $TABLE_COUNT provider tables"
            "$SCRIPT_DIR/apply-blocklist.sh"
        else
            log_warn "No provider tables found in output/tables/"
            log_info "Run ./update-blocklist.sh to generate tables"
        fi
    else
        log_warn "Provider tables not found"
        log_info "Run ./update-blocklist.sh to generate tables"
    fi
else
    log_warn "Not running as root - configuration generated but not applied"
    log_info "To apply manually:"
    log_info "  doas pfctl -f $OUTPUT"
    log_info "  doas $SCRIPT_DIR/apply-blocklist.sh"
fi

log_info "Configuration generation complete"
