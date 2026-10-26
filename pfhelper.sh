#!/bin/sh
# PF Helper - Unified blocklist management
# Usage: pfhelper.sh [--install|--update|--purge]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export APPNAME="pfhelper"

# Source libraries
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/parse-providers.sh"

# Load environment
load_env "$SCRIPT_DIR/.env"

# File paths
PROVIDERS_CONF="$SCRIPT_DIR/providers.conf"
TABLES_DIR="$SCRIPT_DIR/output/tables"
BLOCKLIST_FILE="$SCRIPT_DIR/output/blocklist"
BLOCKLIST_INFO="$SCRIPT_DIR/output/blocklist.info.txt"
TEMPLATE="$SCRIPT_DIR/pf.conf.template"
OUTPUT="${PF_OUTPUT_FILE:-/etc/pf.conf}"

#
# Show usage
#
show_usage() {
    cat <<EOF
Usage: $0 [COMMAND]

Commands:
  --install    Complete setup: download lists, generate config, load tables
  --update     Update workflow: re-download lists, reload tables (no config)
  --purge      Remove all provider tables from PF

Examples:
  doas $0 --install    # Initial setup or full refresh
  doas $0 --update     # Weekly table updates
  doas $0 --purge      # Clear all tables

Environment:
  Configuration loaded from: $SCRIPT_DIR/.env
  PF config output: $OUTPUT
  Provider tables: $TABLES_DIR/
EOF
}

#
# Download providers.conf
#
download_providers_conf() {
    local url="${PF_PROVIDERS_CONF_URL:-https://raw.githubusercontent.com/nikescar/cdn-lookup/main/providers.conf}"
    local max_age=$(( ${PF_PROVIDERS_CACHE_DAYS:-7} * 86400 ))
    local needs_download=1

    if [ -f "$PROVIDERS_CONF" ]; then
        local cache_age=$(( $(date +%s) - $(stat -f %m "$PROVIDERS_CONF" 2>/dev/null || stat -c %Y "$PROVIDERS_CONF" 2>/dev/null) ))
        if [ $cache_age -le $max_age ]; then
            needs_download=0
            local days_old=$(( cache_age / 86400 ))
            log_info "Using cached providers.conf (${days_old} days old)"
        fi
    fi

    if [ $needs_download -eq 1 ]; then
        log_info "Downloading providers.conf"
        if download_file "$url" "$PROVIDERS_CONF.tmp"; then
            mv "$PROVIDERS_CONF.tmp" "$PROVIDERS_CONF"
            local count=$(grep -cv '^#\|^$' "$PROVIDERS_CONF" || echo 0)
            log_info "Downloaded $count provider entries"
        else
            log_error "Failed to download providers.conf"
            exit 1
        fi
    fi
}

