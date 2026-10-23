#!/bin/sh
# install-pktstat-logger.sh
# Installs pktstat-based IP connection logger with daily rotation and 7-day retention

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "${GREEN}=== pktstat Logger Installer ===${NC}"

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "${RED}Error: This script must be run as root${NC}"
    exit 1
fi

# Load environment variables from script's directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "${YELLOW}Warning: .env not found at $ENV_FILE${NC}"
    echo "Please create .env with: PF_ISP_INTERFACE=ure0"
    exit 1
fi

# Source .env
set -a
. "$ENV_FILE"
set +a

# Validate PF_ISP_INTERFACE is set
if [ -z "$PF_ISP_INTERFACE" ]; then
    echo "${RED}Error: PF_ISP_INTERFACE not set in .env${NC}"
    exit 1
fi

echo "Using interface: ${GREEN}$PF_ISP_INTERFACE${NC}"

# Step 1: Check and install pktstat
echo "\n${GREEN}[1/6]${NC} Checking pktstat..."
if ! command -v pktstat >/dev/null 2>&1; then
    echo "${YELLOW}pktstat not found. Installing...${NC}"
    pkg_add pktstat || {
        echo "${RED}Failed to install pktstat${NC}"
        exit 1
    }
else
    echo "pktstat already installed"
fi

# Step 2: Create log directory
LOG_DIR="/var/log/pktstat"
echo "\n${GREEN}[2/6]${NC} Creating log directory..."
mkdir -p "$LOG_DIR"
chmod 755 "$LOG_DIR"
echo "Created $LOG_DIR"

# Step 3: Install logger script
LOGGER_SCRIPT="/usr/local/bin/pktstat-logger.sh"
echo "\n${GREEN}[3/6]${NC} Installing logger script..."

cat > "$LOGGER_SCRIPT" <<LOGGER_EOF
#!/bin/sh
# pktstat-logger.sh - Continuous network monitoring with daily log rotation

# Load environment
ENV_FILE="$ENV_FILE"
if [ -f "\$ENV_FILE" ]; then
    set -a
    . "\$ENV_FILE"
    set +a
fi

# Validate interface
if [ -z "\$PF_ISP_INTERFACE" ]; then
    echo "Error: PF_ISP_INTERFACE not set in .env" >&2
    exit 1
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

echo "Starting pktstat logger on interface \$PF_ISP_INTERFACE"
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
    pktstat -i "\$PF_ISP_INTERFACE" -F -1 -w 5 -T -n "not (ip proto 89 or ip proto 1 or ip proto 2 or ip proto 103)" 2>/dev/null | \
        awk -v d="\$(date '+%Y-%m-%d %H:%M:%S')" 'NF > 2 {print d, \$0}' >> "\$LOG_FILE" || {
        # If pktstat fails, wait and retry
        sleep 5
    }
done
LOGGER_EOF

chmod +x "$LOGGER_SCRIPT"
echo "Installed $LOGGER_SCRIPT"

# Step 4: Add cron entry
echo "\n${GREEN}[4/6]${NC} Configuring cron..."
CRON_ENTRY="@reboot /usr/local/bin/pktstat-logger.sh >/dev/null 2>&1 &"

# Check if entry already exists
if crontab -l 2>/dev/null | grep -q "pktstat-logger.sh"; then
    echo "Cron entry already exists"
else
    # Add to crontab
    (crontab -l 2>/dev/null || true; echo "$CRON_ENTRY") | crontab -
    echo "Added cron entry: $CRON_ENTRY"
fi

# Step 5: Start logger
echo "\n${GREEN}[5/6]${NC} Starting logger..."

# Kill existing logger if running
pkill -f "pktstat-logger.sh" 2>/dev/null || true
sleep 1

# Start in background
nohup "$LOGGER_SCRIPT" >/dev/null 2>&1 &
LOGGER_PID=$!
sleep 2

echo "Logger started with PID: $LOGGER_PID"

# Step 6: Verify installation
echo "\n${GREEN}[6/6]${NC} Verifying installation..."

# Check if process is running
if ps -p "$LOGGER_PID" >/dev/null 2>&1; then
    echo "${GREEN}✓${NC} Logger process is running (PID: $LOGGER_PID)"
else
    echo "${YELLOW}⚠${NC} Logger process check inconclusive"
fi

# Check if log file exists
sleep 3
CURRENT_LOG="$LOG_DIR/pktstat-$(date +%Y-%m-%d).log"
if [ -f "$CURRENT_LOG" ]; then
    LOG_SIZE=$(wc -c < "$CURRENT_LOG")
    echo "${GREEN}✓${NC} Log file created: $CURRENT_LOG (${LOG_SIZE} bytes)"
    echo "\nSample output:"
    tail -3 "$CURRENT_LOG" 2>/dev/null || echo "(waiting for data...)"
else
    echo "${YELLOW}⚠${NC} Log file not yet created (may take a few seconds)"
fi

# Check cron
if crontab -l 2>/dev/null | grep -q "pktstat-logger.sh"; then
    echo "${GREEN}✓${NC} Cron entry configured (@reboot)"
else
    echo "${RED}✗${NC} Cron entry not found"
fi

echo "\n${GREEN}=== Installation Complete ===${NC}"
echo "\nUseful commands:"
echo "  View logs:     tail -f $LOG_DIR/pktstat-\$(date +%Y-%m-%d).log"
echo "  List logs:     ls -lh $LOG_DIR/"
echo "  Check process: ps aux | grep pktstat-logger"
echo "  Stop logger:   pkill -f pktstat-logger.sh"
echo "  Restart:       $LOGGER_SCRIPT &"
echo "\nLogs are retained for 7 days and rotated daily."
echo "Using .env from: $ENV_FILE"
