#!/bin/bash
#
# Frida iOS deb builder
# Builds patched frida-server deb packages for iOS
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${ROOT_DIR}/build"
DIST_DIR="${ROOT_DIR}/dist"
TEMPLATE_DIR="${ROOT_DIR}/templates/deb"
HEXREPLACE="${BUILD_DIR}/hexreplace"

# Default values
DEFAULT_PORT=8899

# Colors (optional, for local runs)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -v, --version VERSION   Frida version (e.g., 16.5.2) or 'latest'"
    echo "  -n, --name NAME         Custom name (5 lowercase letters, e.g., abcde)"
    echo "  -p, --port PORT         Server port (default: $DEFAULT_PORT)"
    echo "  -h, --help              Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 -v latest -n abcde -p 9999"
    echo "  $0 -v 16.5.2 -n xyzab"
    exit 1
}

# Generate random 5-letter name
generate_random_name() {
    head -c 100 /dev/urandom | LC_ALL=C tr -dc 'a-z' | head -c 5
}

# Get latest Frida version from GitHub
get_latest_version() {
    curl -s "https://api.github.com/repos/frida/frida/releases/latest" | \
        grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'
}

# Download Frida deb
download_frida_deb() {
    local version=$1
    local arch=$2
    local output=$3

    local url="https://github.com/frida/frida/releases/download/${version}/frida_${version}_iphoneos-${arch}.deb"
    log_info "Downloading: $url"

    curl -L -f -o "$output" "$url" || {
        log_error "Failed to download $url"
        return 1
    }

    log_info "Downloaded: $output"
}

# Build hexreplace tool
build_hexreplace() {
    log_info "Building hexreplace..."
    cd "${ROOT_DIR}/hexreplace"
    go build -o "$HEXREPLACE" .
    chmod +x "$HEXREPLACE"
    log_info "hexreplace built: $HEXREPLACE"
}

# Extract deb package
extract_deb() {
    local deb_file=$1
    local extract_dir=$2

    log_info "Extracting: $deb_file"
    mkdir -p "$extract_dir"
    dpkg-deb -R "$deb_file" "$extract_dir"
}

# Patch frida-server binary
patch_binary() {
    local input=$1
    local output=$2
    local name=$3

    log_info "Patching binary: $input -> $output"
    "$HEXREPLACE" "$input" "$name" "$output"
}

