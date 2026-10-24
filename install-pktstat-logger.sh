#!/bin/sh
# install-pktstat-logger.sh
# Installs pktstat-based IP connection logger with daily rotation and 7-day retention

set -e

APPNAME="install-pktstat-logger"

# RFC 5424 syslog-style logging
log() {
    local level="$1"
    shift
    printf "%s %s %s: %s\n" "$(date +%Y-%m-%dT%H:%M:%S)" "$level" "$APPNAME" "$*"
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

log_info "Starting pktstat logger installation"

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root"
    exit 1
fi

# Load environment variables from script's directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
    log_warn ".env not found at $ENV_FILE"
    log_error "Please create .env with interfaces configured"
    exit 1
fi

# Source .env
set -a
. "$ENV_FILE"
set +a

# Determine interface based on LAN mode
if [ "${PF_LAN_ENABLED:-0}" = "1" ]; then
    MONITOR_INTERFACE="${PF_LAN_INTERFACE}"
    if [ -z "$MONITOR_INTERFACE" ]; then
        log_error "PF_LAN_ENABLED=1 but PF_LAN_INTERFACE not set in .env"
        exit 1
    fi
    log_info "LAN mode enabled, using interface: $MONITOR_INTERFACE"
else
    MONITOR_INTERFACE="${PF_ISP_INTERFACE}"
    if [ -z "$MONITOR_INTERFACE" ]; then
        log_error "PF_ISP_INTERFACE not set in .env"
        exit 1
    fi
    log_info "Using ISP interface: $MONITOR_INTERFACE"
fi

# Step 1: Check and install pktstat
log_info "Step 1/6: Checking pktstat"
if ! command -v pktstat >/dev/null 2>&1; then
    log_info "pktstat not found. Installing"
    pkg_add pktstat || {
        log_error "Failed to install pktstat"
        exit 1
    }
else
    log_info "pktstat already installed"
fi

# Step 2: Create log directory
LOG_DIR="/var/log/pktstat"
log_info "Step 2/6: Creating log directory"
mkdir -p "$LOG_DIR"
chmod 755 "$LOG_DIR"
log_info "Created $LOG_DIR"

# Step 3: Install logger script
LOGGER_SCRIPT="/usr/local/bin/pktstat-logger.sh"
log_info "Step 3/6: Installing logger script"

cat > "$LOGGER_SCRIPT" <<LOGGER_EOF
#!/bin/sh
# pktstat-logger.sh - Continuous network monitoring with daily log rotation

# Set PATH for cron environment
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH

# Load environment
ENV_FILE="$ENV_FILE"
if [ -f "\$ENV_FILE" ]; then
    set -a
    . "\$ENV_FILE"
    set +a
fi

# Determine interface based on LAN mode
if [ "\${PF_LAN_ENABLED:-0}" = "1" ]; then
    MONITOR_INTERFACE="\${PF_LAN_INTERFACE}"
    if [ -z "\$MONITOR_INTERFACE" ]; then
        echo "Error: PF_LAN_ENABLED=1 but PF_LAN_INTERFACE not set in .env" >&2
        exit 1
    fi
else
    MONITOR_INTERFACE="\${PF_ISP_INTERFACE}"
    if [ -z "\$MONITOR_INTERFACE" ]; then
        echo "Error: PF_ISP_INTERFACE not set in .env" >&2
        exit 1
    fi
fi

LOG_DIR="/var/log/pktstat"
CURRENT_DATE=\$(date +%Y-%m-%d)
LOG_FILE="\$LOG_DIR/pktstat-\$CURRENT_DATE.log"

# Cleanup old logs (keep 7 days)
cleanup_old_logs() {
    find "\$LOG_DIR" -name "pktstat-*.log" -mtime +7 -delete 2>/dev/null || true
}

# Run cleanup on start
cleanup_old_logs

echo "Starting pktstat logger on interface \$MONITOR_INTERFACE"
echo "Logging to: \$LOG_FILE"

# Main logging loop
while true; do
    # Check if date changed (for rotation)
    NEW_DATE=\$(date +%Y-%m-%d)
    if [ "\$NEW_DATE" != "\$CURRENT_DATE" ]; then
        CURRENT_DATE="\$NEW_DATE"
        LOG_FILE="\$LOG_DIR/pktstat-\$CURRENT_DATE.log"
        echo "Rotated to new log: \$LOG_FILE"
        cleanup_old_logs
    fi

    # Run pktstat with timestamp
    pktstat -i "\$MONITOR_INTERFACE" -F -1 -w 5 -T -n "not (ip proto 89 or ip proto 1 or ip proto 2 or ip proto 103)" 2>/dev/null | \
        awk -v d="\$(date '+%Y-%m-%d %H:%M:%S')" 'NF > 2 {print d, \$0}' >> "\$LOG_FILE" || {
        # If pktstat fails, wait and retry
        sleep 5
    }
done
LOGGER_EOF

chmod +x "$LOGGER_SCRIPT"
log_info "Installed $LOGGER_SCRIPT"

# Step 4: Add cron entry
log_info "Step 4/6: Configuring cron"
CRON_ENTRY="@reboot /usr/local/bin/pktstat-logger.sh >/dev/null 2>&1 &"

# Check if entry already exists
if crontab -l 2>/dev/null | grep -q "pktstat-logger.sh"; then
    log_info "Cron entry already exists"
else
    # Add to crontab
    (crontab -l 2>/dev/null || true; echo "$CRON_ENTRY") | crontab -
    log_info "Added cron entry: $CRON_ENTRY"
fi

# Step 5: Start logger
log_info "Step 5/6: Starting logger"

# Kill existing logger if running
pkill -f "pktstat-logger.sh" 2>/dev/null || true
sleep 1

# Start in background
nohup "$LOGGER_SCRIPT" >/dev/null 2>&1 &
LOGGER_PID=$!
sleep 2

log_info "Logger started with PID: $LOGGER_PID"

# Step 6: Verify installation
log_info "Step 6/6: Verifying installation"

# Check if process is running
if ps -p "$LOGGER_PID" >/dev/null 2>&1; then
    log_info "Logger process is running (PID: $LOGGER_PID)"
else
    log_warn "Logger process check inconclusive"
fi

# Check if log file exists
sleep 3
CURRENT_LOG="$LOG_DIR/pktstat-$(date +%Y-%m-%d).log"
if [ -f "$CURRENT_LOG" ]; then
    LOG_SIZE=$(wc -c < "$CURRENT_LOG")
    log_info "Log file created: $CURRENT_LOG (${LOG_SIZE} bytes)"
    log_info "Sample output:"
    tail -3 "$CURRENT_LOG" 2>/dev/null || log_info "(waiting for data...)"
else
    log_warn "Log file not yet created (may take a few seconds)"
fi

# Check cron
if crontab -l 2>/dev/null | grep -q "pktstat-logger.sh"; then
    log_info "Cron entry configured (@reboot)"
else
    log_error "Cron entry not found"
fi

log_info "Installation complete"
log_info ""
log_info "Useful commands:"
log_info "  View logs:     tail -f $LOG_DIR/pktstat-\$(date +%Y-%m-%d).log"
log_info "  List logs:     ls -lh $LOG_DIR/"
log_info "  Check process: ps aux | grep pktstat-logger"
log_info "  Stop logger:   pkill -f pktstat-logger.sh"
log_info "  Restart:       $LOGGER_SCRIPT &"
log_info ""
log_info "Logs are retained for 7 days and rotated daily"
log_info "Using .env from: $ENV_FILE"
