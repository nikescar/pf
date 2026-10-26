#!/bin/sh
# PF pktstat Logger Helper - Unified logger management
# Usage: pktstathelper.sh [--install|--uninstall|--status]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export APPNAME="pktstathelper"

# Source libraries
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/github.sh"

# Load environment
load_env "$SCRIPT_DIR/.env"

# Constants
LOG_DIR="/var/log/pktstat"
LOGGER_SCRIPT="/usr/local/bin/pktstat-logger.sh"
CRON_PATTERN="pktstat-logger.sh"

#
# Show usage
#
show_usage() {
    cat <<EOF
Usage: $0 [COMMAND]

Commands:
  --install    Install pktstat logger with cron @reboot and daily rotation
  --uninstall  Remove cron entry and stop logger process
  --status     Show installation status, running process, and log files

Examples:
  doas $0 --install      # Install and start logger
  $0 --status            # Check status
  doas $0 --uninstall    # Stop and uninstall

Environment:
  Configuration loaded from: $SCRIPT_DIR/.env
  Log directory: $LOG_DIR
  Logger script: $LOGGER_SCRIPT
EOF
}

#
# Command: --install (complete setup)
#
cmd_install() {
    require_root

    log_info "=== pktstat Logger Installation ==="

    # Determine interface based on LAN mode
    local monitor_interface
    if [ "${PF_LAN_ENABLED:-0}" = "1" ]; then
        monitor_interface="${PF_LAN_INTERFACE}"
        if [ -z "$monitor_interface" ]; then
            log_error "PF_LAN_ENABLED=1 but PF_LAN_INTERFACE not set in .env"
            exit 1
        fi
        log_info "LAN mode enabled, using interface: $monitor_interface"
    else
        monitor_interface="${PF_ISP_INTERFACE}"
        if [ -z "$monitor_interface" ]; then
            log_error "PF_ISP_INTERFACE not set in .env"
            exit 1
        fi
        log_info "Using ISP interface: $monitor_interface"
    fi

    # Step 1: Check and install pktstat
    log_info "Step 1/7: Checking pktstat"
    if ! command -v pktstat >/dev/null 2>&1; then
        log_info "Installing pktstat"
        pkg_add pktstat || {
            log_error "Failed to install pktstat"
            exit 1
        }
    else
        log_info "pktstat already installed"
    fi

    # Step 2: Check and install cdn-lookup
    log_info "Step 2/7: Checking cdn-lookup"
    if command -v cdn-lookup >/dev/null 2>&1; then
        log_info "cdn-lookup already installed"
    else
        log_info "Installing cdn-lookup from GitHub"
        require_command wget jq tar

        # Create temp download directory
        local temp_dir="/tmp/pktstat-install-$$"
        mkdir -p "$temp_dir"
        export DOWNLOAD_DIR="$temp_dir"

        # Download from GitHub
        if ! download_github_release "nikescar/cdn-lookup" "cdn-lookup*"; then
            log_error "Failed to download cdn-lookup"
            rm -rf "$temp_dir"
            exit 1
        fi

        # Find downloaded package
        local pkg_file=$(find "$temp_dir" -name "cdn-lookup*" -type f | head -1)
        if [ -z "$pkg_file" ]; then
            log_error "cdn-lookup package not found after download"
            rm -rf "$temp_dir"
            exit 1
        fi

        log_info "Found package: $pkg_file"

        # Extract if tar.gz, or use directly
        local binary_file
        if echo "$pkg_file" | grep -q "\.tar\.gz$"; then
            log_info "Extracting archive"
            tar -xzf "$pkg_file" -C "$temp_dir/" || {
                log_error "Failed to extract cdn-lookup"
                rm -rf "$temp_dir"
                exit 1
            }
            binary_file=$(find "$temp_dir" -name "cdn-lookup" -type f -perm -100 | head -1)
            if [ -z "$binary_file" ]; then
                binary_file=$(find "$temp_dir" -type f -perm -100 | grep -i cdn-lookup | head -1)
            fi
        else
            binary_file="$pkg_file"
        fi

        if [ -z "$binary_file" ]; then
            log_error "cdn-lookup binary not found in package"
            rm -rf "$temp_dir"
            exit 1
        fi

        log_info "Installing binary: $binary_file"
        install -m 755 "$binary_file" /usr/local/bin/cdn-lookup || {
            log_error "Failed to install cdn-lookup to /usr/local/bin"
            rm -rf "$temp_dir"
            exit 1
        }

        rm -rf "$temp_dir"
        log_info "cdn-lookup installed successfully"
    fi

    # Step 3: Copy .env to portable location
    log_info "Step 3/7: Copying .env to portable location"
    local config_dir="$HOME/.config/pf"
    ensure_dir "$config_dir"
    if [ -f "$SCRIPT_DIR/.env" ]; then
        cp "$SCRIPT_DIR/.env" "$config_dir/.env"
        chmod 644 "$config_dir/.env"
        log_info "Copied .env to $config_dir/.env"
    else
        log_error ".env not found in $SCRIPT_DIR"
        exit 1
    fi

    # Step 4: Create log directory
    log_info "Step 4/7: Creating log directory"
    ensure_dir "$LOG_DIR"
    chmod 755 "$LOG_DIR"
    log_info "Created $LOG_DIR"

    # Step 5: Install logger script
    log_info "Step 5/7: Installing logger script"

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

    # Step 6: Add cron entry
    log_info "Step 6/7: Configuring cron"
    local cron_entry="@reboot $LOGGER_SCRIPT >/dev/null 2>&1 &"

    if crontab -l 2>/dev/null | grep -q "$CRON_PATTERN"; then
        log_info "Cron entry already exists"
    else
        (crontab -l 2>/dev/null || true; echo "$cron_entry") | crontab -
        log_info "Added cron entry: $cron_entry"
    fi

    # Step 7: Start logger
    log_info "Step 7/7: Starting logger"

    # Kill existing logger if running
    pkill -f "^$LOGGER_SCRIPT" 2>/dev/null && log_info "Stopped existing logger" || true
    sleep 1

    # Test logger script syntax
    if ! sh -n "$LOGGER_SCRIPT" 2>&1; then
        log_error "Logger script has syntax errors"
        exit 1
    fi

    # Start in background
    local startup_log="/tmp/pktstat-logger-startup.log"
    rm -f "$startup_log"
    nohup "$LOGGER_SCRIPT" >"$startup_log" 2>&1 &
    local logger_pid=$!
    log_info "Started logger (PID: $logger_pid)"

    # Wait and verify
    sleep 2
    if ps -p "$logger_pid" >/dev/null 2>&1; then
        log_info "Logger process is running"
    else
        log_error "Logger process died immediately"
        log_error "Startup log:"
        cat "$startup_log" >&2
        exit 1
    fi

    # Verify installation
    log_info "Verifying installation"

    sleep 3
    local current_log="$LOG_DIR/pktstat-$(date +%Y-%m-%d).log"
    if [ -f "$current_log" ]; then
        local log_size=$(wc -c < "$current_log")
        log_info "Log file created: $current_log (${log_size} bytes)"
    else
        log_warn "Log file not yet created (may take a few seconds)"
    fi

    log_info "=== Installation Complete ==="
    log_info ""
    log_info "Useful commands:"
    log_info "  View logs:     tail -f $LOG_DIR/pktstat-\$(date +%Y-%m-%d).log"
    log_info "  Check status:  $0 --status"
    log_info "  Uninstall:     doas $0 --uninstall"
}

