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

    # Normalize architecture (bidirectional: x86_64 ↔ amd64, aarch64 ↔ arm64)
    local arch_alt=""
    case "$arch1" in
        x86_64) arch_alt="amd64" ;;
        amd64) arch_alt="x86_64" ;;
        aarch64) arch_alt="arm64" ;;
        arm64) arch_alt="aarch64" ;;
        *) arch_alt="$arch1" ;;
    esac

    # Get assets filtered by architecture from jq (try both arch1 and arch_alt)
    # This mirrors the working example's approach
    local asset_urls=$(eval "${curl_cmd}" "${api_url}" | \
        jq -r '.assets[] | select(.name | contains("'${arch1}'") or contains("'${arch_alt}'")) | .browser_download_url' 2>/dev/null)

    if [ -z "$asset_urls" ]; then
        log_warn "No assets found matching arch: $arch1 or $arch_alt"
        return 1
    fi

    # Convert to lowercase for matching
    local prefix_lower=$(echo "$file_prefix" | tr '[:upper:]' '[:lower:]')
    local postfix_lower=$(echo "$file_postfix" | tr '[:upper:]' '[:lower:]')

    # Try matching strategies (mirrors working example)
    local download_url=""

    # Strategy 1: prefix AND postfix
    download_url=$(echo "$asset_urls" | while IFS= read -r url; do
        url_lower=$(echo "$url" | tr '[:upper:]' '[:lower:]')
        if echo "$url_lower" | grep -q "${prefix_lower}"; then
            if [ -n "$postfix_lower" ] && echo "$url_lower" | grep -q "${postfix_lower}"; then
                echo "$url"
                break
            fi
        fi
    done | head -1)

    # Strategy 2: prefix AND linux
    if [ -z "$download_url" ]; then
        download_url=$(echo "$asset_urls" | while IFS= read -r url; do
            url_lower=$(echo "$url" | tr '[:upper:]' '[:lower:]')
            if echo "$url_lower" | grep -q "${prefix_lower}" && \
               echo "$url_lower" | grep -q "linux"; then
                echo "$url"
                break
            fi
        done | head -1)
    fi

    # Strategy 3: arch AND postfix
    if [ -z "$download_url" ] && [ -n "$postfix_lower" ]; then
        download_url=$(echo "$asset_urls" | while IFS= read -r url; do
            url_lower=$(echo "$url" | tr '[:upper:]' '[:lower:]')
            if echo "$url_lower" | grep -q "${postfix_lower}"; then
                echo "$url"
                break
            fi
        done | head -1)
    fi

    # Strategy 4: just take first matching arch
    if [ -z "$download_url" ]; then
        download_url=$(echo "$asset_urls" | head -1)
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
