#!/bin/sh
# PF Blocklist Updater - Range-based blocking
# Downloads threat IPs and finds their network ranges

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
APPNAME="update-blocklist"

# RFC 5424 syslog-style logging
log() {
    local level="$1"
    shift
    printf "%s %s %s: %s\n" "$(date +%Y-%m-%dT%H:%M:%S)" "$level" "$APPNAME" "$*"
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

# Load configuration
if [ ! -f "$ENV_FILE" ]; then
    log_error "$ENV_FILE not found"
    exit 1
fi

set -a
. "$ENV_FILE"
set +a

# Validate blocklist mode
BLOCKLIST_MODE="${PF_BLOCKLIST_MODE:-ip}"
if [ "$BLOCKLIST_MODE" != "ip" ] && [ "$BLOCKLIST_MODE" != "asn" ]; then
    log_error "PF_BLOCKLIST_MODE must be 'ip' or 'asn' (got: $BLOCKLIST_MODE)"
    exit 1
fi

log_info "Blocklist mode: $BLOCKLIST_MODE"

# Files
IP2ASN_CACHE="$SCRIPT_DIR/ip2asn-v4.tsv"
IP2ASN_INT_CACHE="$SCRIPT_DIR/ip2asn-v4-int.tsv"
INBOUND_CACHE="$SCRIPT_DIR/inbound.txt"
OUTBOUND_CACHE="$SCRIPT_DIR/outbound.txt"
BLOCKLIST_FILE="$SCRIPT_DIR/blocklist"
BACKUP_FILE="$SCRIPT_DIR/blocklist.bak"
PF_CONF="${PF_OUTPUT_FILE:-/etc/pf.conf}"

# Temp files
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

log_info "Starting blocklist update"

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
        log_info "Downloading ip2asn database (~50MB compressed)"
        curl -sL "$PF_IP2ASN_URL" | gunzip > "$IP2ASN_CACHE.tmp"

        if [ -s "$IP2ASN_CACHE.tmp" ]; then
            mv "$IP2ASN_CACHE.tmp" "$IP2ASN_CACHE"
            log_info "Downloaded $(wc -l < "$IP2ASN_CACHE" | tr -d ' ') IP range entries"
        else
            log_error "Failed to download ip2asn database"
            rm -f "$IP2ASN_CACHE.tmp"
            exit 1
        fi
    else
        local days_old=$(( cache_age / 86400 ))
        log_info "Using cached ip2asn database (${days_old} days old)"
    fi

    # Generate integer cache if missing
    if [ ! -f "$IP2ASN_INT_CACHE" ]; then
        log_info "Converting to integer format"
        awk '{
            split($1, s, ".");
            split($2, e, ".");
            start = (s[1] * 16777216) + (s[2] * 65536) + (s[3] * 256) + s[4];
            end = (e[1] * 16777216) + (e[2] * 65536) + (e[3] * 256) + e[4];
            print start, end, $1, $2;
        }' "$IP2ASN_CACHE" > "$IP2ASN_INT_CACHE"
        log_info "Conversion complete"
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
        log_info "Downloading IP lists"
        curl -sL "$PF_BLOCKLIST_INBOUND_URL" > "$INBOUND_CACHE.tmp"
        curl -sL "$PF_BLOCKLIST_OUTBOUND_URL" > "$OUTBOUND_CACHE.tmp"

        if [ -s "$INBOUND_CACHE.tmp" ] && [ -s "$OUTBOUND_CACHE.tmp" ]; then
            mv "$INBOUND_CACHE.tmp" "$INBOUND_CACHE"
            mv "$OUTBOUND_CACHE.tmp" "$OUTBOUND_CACHE"
        else
            log_error "Failed to download IP lists"
            rm -f "$INBOUND_CACHE.tmp" "$OUTBOUND_CACHE.tmp"
            exit 1
        fi
    else
        local days_old=$(( cache_age / 86400 ))
        log_info "Using cached IP lists (${days_old} days old)"
    fi

    # Combine and deduplicate
    cat "$INBOUND_CACHE" "$OUTBOUND_CACHE" | \
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | \
        sort -u > "$TEMP_DIR/ip_list.txt"

    local ip_count=$(wc -l < "$TEMP_DIR/ip_list.txt" | tr -d ' ')
    log_info "Processing $ip_count unique IPs"

    if [ "$ip_count" -eq 0 ]; then
        log_error "No valid IPs found"
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
    log_info "Finding IP ranges (optimized merge-join)"

    # Convert all IPs to integers
    log_info "Converting IPs to integers"
    awk '{
        split($1, p, ".");
        ip_int = (p[1] * 16777216) + (p[2] * 65536) + (p[3] * 256) + p[4];
        print ip_int;
    }' "$TEMP_DIR/ip_list.txt" | sort -n > "$TEMP_DIR/ip_list_int.txt"

    # Merge-join sorted IPs with sorted ip2asn ranges
    log_info "Matching IPs to ranges"
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
    log_info "Found $range_count unique IP ranges"

    if [ "$range_count" -eq 0 ]; then
        log_error "No IP ranges found"
        exit 1
    fi
}

