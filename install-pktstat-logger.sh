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

cat > "$LOGGER_SCRIPT" <<'LOGGER_EOF'
#!/bin/ksh
# pktstat-logger.sh - Continuous network monitoring with daily log rotation

# Set PATH for cron environment
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/.local/bin
export PATH

# Find .env file in portable locations
for ENV_CANDIDATE in \
    "$(dirname "$0")/.env" \
    "$HOME/.config/pf/.env" \
    "/etc/pf/.env"; do
    if [ -f "$ENV_CANDIDATE" ]; then
        ENV_FILE="$ENV_CANDIDATE"
        break
    fi
done

if [ -z "$ENV_FILE" ] || [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: Could not find .env file in expected locations" >&2
    exit 1
fi

# Load environment
set -a
. "$ENV_FILE"
set +a

# Determine interface based on LAN mode
if [ "${PF_LAN_ENABLED:-0}" = "1" ]; then
    MONITOR_INTERFACE="${PF_LAN_INTERFACE}"
    if [ -z "$MONITOR_INTERFACE" ]; then
        echo "Error: PF_LAN_ENABLED=1 but PF_LAN_INTERFACE not set in .env" >&2
        exit 1
    fi
else
    MONITOR_INTERFACE="${PF_ISP_INTERFACE}"
    if [ -z "$MONITOR_INTERFACE" ]; then
        echo "Error: PF_ISP_INTERFACE not set in .env" >&2
        exit 1
    fi
fi

LOG_DIR="/var/log/pktstat"
CURRENT_DATE=$(date +%Y-%m-%d)
LOG_FILE="$LOG_DIR/pktstat-$CURRENT_DATE.log"

# CDN cache file for persistence across restarts
CDN_CACHE="/tmp/pktstat-cdn-cache.txt"
touch "$CDN_CACHE"

# Function: Check if IP is internal (RFC1918, loopback, multicast)
is_internal_ip() {
    local ip="$1"
    case "$ip" in
        10.*|127.*|169.254.*) return 0 ;;
        192.168.*) return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
        22[4-9].*|23[0-9].*) return 0 ;;  # Multicast
        0.0.0.0|255.255.255.255) return 0 ;;
    esac
    return 1
}

# Function: Lookup CDN name for IP (with caching)
lookup_cdn_name() {
    local ip="$1"

    # Check cache file (skip corrupted entries)
    local cached=$(grep "^$ip " "$CDN_CACHE" 2>/dev/null | cut -d' ' -f2-)
    if [ -n "$cached" ]; then
        # Validate cache entry isn't corrupted (starts with { or is an IP)
        if echo "$cached" | grep -qE "^{.*}$|^[0-9]+\.[0-9]+"; then
            echo "$cached"
            return
        fi
        # Corrupted cache, fall through to re-lookup
    fi

    # Call cdn-lookup and filter only the result line (ignore download messages)
    local result=$(cdn-lookup "$ip" 2>/dev/null | grep "^$ip:")

    # Check if we got a result
    if [ -z "$result" ]; then
        echo "$ip $ip" >> "$CDN_CACHE"
        echo "$ip"
        return
    fi

    # Parse result: "IP: Found in service1, service2" or "IP: -"
    if echo "$result" | grep -q "Found in "; then
        local services=$(echo "$result" | sed 's/.*Found in //')
        local output="{${services}}"
        echo "$ip $output" >> "$CDN_CACHE"
        echo "$output"
    else
        echo "$ip $ip" >> "$CDN_CACHE"
        echo "$ip"
    fi
}

# Function: Process pktstat line and replace external IPs with CDN names
process_pktstat_line() {
    local timestamp="$1"
    shift
    local bytes="$1"
    local packets="$2"
    local proto="$3"
    local left="$4"
    local arrow="$5"
    local right="$6"

    # Extract IP:port pairs
    local ip1="${left%:*}"
    local port1="${left##*:}"
    local ip2="${right%:*}"
    local port2="${right##*:}"

    # Replace external IPs
    local output1 output2
    if is_internal_ip "$ip1"; then
        output1="$ip1:$port1"
    else
        output1="$(lookup_cdn_name "$ip1"):$port1"
    fi

    if is_internal_ip "$ip2"; then
        output2="$ip2:$port2"
    else
        output2="$(lookup_cdn_name "$ip2"):$port2"
    fi

    echo "$timestamp $bytes $packets $proto $output1 <-> $output2"
}