#
# Generate blocklists from providers
#
generate_blocklists() {
    log_info "Generating blocklists from providers"

    require_command jq curl

    ensure_dir "$TABLES_DIR"

    # Backup existing blocklist
    backup_file "$BLOCKLIST_FILE"
    backup_file "$BLOCKLIST_INFO"

    # Process all providers
    if ! process_providers "$PROVIDERS_CONF" "$TABLES_DIR"; then
        log_error "Failed to process providers"
        exit 1
    fi

    # Generate aggregated blocklist
    log_info "Generating aggregated blocklist"

    cat "$TABLES_DIR"/*.txt 2>/dev/null | \
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$' | \
        sort -u > "$BLOCKLIST_FILE.tmp"

    local total=$(wc -l < "$BLOCKLIST_FILE.tmp" | tr -d ' ')

    if [ "$total" -eq 0 ]; then
        log_warn "Aggregated blocklist is empty"
        rm -f "$BLOCKLIST_FILE.tmp"
        return 1
    fi

    mv "$BLOCKLIST_FILE.tmp" "$BLOCKLIST_FILE"
    log_info "Aggregated blocklist: $total entries"

    # Generate info file
    {
        echo "# PF Blocklist Info - Provider-based"
        echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "# Total entries: $total"
        echo ""
        echo "## Per-category breakdown:"

        for category in threat monitor security crawler; do
            local cat_files=$(find "$TABLES_DIR" -name "${category}_*.txt" 2>/dev/null | wc -l | tr -d ' ')
            local cat_ips=$(cat "$TABLES_DIR/${category}"_*.txt 2>/dev/null | wc -l | tr -d ' ')
            echo "  - $category: $cat_files sources, $cat_ips IPs"
        done

        echo ""
        echo "## Per-source details:"
        find "$TABLES_DIR" -name "*.txt" -type f | sort | while read -r file; do
            local basename=$(basename "$file" .txt)
            local count=$(wc -l < "$file" | tr -d ' ')
            printf "  - %-40s %8d IPs\n" "$basename" "$count"
        done
    } > "$BLOCKLIST_INFO"

    log_info "Blocklist generation complete"
}

#
# Generate PF config from template
#
generate_pf_config() {
    log_info "Generating PF configuration"

    if [ ! -f "$TEMPLATE" ]; then
        log_error "Template not found: $TEMPLATE"
        exit 1
    fi

    # Backup existing config
    backup_file "$OUTPUT"

    # Determine mode
    local mode
    if [ "${PF_LAN_ENABLED:-0}" -eq 1 ]; then
        mode="WITH_LAN"
        log_info "Mode: Router (ISP + LAN)"
    else
        mode="NO_LAN"
        log_info "Mode: Single interface (ISP only)"
    fi

    # Generate config
    local tmp_file=$(mktemp)
    cp "$TEMPLATE" "$tmp_file"

    # Replace interface placeholders
    sed -i "s|PF_ISP_INTERFACE|$PF_ISP_INTERFACE|g" "$tmp_file"
    sed -i "s|PF_LAN_INTERFACE|$PF_LAN_INTERFACE|g" "$tmp_file"

    # Replace security rule placeholders
    sed -i "s|PF_MAX_MSS|${PF_MAX_MSS:-1440}|g" "$tmp_file"
    sed -i "s|PF_CONNLIMIT_PER_IP|${PF_CONNLIMIT_PER_IP:-100}|g" "$tmp_file"
    sed -i "s|PF_UDP_RATE_LIMIT|${PF_UDP_RATE_LIMIT:-256}|g" "$tmp_file"
    sed -i "s|PF_SCANNER_CONN_RATE|${PF_SCANNER_CONN_RATE:-15}|g" "$tmp_file"

    # Remove LAN sections if disabled
    if [ "$mode" = "NO_LAN" ]; then
        sed -i '/^### LAN_START ###/,/^### LAN_END ###/d' "$tmp_file"
        sed -i '/^### NO_LAN_START ###/d' "$tmp_file"
        sed -i '/^### NO_LAN_END ###/d' "$tmp_file"
        sed -i 's/^#\(antispoof quick for { lo }\)/\1/' "$tmp_file"
        sed -i 's/^#\(pass out on \$isp proto { tcp udp icmp }\)/\1/' "$tmp_file"
    else
        sed -i '/^### NO_LAN_START ###/,/^### NO_LAN_END ###/d' "$tmp_file"
        sed -i '/^### LAN_START ###/d' "$tmp_file"
        sed -i '/^### LAN_END ###/d' "$tmp_file"
    fi

    # Remove disabled security sections
    [ "${PF_LIMIT_MSS:-0}" -eq 0 ] && \
        sed -i '/^### SEC_MSS_START ###/,/^### SEC_MSS_END ###/d' "$tmp_file"

    [ "${PF_DROP_INVALID_STATE:-0}" -eq 0 ] && \
        sed -i '/^### SEC_STATE_START ###/,/^### SEC_STATE_END ###/d' "$tmp_file"

    [ "${PF_DROP_NON_SYN:-0}" -eq 0 ] && \
        sed -i '/^### SEC_NONSYN_START ###/,/^### SEC_NONSYN_END ###/d' "$tmp_file"

    [ "${PF_CONNLIMIT_PER_IP:-0}" -eq 0 ] && \
        sed -i '/^### SEC_CONNLIMIT_START ###/,/^### SEC_CONNLIMIT_END ###/d' "$tmp_file"

    [ "${PF_GUARD_UDP_FLOOD:-0}" -eq 0 ] && \
        sed -i '/^### SEC_UDP_FLOOD_START ###/,/^### SEC_UDP_FLOOD_END ###/d' "$tmp_file"

    [ "${PF_GUARD_PORT_SCANNER:-0}" -eq 0 ] && \
        sed -i '/^### SEC_SCANNER_START ###/,/^### SEC_SCANNER_END ###/d' "$tmp_file"

    # Remove all remaining security markers
    sed -i '/^### SEC_.*_START ###/d' "$tmp_file"
    sed -i '/^### SEC_.*_END ###/d' "$tmp_file"

    # Write output
    mv "$tmp_file" "$OUTPUT"

    # Validate
    log_info "Validating configuration syntax"
    if ! pfctl -nf "$OUTPUT" >/dev/null 2>&1; then
        log_error "Syntax validation failed"
        pfctl -nf "$OUTPUT" 2>&1 | grep -i error
        [ -f "$OUTPUT.bak" ] && mv "$OUTPUT.bak" "$OUTPUT"
        exit 1
    fi

    log_info "Configuration generated: $OUTPUT"
}

#
# Apply PF configuration
#
apply_pf_config() {
    log_info "Applying PF configuration"

    if pfctl -f "$OUTPUT" 2>&1; then
        log_info "Configuration applied successfully"
    else
        log_error "Failed to apply configuration"
        [ -f "$OUTPUT.bak" ] && mv "$OUTPUT.bak" "$OUTPUT"
        exit 1
    fi
}

#
# Load all provider tables into PF
#
load_provider_tables() {
    log_info "Loading provider tables"

    if [ ! -d "$TABLES_DIR" ]; then
        log_error "Tables directory not found: $TABLES_DIR"
        log_error "Run: $0 --update to generate tables"
        exit 1
    fi

    local table_files=$(find "$TABLES_DIR" -name "*.txt" -type f | sort)

    if [ -z "$table_files" ]; then
        log_error "No table files found in $TABLES_DIR"
        exit 1
    fi

    local loaded=0
    local failed=0
    local total_entries=0

    for file in $table_files; do
        local table_name=$(basename "$file" .txt)
        local entry_count=$(wc -l < "$file" | tr -d ' ')

        # Skip empty tables
        if [ "$entry_count" -eq 0 ]; then
            log_warn "Skipping empty table: $table_name"
            continue
        fi

        # Load table into PF
        if pfctl -t "$table_name" -T replace -f "$file" >/dev/null 2>&1; then
            log_info "Loaded $table_name: $entry_count entries"
            loaded=$((loaded + 1))
            total_entries=$((total_entries + entry_count))
        else
            log_error "Failed to load table: $table_name"
            failed=$((failed + 1))
        fi
    done

    log_info "Table loading complete"
    log_info "Loaded: $loaded tables, $total_entries total entries"
    log_info "Failed: $failed tables"

    if [ $failed -gt 0 ]; then
        log_warn "Some tables failed to load"
        exit 1
    fi
}

#
# Purge all provider tables from PF
#
purge_provider_tables() {
    log_info "Purging all provider tables"

    local active_tables=$(pfctl -sTables 2>/dev/null | grep -E "^(threat_|monitor_|sec_|crawler_)")

    if [ -z "$active_tables" ]; then
        log_info "No provider tables found in PF"
        return 0
    fi

    local table_count=$(echo "$active_tables" | wc -l | tr -d ' ')
    log_info "Found $table_count provider tables to purge"

    local purged=0
    echo "$active_tables" | while read -r table_name; do
        if pfctl -t "$table_name" -T flush >/dev/null 2>&1; then
            log_info "Flushed table: $table_name"
            purged=$((purged + 1))
        else
            log_error "Failed to flush table: $table_name"
        fi
    done

    log_info "Purge complete: $table_count tables flushed"
}

#
# Command: --install (complete setup)
#
cmd_install() {
    require_root

    log_info "=== PF Installation ==="
    log_info "ISP interface: $PF_ISP_INTERFACE"
    log_info "LAN interface: $PF_LAN_INTERFACE"
    log_info "LAN enabled: ${PF_LAN_ENABLED:-0}"

    # Step 1: Download providers
    download_providers_conf

    # Step 2: Generate blocklists
    generate_blocklists

    # Step 3: Generate PF config
    generate_pf_config

    # Step 4: Apply PF config
    apply_pf_config

    # Step 5: Load tables
    load_provider_tables

    log_info "=== Installation Complete ==="
    log_info "PF config: $OUTPUT"
    log_info "Provider tables: $TABLES_DIR/"
    log_info ""
    log_info "Verify with:"
    log_info "  pfctl -sr | grep threat_"
    log_info "  pfctl -sTables | grep -c '^threat_'"
}

#
# Command: --update (update blocklists and tables)
#
cmd_update() {
    require_root

    log_info "=== PF Update ==="

    # Step 1: Download providers
    download_providers_conf

    # Step 2: Generate blocklists
    generate_blocklists

    # Step 3: Reload tables (no config generation)
    load_provider_tables

    log_info "=== Update Complete ==="
    log_info "Provider tables reloaded from: $TABLES_DIR/"
}

#
# Command: --purge (remove all tables)
#
cmd_purge() {
    require_root

    log_info "=== PF Purge ==="

    purge_provider_tables

    log_info "=== Purge Complete ==="
}

#
# Main
#
main() {
    case "${1:-}" in
        --install)
            cmd_install
            ;;
        --update)
            cmd_update
            ;;
        --purge)
            cmd_purge
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