#
# Function: Create metadata for each IP range
#
create_metadata() {
    log_info "Generating metadata for IP ranges"

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
    log_info "Generated metadata for $meta_count ranges"
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
    log_info "Converting IP ranges to CIDR notation with metadata"

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

    local filtered_count=$(wc -l < "$TEMP_DIR/combined_filtered.txt" | tr -d ' ')
    log_info "Generated $filtered_count unique CIDR blocks with metadata (before whitelist filter)"
}

#
# Function: Finalize blocklist (sort and split)
#
finalize_blocklist() {
    log_info "Finalizing blocklist"

    # Sort by CIDR and remove duplicates
    sort -u -k1,1 "$TEMP_DIR/combined_filtered.txt" > "$TEMP_DIR/combined_sorted.txt"

    # Split into separate files
    awk -F'\t' '{print $1}' "$TEMP_DIR/combined_sorted.txt" > "$TEMP_DIR/blocklist_final.txt"
    awk -F'\t' '{print $2}' "$TEMP_DIR/combined_sorted.txt" > "$TEMP_DIR/info_final.txt"

    local final_count=$(wc -l < "$TEMP_DIR/blocklist_final.txt" | tr -d ' ')
    log_info "Final blocklist: $final_count entries"

    if [ "$final_count" -eq 0 ]; then
        log_error "Final blocklist is empty"
        exit 1
    fi
}