# Function: Cleanup old logs (keep 7 days)
cleanup_old_logs() {
    find "$LOG_DIR" -name "pktstat-*.log" -mtime +7 -delete 2>/dev/null || true
}

# Function: Run pktstat and process output
run_pktstat() {
    pktstat -i "$MONITOR_INTERFACE" -F -1 -w 5 -T -n "not (ip proto 89 or ip proto 1 or ip proto 2 or ip proto 103)" 2>/dev/null | \
    while read -r bytes packets proto left arrow right rest; do
        # Skip lines without proper format
        [ -z "$right" ] && continue
        [ "$arrow" != "<->" ] && continue

        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        process_pktstat_line "$timestamp" "$bytes" "$packets" "$proto" "$left" "$arrow" "$right"
    done
}

# Main execution
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Logger script starting..."
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Interface: $MONITOR_INTERFACE"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Log file: $LOG_FILE"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] CDN cache: $CDN_CACHE"

cleanup_old_logs
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cleanup complete"

# Test if we can write to log file
if ! touch "$LOG_FILE" 2>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Cannot write to $LOG_FILE" >&2
    exit 1
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Log file writable"

# Test if interface exists
if ! ifconfig "$MONITOR_INTERFACE" >/dev/null 2>&1; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Interface $MONITOR_INTERFACE not found" >&2
    exit 1
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Interface exists"

# Test if pktstat is available
if ! command -v pktstat >/dev/null 2>&1; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: pktstat command not found" >&2
    exit 1
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S')] pktstat found"

# Test if cdn-lookup is available
if ! command -v cdn-lookup >/dev/null 2>&1; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: cdn-lookup not found, IPs will not be translated" >&2
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting main loop..."

# Main logging loop
while true; do
    # Check if date changed (for rotation)
    NEW_DATE=$(date +%Y-%m-%d)
    if [ "$NEW_DATE" != "$CURRENT_DATE" ]; then
        CURRENT_DATE="$NEW_DATE"
        LOG_FILE="$LOG_DIR/pktstat-$CURRENT_DATE.log"
        echo "Rotated to new log: $LOG_FILE"
        cleanup_old_logs
    fi

    # Run pktstat with processing
    run_pktstat >> "$LOG_FILE" || {
        echo "pktstat failed, retrying in 5 seconds..."
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
log_info "Killing existing logger processes..."
pkill -f "^/usr/local/bin/pktstat-logger.sh" 2>/dev/null || log_info "No existing logger to kill"
log_info "pkill completed"
sleep 1

# Test logger script syntax
log_info "Testing logger script syntax..."
if ! sh -n "$LOGGER_SCRIPT" 2>&1; then
    log_error "Logger script has syntax errors"
    exit 1
fi
log_info "Syntax check passed"

# Create temp file for startup errors
STARTUP_LOG="/tmp/pktstat-logger-startup.log"
rm -f "$STARTUP_LOG"

log_info "Starting logger script: $LOGGER_SCRIPT"
log_info "Startup log: $STARTUP_LOG"

# Start in background with error capture
nohup "$LOGGER_SCRIPT" >"$STARTUP_LOG" 2>&1 &
LOGGER_PID=$!
log_info "Started background process, PID: $LOGGER_PID"

# Wait and check if it's still running
sleep 2
if ps -p "$LOGGER_PID" >/dev/null 2>&1; then
    log_info "Logger process is running (PID: $LOGGER_PID)"
else
    log_error "Logger process died immediately (PID: $LOGGER_PID)"
    log_error "Startup log contents:"
    cat "$STARTUP_LOG" >&2
    exit 1
fi

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
log_info "  Stop logger:   pkill -f ^/usr/local/bin/pktstat-logger.sh"
log_info "  Restart:       $LOGGER_SCRIPT &"
log_info ""
log_info "Logs are retained for 7 days and rotated daily"
log_info "Using .env from: $ENV_FILE"
