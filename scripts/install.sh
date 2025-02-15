#!/bin/bash
set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Function: print_status
# Prints messages with color.
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
LOGROTATE_DIR="/etc/logrotate.d"
LOG_DIR="/var/log/tampering-check"
CONFIG_DIR="/etc/tampering-check"

# Function: check_dependencies
# Ensures required packages are installed.
check_dependencies() {
    local missing_deps=()
    if ! command -v inotifywait >/dev/null 2>&1; then
        missing_deps+=("inotify-tools")
    fi
    if ! command -v sha256sum >/dev/null 2>&1; then
        missing_deps+=("coreutils")
    fi
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_status "$RED" "Error: Missing dependencies: ${missing_deps[*]}"
        print_status "$YELLOW" "Please install them using your package manager"
        exit 1
    fi
}

# Function: create_directories
# Creates necessary directories with proper permissions.
create_directories() {
    mkdir -p "$LOG_DIR" "$CONFIG_DIR"
    chmod 750 "$LOG_DIR" "$CONFIG_DIR"
}

# Function: install_files
# Installs main script, systemd service, logrotate configuration, and example config.
install_files() {
    install -m 750 bin/tampering-check.sh "$INSTALL_DIR/"
    install -m 644 systemd/tampering-check@.service "$SYSTEMD_DIR/"
    install -m 644 config/logrotate.d/tampering-check "$LOGROTATE_DIR/"
    if [ ! -f "$CONFIG_DIR/config.yml" ]; then
        install -m 640 config/config.yml.example "$CONFIG_DIR/config.yml"
    else
        print_status "$YELLOW" "Note: Existing config.yml found, not overwriting"
        install -m 640 config/config.yml.example "$CONFIG_DIR/config.yml.example"
    fi
}

# Function: configure_system
# Reloads systemd and sets up log files.
configure_system() {
    systemctl daemon-reload
    touch "$LOG_DIR/install.log"
    chmod 640 "$LOG_DIR/install.log"
}

# Main installation flow
main() {
    print_status "$GREEN" "Starting tampering-check installation..."
    print_status "$GREEN" "Checking dependencies..."
    check_dependencies
    print_status "$GREEN" "Creating directories..."
    create_directories
    print_status "$GREEN" "Installing files..."
    install_files
    print_status "$GREEN" "Configuring system..."
    configure_system
    print_status "$GREEN" "Installation completed successfully!"
    print_status "$GREEN" "Use 'systemctl enable tampering-check@directory.service' to enable monitoring"
}

main "$@"