#
# Function: Filter whitelisted ranges
#
filter_whitelist() {
    log_info "Filtering whitelisted ranges"

    # Check if whitelist is defined
    if [ -z "$PF_WHITELIST_RANGES" ]; then
        log_info "No whitelist defined, skipping filter"
        return
    fi

    # Create whitelist file
    echo "$PF_WHITELIST_RANGES" | tr ' ' '\n' > "$TEMP_DIR/whitelist.txt"

    local whitelist_count=$(wc -l < "$TEMP_DIR/whitelist.txt" | tr -d ' ')
    log_info "Whitelist entries: $whitelist_count"

    # Filter using awk to check CIDR overlap
    awk '
    # CIDR to IP range conversion
    function cidr2range(cidr,    parts, ip, mask, ip_int, mask_int, start, end) {
        split(cidr, parts, "/");
        ip = parts[1];
        mask = parts[2];

        # IP to integer
        split(ip, a, ".");
        ip_int = (a[1] * 16777216) + (a[2] * 65536) + (a[3] * 256) + a[4];

        # Calculate network mask
        mask_int = 0;
        for (i = 0; i < mask; i++) {
            mask_int = mask_int + (2 ^ (31 - i));
        }

        # Network address
        start = bitand(ip_int, mask_int);
        # Broadcast address
        end = bitor(start, bitxor(4294967295, mask_int));

        return start "," end;
    }

    # Bitwise AND
    function bitand(a, b,    result, bit) {
        result = 0;
        for (bit = 1; bit <= 4294967295; bit *= 2) {
            if ((int(a / bit) % 2) && (int(b / bit) % 2)) {
                result += bit;
            }
            if (bit > a && bit > b) break;
        }
        return result;
    }

    # Bitwise OR
    function bitor(a, b,    result, bit) {
        result = 0;
        for (bit = 1; bit <= 4294967295; bit *= 2) {
            if ((int(a / bit) % 2) || (int(b / bit) % 2)) {
                result += bit;
            }
            if (bit > a && bit > b) break;
        }
        return result;
    }

    # Bitwise XOR
    function bitxor(a, b,    result, bit) {
        result = 0;
        for (bit = 1; bit <= 4294967295; bit *= 2) {
            if ((int(a / bit) % 2) != (int(b / bit) % 2)) {
                result += bit;
            }
            if (bit > a && bit > b) break;
        }
        return result;
    }

    # Check if two ranges overlap
    function ranges_overlap(start1, end1, start2, end2) {
        return (start1 <= end2) && (end1 >= start2);
    }

    NR == FNR {
        # Load whitelist ranges
        split(cidr2range($1), range, ",");
        wl_start[NR] = range[1];
        wl_end[NR] = range[2];
        wl_count = NR;
        next;
    }
    {
        # Check each blocklist entry
        split($0, fields, "\t");
        cidr = fields[1];

        # Get range for this CIDR
        split(cidr2range(cidr), range, ",");
        bl_start = range[1];
        bl_end = range[2];

        # Check overlap with whitelist
        overlap = 0;
        for (i = 1; i <= wl_count; i++) {
            if (ranges_overlap(bl_start, bl_end, wl_start[i], wl_end[i])) {
                overlap = 1;
                break;
            }
        }

        # Output if no overlap
        if (!overlap) {
            print $0;
        }
    }
    ' "$TEMP_DIR/whitelist.txt" "$TEMP_DIR/combined_filtered.txt" > "$TEMP_DIR/combined_whitelist_filtered.txt"

    local before=$(wc -l < "$TEMP_DIR/combined_filtered.txt" | tr -d ' ')
    local after=$(wc -l < "$TEMP_DIR/combined_whitelist_filtered.txt" | tr -d ' ')
    local removed=$((before - after))

    log_info "Removed $removed whitelisted ranges (${before} -> ${after})"

    # Replace filtered file
    mv "$TEMP_DIR/combined_whitelist_filtered.txt" "$TEMP_DIR/combined_filtered.txt"
}

#
# Function: Process IP mode with /24 aggregation
#
process_ip_mode() {
    log_info "Processing IP mode"

    local ip_count=$(wc -l < "$TEMP_DIR/ip_list.txt" | tr -d ' ')

    if [ "$ip_count" -gt 100000 ]; then
        log_info "IP count ($ip_count) exceeds 100k threshold"
        log_info "Aggregating to /24 subnets"

        # Extract first 3 octets, deduplicate, convert to /24 CIDR
        awk -F. '{print $1"."$2"."$3".0/24"}' "$TEMP_DIR/ip_list.txt" | \
            sort -u > "$TEMP_DIR/blocklist_final.txt"

        local subnet_count=$(wc -l < "$TEMP_DIR/blocklist_final.txt" | tr -d ' ')
        log_info "Aggregated $ip_count IPs to $subnet_count /24 subnets"
    else
        log_info "Using raw IP list ($ip_count entries)"
        cp "$TEMP_DIR/ip_list.txt" "$TEMP_DIR/blocklist_final.txt"
    fi

    # Filter private IPs
    log_info "Filtering private IP ranges"
    grep -Ev "^192\.168\.|^10\.|^172\.(1[6-9]|2[0-9]|3[01])\.|^127\.|^0\.|^169\.254\." \
        "$TEMP_DIR/blocklist_final.txt" > "$TEMP_DIR/blocklist_filtered.txt" || true

    # Apply whitelist filter if configured
    if [ -n "$PF_WHITELIST_RANGES" ]; then
        log_info "Filtering whitelisted ranges"

        # Create whitelist file
        echo "$PF_WHITELIST_RANGES" | tr ' ' '\n' > "$TEMP_DIR/whitelist.txt"

        # Simple prefix matching for whitelist (faster than full CIDR overlap)
        local before=$(wc -l < "$TEMP_DIR/blocklist_filtered.txt" | tr -d ' ')

        # Filter out whitelist entries
        grep -vFf "$TEMP_DIR/whitelist.txt" "$TEMP_DIR/blocklist_filtered.txt" \
            > "$TEMP_DIR/blocklist_final.txt" || cp "$TEMP_DIR/blocklist_filtered.txt" "$TEMP_DIR/blocklist_final.txt"

        local after=$(wc -l < "$TEMP_DIR/blocklist_final.txt" | tr -d ' ')
        local removed=$((before - after))
        log_info "Removed $removed whitelisted entries (${before} -> ${after})"
    else
        mv "$TEMP_DIR/blocklist_filtered.txt" "$TEMP_DIR/blocklist_final.txt"
    fi

    local final_count=$(wc -l < "$TEMP_DIR/blocklist_final.txt" | tr -d ' ')
    log_info "Final blocklist: $final_count entries"

    if [ "$final_count" -eq 0 ]; then
        log_error "Final blocklist is empty"
        exit 1
    fi

    # Create minimal info file for IP mode
    echo "# IP mode blocklist (no ASN metadata)" > "$TEMP_DIR/info_final.txt"
    echo "# Generated: $(date)" >> "$TEMP_DIR/info_final.txt"
    echo "# Total entries: $final_count" >> "$TEMP_DIR/info_final.txt"

    log_info "IP mode processing complete"
}

