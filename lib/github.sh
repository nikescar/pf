#!/bin/sh
# GitHub Release Download Functions
# Sourced by scripts needing to download GitHub releases

#
# Trim whitespace from string
# Usage: _trim_string "  text  "
#
_trim_string() {
    echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

#
# Download latest release from GitHub repository
# Usage: download_github_release "owner/repo" "file-pattern*.tar.gz" [arch1] [arch2]
# Example: download_github_release "nikescar/cdn-lookup" "cdn-lookup*"
#
# Downloads to $DOWNLOAD_DIR (must be set by caller)
# Returns: 0 on success, 1 on failure
#
download_github_release() {
    local repo="$1"
    local file_pattern="$2"
    local arch1="${3:-$(uname -m)}"
    local arch2="${4:-$(uname -m)}"

    if [ "$(echo "$repo" | grep -c "/")" != 1 ]; then
        log_error "Invalid repo format. Expected: owner/repo"
        return 1
    fi

    if [ -z "$DOWNLOAD_DIR" ]; then
        log_error "DOWNLOAD_DIR not set"
        return 1
    fi

    local api_url="https://api.github.com/repos/$(_trim_string "$repo")/releases/latest"

    # Parse file pattern into prefix and postfix
    IFS='*' read -r file_prefix file_postfix <<EOF
$(_trim_string "$file_pattern")
EOF
    file_prefix=$(_trim_string "$file_prefix")
    file_postfix=$(_trim_string "$file_postfix")

    # Use GitHub token if available
    local curl_cmd="curl -sSL"
    if [ -n "${GITHUB_TOKEN}" ]; then
        curl_cmd="curl -sSL -H \"Authorization: Bearer ${GITHUB_TOKEN}\""
        log_trace "Using GitHub token for API request"
    fi

    # Get ALL assets first (without architecture filtering)
    local all_assets=$(eval "${curl_cmd}" "${api_url}" | \
        jq -r '.assets[].browser_download_url' 2>/dev/null)

    if [ -z "$all_assets" ]; then
        log_warn "No assets found for $repo"
        return 1
    fi

    # Try architecture-specific filtering first
    local asset_list=$(echo "$all_assets" | while IFS= read -r url; do
        local name=$(basename "$url" | tr '[:upper:]' '[:lower:]')
        local arch1_lower=$(echo "$arch1" | tr '[:upper:]' '[:lower:]')
        local arch2_lower=$(echo "$arch2" | tr '[:upper:]' '[:lower:]')
        if echo "$name" | grep -qE "${arch1_lower}|${arch2_lower}"; then
            echo "$url"
        fi
    done)

    # If no arch-specific assets, use all assets
    if [ -z "$asset_list" ]; then
        log_trace "No arch-specific assets, trying all assets"
        asset_list="$all_assets"
    fi

    # Detect OS and normalize arch
    local os_name=$(uname -s | tr '[:upper:]' '[:lower:]')
    local arch_normalized="$arch1"
    case "$arch1" in
        x86_64) arch_normalized="amd64" ;;
        aarch64) arch_normalized="arm64" ;;
    esac

    # Try matching strategies in order of preference
    local download_url=""

    # Strategy 1: OS + arch + prefix (e.g., openbsd-amd64-cdn-lookup)
    download_url=$(echo "$asset_list" | while IFS= read -r url; do
        url_lower=$(echo "$url" | tr '[:upper:]' '[:lower:]')
        prefix_lower=$(echo "$file_prefix" | tr '[:upper:]' '[:lower:]')
        if echo "$url_lower" | grep -qE "${os_name}.*(${arch1}|${arch_normalized})|${prefix_lower}"; then
            # Filter out wrong OS (android, darwin, windows)
            if ! echo "$url_lower" | grep -qE "android|darwin|windows|macos"; then
                echo "$url"
                break
            fi
        fi
    done)

    # Strategy 2: prefix + BSD
    if [ -z "$download_url" ]; then
        download_url=$(echo "$asset_list" | while IFS= read -r url; do
            url_lower=$(echo "$url" | tr '[:upper:]' '[:lower:]')
            prefix_lower=$(echo "$file_prefix" | tr '[:upper:]' '[:lower:]')
            if echo "$url_lower" | grep -q "${prefix_lower}" && echo "$url_lower" | grep -qE "bsd"; then
                if ! echo "$url_lower" | grep -q "android"; then
                    echo "$url"
                    break
                fi
            fi
        done)
    fi

    # Strategy 3: prefix + arch (any OS)
    if [ -z "$download_url" ]; then
        download_url=$(echo "$asset_list" | while IFS= read -r url; do
            url_lower=$(echo "$url" | tr '[:upper:]' '[:lower:]')
            prefix_lower=$(echo "$file_prefix" | tr '[:upper:]' '[:lower:]')
            if echo "$url_lower" | grep -q "${prefix_lower}" && echo "$url_lower" | grep -qE "${arch1}|${arch_normalized}"; then
                if ! echo "$url_lower" | grep -qE "android|arm"; then
                    echo "$url"
                    break
                fi
            fi
        done)
    fi

    # Strategy 4: just prefix + linux
    if [ -z "$download_url" ]; then
        download_url=$(echo "$asset_list" | while IFS= read -r url; do
            url_lower=$(echo "$url" | tr '[:upper:]' '[:lower:]')
            prefix_lower=$(echo "$file_prefix" | tr '[:upper:]' '[:lower:]')
            if echo "$url_lower" | grep -q "${prefix_lower}" && echo "$url_lower" | grep -q "linux"; then
                if ! echo "$url_lower" | grep -qE "android|arm"; then
                    echo "$url"
                    break
                fi
            fi
        done)
    fi

    if [ -z "$download_url" ]; then
        log_error "No matching asset found for $file_pattern (arch: $arch1/$arch2)"
        return 1
    fi

    # Download
    log_trace "Downloading from: $download_url"
    if wget --directory-prefix="$DOWNLOAD_DIR" "$download_url" 2>/dev/null; then
        log_trace "Downloaded successfully"
        return 0
    else
        log_error "Download failed: $download_url"
        return 1
    fi
}
