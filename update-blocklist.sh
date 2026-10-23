#!/bin/sh
# PF Blocklist Updater - Range-based blocking
# Downloads threat IPs and finds their network ranges

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
IP2ASN_CACHE="$SCRIPT_DIR/ip2asn-v4.tsv"
IP2ASN_INT_CACHE="$SCRIPT_DIR/ip2asn-v4-int.tsv"
INBOUND_CACHE="$SCRIPT_DIR/inbound.txt"
OUTBOUND_CACHE="$SCRIPT_DIR/outbound.txt"
BLOCKLIST_FILE="$SCRIPT_DIR/blocklist"
BACKUP_FILE="$SCRIPT_DIR/blocklist.$(date +%Y%m%d)"
PF_CONF="${PF_OUTPUT_FILE:-/etc/pf.conf}"

# Temp files
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "[$(date)] Starting blocklist update..."

#
# Function: Download and cache ip2asn database
#
download_ip2asn() {
    local cache_age=999999
    local needs_download=1

    if [ -f "$IP2ASN_CACHE" ]; then
        cache_age=$(( $(date +%s) - $(stat -f %m "$IP2ASN_CACHE" 2>/dev/null || stat -c %Y "$IP2ASN_CACHE" 2>/dev/null) ))
        local max_age=$(( ${PF_BLOCKLIST_CACHE_DAYS:-180} * 86400 ))
        if [ $cache_age -le $max_age ]; then
            needs_download=0
        fi
    fi

    if [ $needs_download -eq 1 ]; then
        echo "Downloading ip2asn database (~50MB compressed)..."
        curl -sL "$PF_IP2ASN_URL" | gunzip > "$IP2ASN_CACHE.tmp"

        if [ -s "$IP2ASN_CACHE.tmp" ]; then
            mv "$IP2ASN_CACHE.tmp" "$IP2ASN_CACHE"
            echo "Downloaded $(wc -l < "$IP2ASN_CACHE" | tr -d ' ') IP range entries"
        else
            echo "ERROR: Failed to download ip2asn database"
            rm -f "$IP2ASN_CACHE.tmp"
            exit 1
        fi
    else
        local days_old=$(( cache_age / 86400 ))
        echo "Using cached ip2asn database (${days_old} days old)"
    fi

    # Generate integer cache if missing
    if [ ! -f "$IP2ASN_INT_CACHE" ]; then
        echo "Converting to integer format..."
        awk '{
            split($1, s, ".");
            split($2, e, ".");
            start = (s[1] * 16777216) + (s[2] * 65536) + (s[3] * 256) + s[4];
            end = (e[1] * 16777216) + (e[2] * 65536) + (e[3] * 256) + e[4];
            print start, end, $1, $2;
        }' "$IP2ASN_CACHE" > "$IP2ASN_INT_CACHE"
        echo "Conversion complete"
    fi
}

#
# Function: Download IP lists
#
download_ip_lists() {
    local needs_download=0
    local max_age=$((7 * 86400))  # 7 days

    # Check inbound cache
    if [ -f "$INBOUND_CACHE" ]; then
        local cache_age=$(( $(date +%s) - $(stat -f %m "$INBOUND_CACHE" 2>/dev/null || stat -c %Y "$INBOUND_CACHE" 2>/dev/null) ))
        if [ $cache_age -gt $max_age ]; then
            needs_download=1
        fi
    else
        needs_download=1
    fi

    # Download if needed
    if [ $needs_download -eq 1 ]; then
        echo "Downloading IP lists..."
        curl -sL "$PF_BLOCKLIST_INBOUND_URL" > "$INBOUND_CACHE.tmp"
        curl -sL "$PF_BLOCKLIST_OUTBOUND_URL" > "$OUTBOUND_CACHE.tmp"

        if [ -s "$INBOUND_CACHE.tmp" ] && [ -s "$OUTBOUND_CACHE.tmp" ]; then
            mv "$INBOUND_CACHE.tmp" "$INBOUND_CACHE"
            mv "$OUTBOUND_CACHE.tmp" "$OUTBOUND_CACHE"
        else
            echo "ERROR: Failed to download IP lists"
            rm -f "$INBOUND_CACHE.tmp" "$OUTBOUND_CACHE.tmp"
            exit 1
        fi
    else
        local days_old=$(( cache_age / 86400 ))
        echo "Using cached IP lists (${days_old} days old)"
    fi

    # Combine and deduplicate
    cat "$INBOUND_CACHE" "$OUTBOUND_CACHE" | \
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | \
        sort -u > "$TEMP_DIR/ip_list.txt"

    local ip_count=$(wc -l < "$TEMP_DIR/ip_list.txt" | tr -d ' ')
    echo "Processing $ip_count unique IPs"

    if [ "$ip_count" -eq 0 ]; then
        echo "ERROR: No valid IPs found"
        exit 1
    fi
}