#
# Main execution
#

# Backup existing blocklist
if [ -f "$BLOCKLIST_FILE" ]; then
    cp "$BLOCKLIST_FILE" "$BACKUP_FILE"
    log_info "Backed up existing blocklist to $BACKUP_FILE"
fi

# Backup existing info file
if [ -f "${BLOCKLIST_FILE}.info.txt" ]; then
    cp "${BLOCKLIST_FILE}.info.txt" "${BACKUP_FILE}.info.txt"
fi

# Download IP lists
download_ip_lists

# Process based on blocklist mode
if [ "$BLOCKLIST_MODE" = "asn" ]; then
    log_info "Using ASN mode (convert IPs to network ranges)"

    # Download and cache ip2asn database
    download_ip2asn

    # Find IP ranges for sample IPs
    find_ranges

    # Generate metadata for ranges
    create_metadata

    # Convert to CIDR
    convert_to_cidr

    # Filter whitelisted ranges
    filter_whitelist

    # Finalize blocklist (sort and split after whitelist filter)
    finalize_blocklist
else
    log_info "Using IP mode (direct IP blocking with /24 aggregation if needed)"

    # Process IP mode with aggregation
    process_ip_mode
fi

# Deploy new blocklist and info file
mv "$TEMP_DIR/blocklist_final.txt" "$BLOCKLIST_FILE"
mv "$TEMP_DIR/info_final.txt" "${BLOCKLIST_FILE}.info.txt"
log_info "Deployed to $BLOCKLIST_FILE and ${BLOCKLIST_FILE}.info.txt"

# CI mode: skip PF operations
if [ -n "$CI" ]; then
    log_info "CI mode: Blocklist generated successfully: $BLOCKLIST_FILE"
    log_info "CI mode: Skipping PF validation and reload"
    exit 0
fi

# Use apply-blocklist.sh to load the blocklist
log_info "Loading blocklist via apply-blocklist.sh"
if [ -f "$SCRIPT_DIR/apply-blocklist.sh" ]; then
    if "$SCRIPT_DIR/apply-blocklist.sh" --local-only --force; then
        log_info "Blocklist loaded successfully"
    else
        log_error "Failed to load blocklist"
        mv "$BACKUP_FILE" "$BLOCKLIST_FILE" 2>/dev/null || true
        exit 1
    fi
else
    log_warn "apply-blocklist.sh not found, using fallback method"
    log_info "Validating PF config"
    if ! pfctl -nvf "$PF_CONF" >/dev/null 2>&1; then
        log_error "PF config validation failed"
        mv "$BACKUP_FILE" "$BLOCKLIST_FILE" 2>/dev/null || true
        exit 1
    fi
    log_info "Reloading PF rules"
    pfctl -f "$PF_CONF"
    log_warn "Install apply-blocklist.sh for better table loading"
fi

log_info "Blocklist update complete"
