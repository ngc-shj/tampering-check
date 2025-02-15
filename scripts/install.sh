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
    mkdir -p "$CONFIG_DIR"
    chmod 750 "$CONFIG_DIR"
}

# Function: install_files
# Installs main script, systemd service, and example config.
install_files() {
    install -m 750 bin/tampering-check.sh "$INSTALL_DIR/"

    # Copy canonical service file template to the final service file
    cp systemd/tampering-check@.service.example systemd/tampering-check@.service

    # Check if /var/spool/postfix/maildrop exists; if not, remove it from ReadWritePaths in the service file.
    if [ ! -d "/var/spool/postfix/maildrop" ]; then
        echo "/var/spool/postfix/maildrop does not exist; removing from ReadWritePaths..."
        sed -i 's#/var/spool/postfix/maildrop##g' systemd/tampering-check@.service
    fi

    install -m 644 systemd/tampering-check@.service "$SYSTEMD_DIR/"
    if [ ! -f "$CONFIG_DIR/config.yml" ]; then
        install -m 640 config/config.yml.example "$CONFIG_DIR/config.yml"
    else
        print_status "$YELLOW" "Note: Existing config.yml found, not overwriting"
        install -m 640 config/config.yml.example "$CONFIG_DIR/config.yml.example"
    fi
}

# Function: configure_system
# Reloads systemd.
configure_system() {
    systemctl daemon-reload
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

