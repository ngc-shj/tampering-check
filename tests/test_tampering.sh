#!/bin/bash
set -e

################################################################################
# Color definitions (for test result output)
################################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

################################################################################
# For debug output
################################################################################
debug() {
    if [ -n "${DEBUG_ENABLED+x}" ]; then
        printf "[%s] DEBUG: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
    fi
}

################################################################################
# Test environment variables
################################################################################
TEST_DIR="/tmp/tampering-check-test"
TEST_CONFIG_DIR="/tmp/tampering-check-test-config"
TEST_CONFIG_FILE="${TEST_CONFIG_DIR}/test_config.yml"
PID_FILE="/tmp/tampering-check-test.pid"

LOGGER_TAG="tampering-check"

TESTS_TOTAL=0
TESTS_PASSED=0
TESTS_FAILED=0

################################################################################
# Print test result and update counters
################################################################################
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

################################################################################
# Setup the test environment
################################################################################
setup() {
    debug "Setting up test environment"

    # Create test directories (but do NOT touch /etc/tampering-check).
    sudo mkdir -p "$TEST_DIR" "$TEST_CONFIG_DIR"
    sudo rm -f "$PID_FILE"

    create_test_config

    debug "Test environment setup complete"
}

################################################################################
# Create a custom config file in /tmp rather than /etc/tampering-check
################################################################################
create_test_config() {
    debug "Creating test configuration in $TEST_CONFIG_FILE"

    # If already exists, remove and re-create (test environment only)
    sudo rm -f "$TEST_CONFIG_FILE"

    cat << 'EOF' | sudo tee "$TEST_CONFIG_FILE" > /dev/null
general:
  check_interval: 5
  hash_algorithm: sha256
  enable_alerts: true

alert_matrix:
  medium:
    create: "notice"
    modify: "warning"
    delete: "warning"
    move:   "notice"

directories:
  - path: /tmp/tampering-check-test
    recursive: true
    default_importance: medium

notifications:
  syslog:
    enabled: true
    facility: auth

logging:
  level: debug
EOF

    sudo chmod 640 "$TEST_CONFIG_FILE"
    debug "Configuration file created at $TEST_CONFIG_FILE"
}

################################################################################
# Cleanup the test environment
################################################################################
cleanup() {
    debug "Cleaning up test environment..."

    # Kill the tampering-check process if still running
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        sudo kill -9 "$pid" 2>/dev/null || true
        rm -f "$PID_FILE"
    fi

    # Remove only our test directories in /tmp
    sudo rm -rf "$TEST_DIR" "$TEST_CONFIG_DIR"

    debug "Cleanup complete (did not remove /etc/tampering-check)"
}

################################################################################
# Dependency check
################################################################################
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

################################################################################
# Wait for a log message in journald filtered by the logger tag
################################################################################
wait_for_journal_message() {
    local message="$1"
    local timeout="$2"

    local start_time
    start_time=$(date +%s)

    while true; do
        # Check last 200 lines from journald for our LOGGER_TAG
        if journalctl -n 200 -t "$LOGGER_TAG" | grep -q "$message"; then
            return 0
        fi
        if [ $(( $(date +%s) - start_time )) -ge "$timeout" ]; then
            return 1
        fi
        sleep 1
    done
}

################################################################################
# Test script execution with custom config file
################################################################################
test_script_execution() {
    local result=0
    debug "Testing script execution with -c $TEST_CONFIG_FILE"

    # Create a test file in the monitored directory
    echo "test content" | sudo tee "$TEST_DIR/test.txt" >/dev/null
    debug "Created test file: $TEST_DIR/test.txt"

    # Start tampering-check.sh with -c pointing to our custom config
    debug "Starting tampering-check.sh"
    sudo ./bin/tampering-check.sh -c "$TEST_CONFIG_FILE" "$TEST_DIR" >/dev/null 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"
    debug "Started with PID: $pid"

    # Wait for "Starting file monitoring" message in journald
    if ! wait_for_journal_message "Starting file monitoring for $TEST_DIR" 5; then
        debug "Initialization failed (didn't see 'Starting file monitoring' in journald)"
        result=1
    else
        debug "Detected start message"
        sleep 2

        # Modify the file to see if tampering-check logs "File modified:"
        echo "modified content" | sudo tee "$TEST_DIR/test.txt" >/dev/null
        debug "Modified test file: $TEST_DIR/test.txt"

        if ! wait_for_journal_message "File modif.*d: $TEST_DIR/test.txt" 5; then
            debug "Modification detection failed (didn't see 'File modified' in journald)"
            result=1
        else
            debug "Modification detected successfully"
        fi
    fi

    # Stop the process
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE")
        if ps -p "$pid" >/dev/null; then
            debug "Stopping process $pid"
            sudo kill "$pid"
            sleep 1
        fi
        rm -f "$PID_FILE"
    fi

    print_result "Script execution" "$result"
}

################################################################################
# Test systemd service file syntax
################################################################################
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

################################################################################
# Test hash calculation logic
################################################################################
test_hash_calculation() {
    local result=0
    local test_file="$TEST_DIR/hash_test.txt"
    debug "Testing hash calculation"

    echo "test content" | sudo tee "$test_file" >/dev/null
    debug "Created file: $test_file"
    local hash1
    hash1=$(sha256sum "$test_file" | cut -d' ' -f1)

    echo "modified content" | sudo tee "$test_file" >/dev/null
    debug "Modified file: $test_file"
    local hash2
    hash2=$(sha256sum "$test_file" | cut -d' ' -f1)

    if [ "$hash1" = "$hash2" ]; then
        debug "Hashes matched, but they should differ!"
        result=1
    else
        debug "Hashes differ as expected"
    fi
    print_result "Hash calculation" "$result"
}

################################################################################
# Main test sequence
################################################################################
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