# Create patched deb package
create_deb() {
    local version=$1
    local arch=$2
    local name=$3
    local port=$4

    local original_deb="${BUILD_DIR}/frida_${version}_iphoneos-${arch}.deb"
    local extract_dir="${BUILD_DIR}/extract_${arch}"
    local output_deb="${DIST_DIR}/${name}_${version}_iphoneos-${arch}.deb"

    # Determine paths based on architecture (rootless for arm64)
    local server_path="/usr/sbin"
    local launch_daemon_path="/Library/LaunchDaemons"
    local lib_path="/usr/lib"

    if [ "$arch" = "arm64" ]; then
        server_path="/var/jb/usr/sbin"
        launch_daemon_path="/var/jb/Library/LaunchDaemons"
        lib_path="/var/jb/usr/lib"
    fi

    # Clean and extract
    rm -rf "$extract_dir"
    extract_deb "$original_deb" "$extract_dir"

    # Find and patch frida-server
    local server_file
    if [ "$arch" = "arm64" ]; then
        server_file="${extract_dir}/var/jb/usr/sbin/frida-server"
    else
        server_file="${extract_dir}/usr/sbin/frida-server"
    fi

    if [ -f "$server_file" ]; then
        local patched_server="${server_file%frida-server}${name}"
        patch_binary "$server_file" "$patched_server" "$name"
        rm -f "$server_file"
        chmod 755 "$patched_server"
    else
        log_error "frida-server not found: $server_file"
        return 1
    fi

    # Find and patch frida-agent.dylib
    local agent_file
    if [ "$arch" = "arm64" ]; then
        agent_file="${extract_dir}/var/jb/usr/lib/frida/frida-agent.dylib"
    else
        agent_file="${extract_dir}/usr/lib/frida/frida-agent.dylib"
    fi

    if [ -f "$agent_file" ]; then
        local agent_dir=$(dirname "$agent_file")
        local new_agent_dir="${agent_dir%frida}${name}"
        mkdir -p "$new_agent_dir"

        local patched_agent="${new_agent_dir}/${name}-agent.dylib"
        patch_binary "$agent_file" "$patched_agent" "$name"
        rm -rf "$agent_dir"
        chmod 755 "$patched_agent"
    fi

    # Update DEBIAN/control
    local control_file="${extract_dir}/DEBIAN/control"
    sed -i.bak "s/re\.frida\.server/re.${name}.server/g" "$control_file"
    rm -f "${control_file}.bak"

    # Update DEBIAN/extrainst_
    local extrainst_file="${extract_dir}/DEBIAN/extrainst_"
    if [ -f "$extrainst_file" ]; then
        sed -i.bak "s/re\.frida\.server/re.${name}.server/g" "$extrainst_file"
        rm -f "${extrainst_file}.bak"
        chmod 755 "$extrainst_file"
    fi

    # Update DEBIAN/prerm
    local prerm_file="${extract_dir}/DEBIAN/prerm"
    if [ -f "$prerm_file" ]; then
        sed -i.bak "s/re\.frida\.server/re.${name}.server/g" "$prerm_file"
        rm -f "${prerm_file}.bak"
        chmod 755 "$prerm_file"
    fi

    # Update LaunchDaemon plist
    local plist_file="${extract_dir}${launch_daemon_path}/re.frida.server.plist"
    local new_plist_file="${extract_dir}${launch_daemon_path}/re.${name}.server.plist"

    if [ -f "$plist_file" ]; then
        # Replace frida references
        sed -i.bak \
            -e "s/re\.frida\.server/re.${name}.server/g" \
            -e "s/frida-server/${name}/g" \
            -e "s|/frida/|/${name}/|g" \
            "$plist_file"

        # Add port configuration
        sed -i.bak 's|</array>|\t<string>-l</string>\n\t\t<string>0.0.0.0:'"${port}"'</string>\n\t</array>|g' "$plist_file"

        rm -f "${plist_file}.bak"
        mv "$plist_file" "$new_plist_file"
    fi

    # Remove .DS_Store files
    find "$extract_dir" -name ".DS_Store" -delete

    # Build deb
    log_info "Building deb: $output_deb"
    dpkg-deb -b "$extract_dir" "$output_deb"

    log_info "Created: $output_deb"

    # Cleanup
    rm -rf "$extract_dir"
}

# Main
main() {
    local version=""
    local name=""
    local port="$DEFAULT_PORT"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--version)
                version="$2"
                shift 2
                ;;
            -n|--name)
                name="$2"
                shift 2
                ;;
            -p|--port)
                port="$2"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done

    # Validate version
    if [ -z "$version" ]; then
        log_error "Version is required"
        usage
    fi

    if [ "$version" = "latest" ]; then
        version=$(get_latest_version)
        log_info "Latest version: $version"
    fi

    # Validate/generate name
    if [ -z "$name" ]; then
        name=$(generate_random_name)
        log_info "Generated random name: $name"
    fi

    if [[ ! "$name" =~ ^[a-z]{5}$ ]]; then
        log_error "Name must be exactly 5 lowercase letters (a-z)"
        exit 1
    fi

    # Validate port
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
        log_error "Port must be a number between 1024 and 65535"
        exit 1
    fi

    log_info "========================================="
    log_info "Frida iOS deb builder"
    log_info "========================================="
    log_info "Version: $version"
    log_info "Name:    $name"
    log_info "Port:    $port"
    log_info "========================================="

    # Create directories
    mkdir -p "$BUILD_DIR" "$DIST_DIR"

    # Build hexreplace
    build_hexreplace

    # Process each architecture
    for arch in arm arm64; do
        log_info ""
        log_info "Processing architecture: $arch"
        log_info "-----------------------------------------"

        local deb_file="${BUILD_DIR}/frida_${version}_iphoneos-${arch}.deb"

        # Download if not exists
        if [ ! -f "$deb_file" ]; then
            download_frida_deb "$version" "$arch" "$deb_file" || {
                log_warn "Failed to download $arch version, skipping..."
                continue
            }
        fi

        # Create patched deb
        create_deb "$version" "$arch" "$name" "$port"
    done

    log_info ""
    log_info "========================================="
    log_info "Build complete!"
    log_info "Output directory: $DIST_DIR"
    log_info "========================================="
    ls -la "$DIST_DIR"
}

main "$@"