#
# Command: --uninstall (remove logger)
#
cmd_uninstall() {
    require_root

    log_info "=== pktstat Logger Uninstall ==="

    # Stop running logger
    log_info "Stopping logger process"
    if pkill -f "^$LOGGER_SCRIPT" 2>/dev/null; then
        log_info "Logger process stopped"
    else
        log_info "No logger process found"
    fi

    # Remove cron entry
    log_info "Removing cron entry"
    if crontab -l 2>/dev/null | grep -q "$CRON_PATTERN"; then
        crontab -l 2>/dev/null | grep -v "$CRON_PATTERN" | crontab -
        log_info "Cron entry removed"
    else
        log_info "No cron entry found"
    fi

    # Optionally remove logger script
    if [ -f "$LOGGER_SCRIPT" ]; then
        log_info "Logger script still exists: $LOGGER_SCRIPT"
        log_info "Log directory preserved: $LOG_DIR"
        log_info "Run manually to remove: rm $LOGGER_SCRIPT"
    fi

    log_info "=== Uninstall Complete ==="
}

#
# Command: --status (show status)
#
cmd_status() {
    log_info "=== pktstat Logger Status ==="

    # Check cron installation
    log_info "Cron status:"
    if crontab -l 2>/dev/null | grep -q "$CRON_PATTERN"; then
        local cron_line=$(crontab -l 2>/dev/null | grep "$CRON_PATTERN")
        log_info "  Installed: YES"
        log_info "  Entry: $cron_line"
    else
        log_info "  Installed: NO"
    fi

    # Check running process
    log_info "Process status:"
    local pid=$(pgrep -f "^$LOGGER_SCRIPT" 2>/dev/null)
    if [ -n "$pid" ]; then
        log_info "  Running: YES (PID: $pid)"
    else
        log_info "  Running: NO"
    fi

    # Check logger script
    log_info "Logger script:"
    if [ -f "$LOGGER_SCRIPT" ]; then
        log_info "  Exists: YES ($LOGGER_SCRIPT)"
    else
        log_info "  Exists: NO"
    fi

    # Check log directory and files
    log_info "Log files:"
    if [ -d "$LOG_DIR" ]; then
        local log_count=$(find "$LOG_DIR" -name "pktstat-*.log" 2>/dev/null | wc -l | tr -d ' ')
        local total_size=$(du -sh "$LOG_DIR" 2>/dev/null | awk '{print $1}')
        log_info "  Directory: $LOG_DIR"
        log_info "  File count: $log_count"
        log_info "  Total size: ${total_size:-0}"

        # Show latest log
        local latest_log="$LOG_DIR/pktstat-$(date +%Y-%m-%d).log"
        if [ -f "$latest_log" ]; then
            local latest_size=$(wc -c < "$latest_log" | tr -d ' ')
            log_info "  Latest log: $latest_log (${latest_size} bytes)"
            log_info "  Sample (last 3 lines):"
            tail -3 "$latest_log" 2>/dev/null | while IFS= read -r line; do
                log_info "    $line"
            done
        else
            log_info "  No log for today"
        fi
    else
        log_info "  Directory: NOT FOUND"
    fi

    log_info "=== Status Complete ==="
}

#
# Main
#
main() {
    case "${1:-}" in
        --install)
            cmd_install
            ;;
        --uninstall)
            cmd_uninstall
            ;;
        --status)
            cmd_status
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        *)
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
