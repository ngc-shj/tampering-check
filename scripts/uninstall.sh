#!/bin/bash
set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Function: print_status
print_status() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${NC}"
}

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    print_status "$RED" "Error: Please run as root"
    exit 1
fi

# Set paths
INSTALL_DIR="/usr/local/sbin"
SYSTEMD_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/tampering-check"

# Function: stop_services
# Stops and disables all tampering-check services.
stop_services() {
    print_status "$GREEN" "Stopping all tampering-check services..."
    systemctl stop tampering-check@*.service 2>/dev/null || true
    systemctl disable tampering-check@*.service 2>/dev/null || true
}

# Function: remove_files
# Removes installed files.
remove_files() {
    rm -f "$INSTALL_DIR/tampering-check.sh"
    rm -f "$SYSTEMD_DIR/tampering-check@.service"
}

# Function: cleanup_directories
# Cleans up directories, asking the user if configuration should be preserved.
cleanup_directories() {
    local preserve_config=0
    read -p "Do you want to preserve configuration? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        preserve_config=1
    fi
    if [ "$preserve_config" -eq 0 ]; then
        rm -rf "$CONFIG_DIR"
    else
        print_status "$YELLOW" "Preserving configuration in $CONFIG_DIR"
    fi
}

# Main uninstallation flow
main() {
    print_status "$GREEN" "Starting tampering-check uninstallation..."
    print_status "$GREEN" "Stopping services..."
    stop_services
    print_status "$GREEN" "Removing files..."
    remove_files
    print_status "$GREEN" "Cleaning up directories..."
    cleanup_directories
    systemctl daemon-reload
    print_status "$GREEN" "Uninstallation completed successfully!"
}

main "$@"

