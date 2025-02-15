#!/bin/bash
set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# To enable debug output, set the DEBUG_ENABLED environment variable (e.g., export DEBUG_ENABLED=1).
# If DEBUG_ENABLED is not defined, debug output is suppressed.

# Test directory and file settings
TEST_DIR="/tmp/tampering-check-test"
LOG_DIR="/var/log/tampering-check"
# Align with tampering-check.sh SERVICE_ID generation (slashes replaced/removed)
TEST_LOG_FILE="${LOG_DIR}/tmp_tampering-check-test.log"
CONFIG_DIR="/etc/tampering-check"
CONFIG_FILE="${CONFIG_DIR}/config.yml"
PID_FILE="/tmp/tampering-check-test.pid"

# Test result counters
TESTS_TOTAL=0
TESTS_PASSED=0
TESTS_FAILED=0

# Print debug message with timestamp only if DEBUG_ENABLED is set
debug() {
    if [ -n "${DEBUG_ENABLED+x}" ]; then
        printf "[%s] DEBUG: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
    fi
}

# Print test result and update counters
print_result() {
    local test_name="$1"
    local result="$2"
    if [ "$result" -eq 0 ]; then
        printf "${GREEN}✓ %s${NC}\n" "$test_name"
    else
        printf "${RED}✗ %s${NC}\n" "$test_name"
    fi
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    TESTS_PASSED=$((TESTS_PASSED + (1 - result)))
    TESTS_FAILED=$((TESTS_FAILED + result))
}

# Set up the test environment
setup() {
    debug "Setting up test environment"
    sudo mkdir -p "$TEST_DIR" "$LOG_DIR" "$CONFIG_DIR"
    sudo chmod 750 "$LOG_DIR" "$CONFIG_DIR"
    sudo rm -f "$TEST_LOG_FILE"
    sudo touch "$TEST_LOG_FILE"
    sudo chmod 640 "$TEST_LOG_FILE"
    create_test_config
    debug "Test environment setup complete"
}

# Create the test configuration file
create_test_config() {
    debug "Creating test configuration"
    cat << 'EOF' | sudo tee "$CONFIG_FILE" > /dev/null
general:
  check_interval: 5
  hash_algorithm: sha256
  enable_alerts: true

directories:
  - path: /tmp/tampering-check-test
    recursive: true
    priority: high

notifications:
  syslog:
    enabled: true
    facility: auth
    min_priority: notice

logging:
  level: debug
EOF
    sudo chmod 640 "$CONFIG_FILE"
    debug "Configuration file created at $CONFIG_FILE"
}

# Clean up the test environment
cleanup() {
    debug "Cleaning up test environment..."
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE")
        sudo kill -9 "$pid" 2>/dev/null || true
        rm -f "$PID_FILE"
    fi
    sudo rm -rf "$TEST_DIR" "$TEST_LOG_FILE" "$CONFIG_FILE"
    debug "Cleanup complete"
}

# Check for required dependencies
test_dependencies() {
    local result=0
    local missing=()
    debug "Checking dependencies..."
    command -v inotifywait >/dev/null 2>&1 || missing+=("inotifywait")
    command -v sha256sum >/dev/null 2>&1 || missing+=("sha256sum")
    command -v yq >/dev/null 2>&1 || missing+=("yq")
    if [ ${#missing[@]} -gt 0 ]; then
        debug "Missing dependencies: ${missing[*]}"
        result=1
    fi
    print_result "Dependency check" "$result"
}

# Wait for a specific log message with a timeout
wait_for_log_message() {
    local message="$1"
    local timeout="$2"
    local start_time=$(date +%s)
    while true; do
        if sudo cat "$TEST_LOG_FILE" | sed 's/^[[:space:]]*//' | grep -q "$message"; then
            return 0
        fi
        if [ $(( $(date +%s) - start_time )) -ge "$timeout" ]; then
            return 1
        fi
        sleep 1
    done
}

# Test the execution of tampering-check.sh
test_script_execution() {
    local result=0
    debug "Testing script execution"
    sudo rm -f "$TEST_LOG_FILE"
    sudo touch "$TEST_LOG_FILE"
    sudo chmod 640 "$TEST_LOG_FILE"
    echo "test content" > "$TEST_DIR/test.txt"
    debug "Created test file: $TEST_DIR/test.txt"
    debug "Starting tampering-check.sh"
    sudo ./bin/tampering-check.sh "$TEST_DIR" > /dev/null 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"
    debug "Started with PID: $pid"
    debug "Waiting for initialization"
    if ! wait_for_log_message "Starting file monitoring" 5; then
        debug "Initialization failed, log content:"
        sudo cat "$TEST_LOG_FILE" | sed 's/^[[:space:]]*//'
        result=1
    else
        debug "Successfully initialized"
        sleep 2
        debug "Modifying test file"
        echo "modified content" > "$TEST_DIR/test.txt"
        debug "Waiting for modification detection"
        if ! wait_for_log_message "File modified:" 3; then
            debug "Modification detection failed, log content:"
            sudo cat "$TEST_LOG_FILE" | sed 's/^[[:space:]]*//'
            result=1
        else
            debug "Modification detected successfully"
        fi
    fi
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE")
        if ps -p "$pid" > /dev/null; then
            debug "Stopping process $pid"
            sudo kill "$pid"
            sleep 1
            debug "Final log content:"
            sudo cat "$TEST_LOG_FILE" | sed 's/^[[:space:]]*//'
        fi
        rm -f "$PID_FILE"
    fi
    print_result "Script execution" "$result"
}

# Test the systemd service file
test_systemd_service() {
    local result=0
    debug "Testing systemd service..."
    if ! systemd-analyze verify systemd/tampering-check@.service >/dev/null 2>&1; then
        debug "Invalid systemd service file"
        result=1
    else
        debug "Systemd service file verified successfully"
    fi
    print_result "Systemd service" "$result"
}

# Test hash calculation functionality
test_hash_calculation() {
    local result=0
    local test_file="$TEST_DIR/hash_test.txt"
    debug "Testing hash calculation..."
    echo "test content" > "$test_file"
    debug "Created hash test file: $test_file"
    local hash1=$(sha256sum "$test_file" | cut -d' ' -f1)
    debug "Initial hash: $hash1"
    echo "modified content" > "$test_file"
    debug "Modified hash test file"
    local hash2=$(sha256sum "$test_file" | cut -d' ' -f1)
    debug "New hash: $hash2"
    if [ "$hash1" = "$hash2" ]; then
        debug "Hash comparison failed: hashes match when they should differ"
        result=1
    else
        debug "Hash comparison successful: hashes differ as expected"
    fi
    print_result "Hash calculation" "$result"
}

# Main test execution function
main() {
    debug "Starting tampering-check tests..."
    setup
    test_dependencies
    test_script_execution
    test_systemd_service
    test_hash_calculation
    cleanup
    echo ""
    echo "Test Summary:"
    echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
    echo -e "${RED}Failed: $TESTS_FAILED${NC}"
    echo "Total: $TESTS_TOTAL"
    [ "$TESTS_FAILED" -eq 0 ]
}

if [ "$EUID" -ne 0 ]; then
    echo "Please run the tests with sudo"
    exit 1
fi

trap cleanup EXIT
main "$@"