#
# Function: IP to integer conversion
#
ip2int() {
    local ip=$1
    local a b c d
    IFS=. read -r a b c d <<EOF
$ip
EOF
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

#
# Function: Find ranges using merge-join (O(n+m) instead of O(n*m))
#
find_ranges() {
    echo "Finding IP ranges (optimized merge-join)..."

    # Convert all IPs to integers
    echo "Converting IPs to integers..."
    awk '{
        split($1, p, ".");
        ip_int = (p[1] * 16777216) + (p[2] * 65536) + (p[3] * 256) + p[4];
        print ip_int;
    }' "$TEMP_DIR/ip_list.txt" | sort -n > "$TEMP_DIR/ip_list_int.txt"

    # Merge-join sorted IPs with sorted ip2asn ranges
    echo "Matching IPs to ranges..."
    awk '
    NR == FNR {
        # Load ip2asn cache (already sorted by start IP)
        ranges[NR] = $0;
        starts[NR] = $1;
        ends[NR] = $2;
        max_range = NR;
        next;
    }
    {
        # For each IP, find matching range
        ip = $1;

        # Start from current position (ranges are sorted)
        for (i = last_pos > 0 ? last_pos : 1; i <= max_range; i++) {
            if (ip >= starts[i] && ip <= ends[i]) {
                split(ranges[i], parts, " ");
                print parts[3], parts[4];
                last_pos = i;  # Remember position for next lookup
                break;
            }
            if (starts[i] > ip) break;  # IP is before this range
        }
    }
    ' "$IP2ASN_INT_CACHE" "$TEMP_DIR/ip_list_int.txt" | \
        sort -u > "$TEMP_DIR/ip_ranges.txt"

    local range_count=$(wc -l < "$TEMP_DIR/ip_ranges.txt" | tr -d ' ')
    echo "Found $range_count unique IP ranges"

    if [ "$range_count" -eq 0 ]; then
        echo "ERROR: No IP ranges found"
        exit 1
    fi
}

#
# Function: Create metadata for each IP range
#
create_metadata() {
    echo "Generating metadata for IP ranges..."

    awk '
    NR == FNR {
        # Load ip2asn metadata: key = "start_ip end_ip"
        key = $1 " " $2;
        asn[key] = $3;
        country[key] = $4;
        # Description is everything after field 4
        desc[key] = "";
        for (i = 5; i <= NF; i++) {
            if (i > 5) desc[key] = desc[key] " ";
            desc[key] = desc[key] $i;
        }
        next;
    }
    {
        # For each range, lookup metadata
        key = $1 " " $2;
        c = (country[key] != "") ? country[key] : "??";
        a = (asn[key] != "") ? asn[key] : "0";
        d = (desc[key] != "") ? desc[key] : "Unknown";
        print $1, $2, a, c, d;
    }
    ' "$IP2ASN_CACHE" "$TEMP_DIR/ip_ranges.txt" > "$TEMP_DIR/ip_metadata.txt"

    local meta_count=$(wc -l < "$TEMP_DIR/ip_metadata.txt" | tr -d ' ')
    echo "Generated metadata for $meta_count ranges"
}

#
# Function: Convert IP range to CIDR (simple approximation)
#
range_to_cidr() {
    local start_ip=$1
    local end_ip=$2

    # Simple approach: calculate approximate /prefix
    local start=$(ip2int "$start_ip")
    local end=$(ip2int "$end_ip")
    local size=$(( end - start + 1 ))

    # Find closest power of 2
    local prefix=32
    local block=1

    while [ $block -lt $size ] && [ $prefix -gt 0 ]; do
        prefix=$((prefix - 1))
        block=$((block * 2))
    done

    echo "$start_ip/$prefix"
}

