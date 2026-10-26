#!/bin/sh
# Provider Configuration Parser
# Parses providers.conf and downloads IPs per source

# Category definitions (asndrop removed - ASN-only, no IPs)
THREAT_INTEL="binarydefense blocklistde cinsscore cymru dshield emergingthreats feodo greensnow ipsum spamhaus stopforumspam threatfox"
MONITORING="betterstack checkly grafana hetrixtools newrelic nodeping ohdear pingdom sentry site24x7 statuscake updown uptimerobot uptrends"
SECURITY="imperva stormwall sucuri zscaler"
CRAWLERS="amazonbot anthropic applebot ccbot claudebot commoncrawl duckassistbot duckduckbot googlebot googlesc googleutf gptbot perplexitybot"

#
# Function: Get category for provider
# Usage: get_category "spamhaus"
# Returns: threat|monitor|security|crawler|unknown
#
get_category() {
    local provider="$1"

    if echo " $THREAT_INTEL " | grep -q " $provider "; then
        echo "threat"
    elif echo " $MONITORING " | grep -q " $provider "; then
        echo "monitor"
    elif echo " $SECURITY " | grep -q " $provider "; then
        echo "security"
    elif echo " $CRAWLERS " | grep -q " $provider "; then
        echo "crawler"
    else
        echo "unknown"
    fi
}

#
# Function: Extract IPs from JSON using jq
# Usage: extract_json_ips "content"
# Handles multiple JSON formats from different providers
#
extract_json_ips() {
    local content="$1"
    local result=""

    # Try AWS-style: prefixes[].ipv4Prefix or prefixes[].ip_prefix
    result=$(echo "$content" | jq -r '.prefixes[]?.ipv4Prefix // .prefixes[]?.ip_prefix' 2>/dev/null | grep -v '^null$' | grep -v '^$')
    [ -n "$result" ] && echo "$result" && return 0

    # Try simple string array: ["1.2.3.4", "5.6.7.8"]
    result=$(echo "$content" | jq -r '.[] | select(type == "string")' 2>/dev/null | grep -E '^[0-9]')
    [ -n "$result" ] && echo "$result" && return 0

    # Try object array: [{"ip":"1.2.3.4"}] or [{"prefix":"1.2.3.4/24"}]
    result=$(echo "$content" | jq -r '.[].ip // .[].prefix // .[].cidr' 2>/dev/null | grep -v '^null$' | grep -E '^[0-9]')
    [ -n "$result" ] && echo "$result" && return 0

    # Try nested arrays: {"ips": [...]} or {"ranges": [...]}
    result=$(echo "$content" | jq -r '.ips[]? // .ranges[]? // .cidrs[]?' 2>/dev/null | grep -v '^null$' | grep -E '^[0-9]')
    [ -n "$result" ] && echo "$result" && return 0

    # Try ASN format: {ranges: [{range_start, range_end, asn, ...}]}
    result=$(echo "$content" | jq -r '.ranges[]? | "\(.range_start)-\(.range_end)"' 2>/dev/null | grep -v '^null$' | grep -E '^[0-9]')
    [ -n "$result" ] && echo "$result" && return 0

    return 1
}

#
# Function: Extract IPs using regex (fallback when JSON parsing fails)
# Usage: extract_ips_regex "content"
# Extracts all IPv4 addresses and CIDR ranges from any text/JSON
#
extract_ips_regex() {
    local content="$1"

    # Regex for IPv4 with optional CIDR: 1.2.3.4 or 1.2.3.4/24
    echo "$content" | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?\b' | \
        # Validate octet ranges (0-255)
        awk -F'[./]' '{
            valid = 1;
            for (i = 1; i <= 4; i++) {
                if ($i < 0 || $i > 255) {
                    valid = 0;
                    break;
                }
            }
            # Validate CIDR prefix if present
            if (NF == 5 && ($5 < 0 || $5 > 32)) {
                valid = 0;
            }
            if (valid) print $0;
        }' | sort -u
}

#
# Function: Download provider IPs
# Usage: download_provider_ips "spamhaus" "https://..." "output_file"
# Returns: 0 on success, 1 on failure
#
download_provider_ips() {
    local name="$1"
    local url="$2"
    local output="$3"
    local timeout="${PF_PROVIDER_TIMEOUT:-30}"

    log_trace "Downloading $name from $url"

    # Download with timeout
    local content
    content=$(curl -sSL --max-time "$timeout" "$url" 2>/dev/null)

    if [ -z "$content" ]; then
        log_warn "Empty response from $name"
        return 1
    fi

    # Detect format and extract IPs
    local ips=""

    if echo "$url" | grep -q '\.json$'; then
        # JSON format - try jq first
        ips=$(extract_json_ips "$content")

        # If jq failed, fall back to regex extraction
        if [ -z "$ips" ]; then
            log_trace "$name: jq parsing failed, using regex fallback"
            ips=$(extract_ips_regex "$content")
        fi
    else
        # Plain text format - try line-by-line first
        ips=$(echo "$content" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$')

        # If no clean lines, use regex extraction
        if [ -z "$ips" ]; then
            ips=$(extract_ips_regex "$content")
        fi
    fi

    if [ -z "$ips" ]; then
        log_warn "No IPs extracted from $name"
        return 1
    fi

    # Write to output
    echo "$ips" > "$output"
    local count=$(wc -l < "$output" | tr -d ' ')
    log_trace "$name: $count IPs"

    return 0
}

#
# Function: Process providers.conf
# Usage: process_providers "providers.conf" "output_dir"
# Creates: output_dir/{category}_{name}.txt files
#
process_providers() {
    local providers_file="$1"
    local output_dir="$2"

    if [ ! -f "$providers_file" ]; then
        log_error "providers.conf not found: $providers_file"
        return 1
    fi

    mkdir -p "$output_dir"

    local processed=0
    local failed=0
    local skipped=0

    # Read providers.conf line by line
    while IFS='|' read -r name url flag1 flag2; do
        # Skip empty lines and comments
        [ -z "$name" ] && continue
        echo "$name" | grep -q '^#' && continue

        local category=$(get_category "$name")

        # Skip unknown categories
        if [ "$category" = "unknown" ]; then
            log_trace "Skipping $name (not in configured categories)"
            skipped=$((skipped + 1))
            continue
        fi

        local output_file="$output_dir/${category}_${name}.txt"

        if download_provider_ips "$name" "$url" "$output_file"; then
            processed=$((processed + 1))
        else
            failed=$((failed + 1))
            rm -f "$output_file"
        fi
    done < "$providers_file"

    log_info "Processed $processed providers, $failed failed, $skipped skipped"

    return 0
}

#
# Function: Get blocking rule for category
# Usage: get_block_rule "threat"
# Returns: in+out | in | out
#
get_block_rule() {
    local category="$1"

    case "$category" in
        threat|security|crawler)
            echo "in+out"
            ;;
        monitor)
            echo "in"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}
