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
log_debug() { log "DEBUG" "$@"; }
log_trace() { log "TRACE" "$@"; }

_trim_string() {
    echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

_download_github_pkgs() { # _download_github_pkgs DNSCrypt/dnscrypt-proxy dnscrypt-proxy-linux*.tar.gz
    local arch1 arch2
    arch1=$(uname -m)
    arch2=$(uname -m)
    [ -n "${3}" ] && arch1=${3}
    [ -n "${4}" ] && arch2=${4}
    [ "$(echo "$1" | grep -c "/")" != 1 ] && log_debug "please set githubid/repoid." && return 1
    local pkgurl="https://api.github.com/repos/$(_trim_string "$1")/releases/latest"

    IFS='*' read -r pkgfileprefix pkgfilepostfix <<EOF
$(_trim_string "$2")
EOF
    [ -n "$(find "${JANGBI_IT}/pkgs/" -name "$2" 2>/dev/null)" ] && rm -f "${JANGBI_IT}/pkgs/$2"
    pkgfileprefix=$(_trim_string "${pkgfileprefix}")
    pkgfilepostfix=$(_trim_string "${pkgfilepostfix}")

    # Use GitHub token if available to avoid rate limiting
    local curl_cmd="curl -sSL"
    if [ -n "${GITHUB_TOKEN}" ]; then
        curl_cmd="curl -sSL -H \"Authorization: Bearer ${GITHUB_TOKEN}\""
        log_trace "Using GitHub token for API request"
    fi

    local possible_list=$(eval "${curl_cmd}" "${pkgurl}" | jq -r '.assets[] | select(.name | contains("'"${arch1}"'") or contains("'"${arch2}"'")) | .browser_download_url')

    if [ -n "$possible_list" ]; then
        echo "$possible_list" | while IFS= read -r durl; do
            durl=$(_trim_string "${durl}")
            durl_lower=$(echo "$durl" | tr '[:upper:]' '[:lower:]')
            prefix_lower=$(echo "$pkgfileprefix" | tr '[:upper:]' '[:lower:]')
            postfix_lower=$(echo "$pkgfilepostfix" | tr '[:upper:]' '[:lower:]')

            # Type 1: matches both prefix and postfix
            if echo "$durl_lower" | grep -q "${prefix_lower}" && echo "$durl_lower" | grep -q "${postfix_lower}"; then
                log_debug "Downloading(type1) ${durl}..."
                wget --directory-prefix="${JANGBI_IT}/pkgs" "${durl}" || (log_error "error downloading ${durl}"; return 1)
                return 0
            fi
        done

        # Type 2: matches prefix and contains "linux"
        echo "$possible_list" | while IFS= read -r durl; do
            durl=$(_trim_string "${durl}")
            durl_lower=$(echo "$durl" | tr '[:upper:]' '[:lower:]')
            prefix_lower=$(echo "$pkgfileprefix" | tr '[:upper:]' '[:lower:]')

            if echo "$durl_lower" | grep -q "${prefix_lower}" && echo "$durl_lower" | grep -q "linux"; then
                log_debug "Downloading(type2) ${durl}..."
                wget --directory-prefix="${JANGBI_IT}/pkgs" "${durl}" || (log_error "error downloading ${durl}"; return 1)
                return 0
            fi
        done

        # Type 3: matches arch1 and postfix
        echo "$possible_list" | while IFS= read -r durl; do
            durl=$(_trim_string "${durl}")
            durl_lower=$(echo "$durl" | tr '[:upper:]' '[:lower:]')
            arch1_lower=$(echo "$arch1" | tr '[:upper:]' '[:lower:]')
            postfix_lower=$(echo "$pkgfilepostfix" | tr '[:upper:]' '[:lower:]')

            if echo "$durl_lower" | grep -q "${arch1_lower}" && echo "$durl_lower" | grep -q "${postfix_lower}"; then
                log_debug "Downloading(type3) ${durl}..."
                wget --directory-prefix="${JANGBI_IT}/pkgs" "${durl}" || (log_error "error downloading ${durl}"; return 1)
                return 0
            fi
        done

        # Type 4: matches arch2 and postfix
        echo "$possible_list" | while IFS= read -r durl; do
            durl=$(_trim_string "${durl}")
            durl_lower=$(echo "$durl" | tr '[:upper:]' '[:lower:]')
            arch2_lower=$(echo "$arch2" | tr '[:upper:]' '[:lower:]')
            postfix_lower=$(echo "$pkgfilepostfix" | tr '[:upper:]' '[:lower:]')

            if echo "$durl_lower" | grep -q "${arch2_lower}" && echo "$durl_lower" | grep -q "${postfix_lower}"; then
                log_debug "Downloading(type4) ${durl}..."
                wget --directory-prefix="${JANGBI_IT}/pkgs" "${durl}" || (log_error "error downloading ${durl}"; return 1)
                return 0
            fi
        done
    fi

    log_error "No matching package found for ${pkgfileprefix} ${arch1} ${pkgfilepostfix}"
    return 1
}

log_info "Starting pktstat logger installation"

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root"
    exit 1
fi

# Check required commands
for cmd in wget jq tar; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "Required command not found: $cmd"
        log_error "Please install: pkg_add $cmd"
        exit 1
    fi
done

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
log_info "Step 1/7: Checking pktstat"
if ! command -v pktstat >/dev/null 2>&1; then
    log_info "pktstat not found. Installing"
    pkg_add pktstat || {
        log_error "Failed to install pktstat"
        exit 1
    }
else
    log_info "pktstat already installed"
fi

# Step 2: Download and install cdn-lookup
log_info "Step 2/7: Checking cdn-lookup"
if command -v cdn-lookup >/dev/null 2>&1; then
    log_info "cdn-lookup already installed"
else
    log_info "cdn-lookup not found. Downloading from GitHub"

    # Create temp directory
    JANGBI_IT="/tmp/pf-install"
    mkdir -p "$JANGBI_IT/pkgs"
    export JANGBI_IT

    # Download from GitHub (nikescar/cdn-lookup)
    _download_github_pkgs "nikescar/cdn-lookup" "cdn-lookup*" || {
        log_error "Failed to download cdn-lookup"
        exit 1
    }

    # Find downloaded package
    CDN_PKG=$(find "$JANGBI_IT/pkgs" -name "cdn-lookup*" -type f | head -1)
    if [ -z "$CDN_PKG" ]; then
        log_error "cdn-lookup package not found after download"
        exit 1
    fi

    log_info "Found package: $CDN_PKG"

    # Extract binary (handle tar.gz or direct binary)
    if echo "$CDN_PKG" | grep -q "\.tar\.gz$"; then
        log_info "Extracting tar.gz archive"
        tar -xzf "$CDN_PKG" -C "$JANGBI_IT/pkgs/" || {
            log_error "Failed to extract cdn-lookup"
            exit 1
        }
        CDN_BIN=$(find "$JANGBI_IT/pkgs" -name "cdn-lookup" -type f -perm -100 | head -1)
        if [ -z "$CDN_BIN" ]; then
            # Try finding any executable in extracted files
            CDN_BIN=$(find "$JANGBI_IT/pkgs" -type f -perm -100 | grep -i cdn-lookup | head -1)
        fi
    else
        CDN_BIN="$CDN_PKG"
    fi

    if [ -z "$CDN_BIN" ]; then
        log_error "cdn-lookup binary not found in package"
        exit 1
    fi

    log_info "Installing binary: $CDN_BIN"

    # Install to /usr/local/bin
    install -m 755 "$CDN_BIN" /usr/local/bin/cdn-lookup || {
        log_error "Failed to install cdn-lookup to /usr/local/bin"
        exit 1
    }

    # Cleanup temp directory
    rm -rf "$JANGBI_IT"

    log_info "cdn-lookup installed successfully"
fi

# Step 3: Create log directory
LOG_DIR="/var/log/pktstat"
log_info "Step 3/7: Creating log directory"
mkdir -p "$LOG_DIR"
chmod 755 "$LOG_DIR"
log_info "Created $LOG_DIR"

# Step 4: Install logger script
LOGGER_SCRIPT="/usr/local/bin/pktstat-logger.sh"
log_info "Step 4/7: Installing logger script"

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
log_info "Step 5/7: Configuring cron"
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
log_info "Step 6/7: Starting logger"

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
log_info "Step 7/7: Verifying installation"

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