#
# Function: Convert all ranges to CIDR notation
#
convert_to_cidr() {
    echo "Converting IP ranges to CIDR notation with metadata..."

    # Process all ranges with awk (much faster than shell loop)
    awk '
    # IP to integer conversion
    function ip2int(ip) {
        split(ip, p, ".");
        return (p[1] * 16777216) + (p[2] * 65536) + (p[3] * 256) + p[4];
    }

    # Range to CIDR approximation
    function range_to_cidr(start_ip, end_ip) {
        start = ip2int(start_ip);
        end = ip2int(end_ip);
        size = end - start + 1;

        # Find closest power of 2
        prefix = 32;
        block = 1;
        while (block < size && prefix > 0) {
            prefix--;
            block *= 2;
        }

        return start_ip "/" prefix;
    }

    NR == FNR {
        # Load metadata: line N has metadata for range N
        meta_asn[NR] = $3;
        meta_country[NR] = $4;
        meta_isp[NR] = "";
        for (i = 5; i <= NF; i++) {
            if (i > 5) meta_isp[NR] = meta_isp[NR] " ";
            meta_isp[NR] = meta_isp[NR] $i;
        }
        next;
    }
    {
        # Process ranges: line N from ip_ranges.txt
        start_ip = $1;
        end_ip = $2;
        cidr = range_to_cidr(start_ip, end_ip);

        # Get metadata for this line
        asn = meta_asn[FNR];
        country = meta_country[FNR];
        isp = meta_isp[FNR];

        # Format: CIDR<tab>Country | ASN | ISP | Range
        info = country " | AS" asn " | " isp " | " start_ip "-" end_ip;
        print cidr "\t" info;
    }
    ' "$TEMP_DIR/ip_metadata.txt" "$TEMP_DIR/ip_ranges.txt" > "$TEMP_DIR/combined_all.txt"

    # Filter private IPs (both CIDR and info together)
    grep -Ev "^192\.168\.|^10\.|^172\.(1[6-9]|2[0-9]|3[01])\.|^127\.|^0\.|^169\.254\." \
        "$TEMP_DIR/combined_all.txt" > "$TEMP_DIR/combined_filtered.txt"

    # Sort by CIDR and remove duplicates
    sort -u -k1,1 "$TEMP_DIR/combined_filtered.txt" > "$TEMP_DIR/combined_sorted.txt"

    # Split into separate files
    awk -F'\t' '{print $1}' "$TEMP_DIR/combined_sorted.txt" > "$TEMP_DIR/blocklist_final.txt"
    awk -F'\t' '{print $2}' "$TEMP_DIR/combined_sorted.txt" > "$TEMP_DIR/info_final.txt"

    local final_count=$(wc -l < "$TEMP_DIR/blocklist_final.txt" | tr -d ' ')
    echo "Generated $final_count unique CIDR blocks with metadata"

    if [ "$final_count" -eq 0 ]; then
        echo "ERROR: Final blocklist is empty"
        exit 1
    fi
}

#
# Main execution
#

# Backup existing blocklist
if [ -f "$BLOCKLIST_FILE" ]; then
    cp "$BLOCKLIST_FILE" "$BACKUP_FILE"
    echo "Backed up to $BACKUP_FILE"
fi

# Backup existing info file
if [ -f "${BLOCKLIST_FILE}.info.txt" ]; then
    cp "${BLOCKLIST_FILE}.info.txt" "${BACKUP_FILE}.info.txt"
fi

# Download and cache ip2asn database
download_ip2asn

# Download sample IP lists
download_ip_lists

# Find IP ranges for sample IPs
find_ranges

# Generate metadata for ranges
create_metadata

# Convert to CIDR and finalize
convert_to_cidr

# Deploy new blocklist and info file
mv "$TEMP_DIR/blocklist_final.txt" "$BLOCKLIST_FILE"
mv "$TEMP_DIR/info_final.txt" "${BLOCKLIST_FILE}.info.txt"
echo "Deployed to $BLOCKLIST_FILE and ${BLOCKLIST_FILE}.info.txt"

# CI mode: skip PF operations
if [ -n "$CI" ]; then
    echo "[CI] Blocklist generated successfully: $BLOCKLIST_FILE"
    echo "[CI] Skipping PF validation and reload"
    exit 0
fi

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
echo "PF reload complete. Blocking $ACTIVE_RULES IP ranges."

# Cleanup old backups (keep last 5)
ls -t "$SCRIPT_DIR"/blocklist.2* 2>/dev/null | grep -v '\.info\.txt$' | tail -n +6 | xargs rm -f 2>/dev/null || true
ls -t "$SCRIPT_DIR"/blocklist.2*.info.txt 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true

echo "[$(date)] Blocklist update complete."
