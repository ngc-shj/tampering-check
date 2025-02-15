#!/bin/bash
set -e

# Config file location and default values
CONFIG_FILE="/etc/tampering-check/config.yml"

DEFAULT_CHECK_INTERVAL=300
DEFAULT_HASH_ALGORITHM="sha256"   # Expect to use sha256sum
DEFAULT_ENABLE_ALERTS=true
DEFAULT_RECURSIVE=true
DEFAULT_SYSLOG_ENABLED=true
DEFAULT_EMAIL_ENABLED=false
DEFAULT_WEBHOOK_ENABLED=false
DEFAULT_LOG_LEVEL="info"

# Function: parse_config
# Reads a configuration key from CONFIG_FILE using yq.
# Falls back to default values if yq is missing or the key is absent.
parse_config() {
    if ! command -v yq &> /dev/null; then
        echo "Warning: yq not found, using default values" >&2
        return 1
    fi
    if [ -f "$CONFIG_FILE" ]; then
        local key="$1"
        local value
        value=$(yq -r "$key" "$CONFIG_FILE" 2>/dev/null)
        if [ -z "$value" ]; then
            return 1
        else
            echo "$value"
        fi
    else
        return 1
    fi
}

# Normalize and validate the WATCH_DIR (the target directory to monitor)
WATCH_DIR=$(echo "$1" | sed 's#/\+#/#g' | sed 's#/$##')
if [[ "$WATCH_DIR" != /* ]]; then
    WATCH_DIR="/$WATCH_DIR"
fi
if [ -z "$WATCH_DIR" ]; then
    echo "Error: No target directory specified" >&2
    exit 1
fi

# Load configuration values, falling back to defaults if needed.
CHECK_INTERVAL=$(parse_config '.general.check_interval' || echo "$DEFAULT_CHECK_INTERVAL")
HASH_ALGORITHM=$(parse_config '.general.hash_algorithm' || echo "$DEFAULT_HASH_ALGORITHM")
ENABLE_ALERTS=$(parse_config '.general.enable_alerts' || echo "$DEFAULT_ENABLE_ALERTS")
RECURSIVE=$(parse_config ".directories[] | select(.path == \"$WATCH_DIR\") | .recursive" || echo "$DEFAULT_RECURSIVE")
SYSLOG_ENABLED=$(parse_config '.notifications.syslog.enabled' || echo "$DEFAULT_SYSLOG_ENABLED")
EMAIL_ENABLED=$(parse_config '.notifications.email.enabled' || echo "$DEFAULT_EMAIL_ENABLED")
WEBHOOK_ENABLED=$(parse_config '.notifications.webhook.enabled' || echo "$DEFAULT_WEBHOOK_ENABLED")
LOG_LEVEL=$(parse_config '.logging.level' || echo "$DEFAULT_LOG_LEVEL")

# Ensure CHECK_INTERVAL is a valid positive integer
CHECK_INTERVAL=${CHECK_INTERVAL//[!0-9]/}
if [ -z "$CHECK_INTERVAL" ] || [ "$CHECK_INTERVAL" -lt 1 ]; then
    CHECK_INTERVAL=$DEFAULT_CHECK_INTERVAL
fi

# Set the hash command based on the configuration.
HASH_COMMAND="${HASH_ALGORITHM}sum"

# Log the chosen hash algorithm for debugging purposes (optional)
echo "Using hash algorithm: ${HASH_COMMAND}" >> /var/log/tampering-check/debug.log 2>/dev/null

# Generate a service identifier based on WATCH_DIR (slashes replaced with underscores)
SERVICE_ID=$(echo "$WATCH_DIR" | sed 's#^/##' | tr '/' '_')

# Set up logging and hash file paths
LOG_DIR="/var/log/tampering-check"
LOG_FILE="${LOG_DIR}/${SERVICE_ID}.log"
HASH_FILE="${LOG_DIR}/${SERVICE_ID}_hashes.txt"

# Ensure the log directory exists with proper permissions
mkdir -p "$LOG_DIR"
chmod 750 "$LOG_DIR"
touch "$LOG_FILE"
chmod 640 "$LOG_FILE"

# Function: send_notification
# Logs a message to LOG_FILE and sends notifications via syslog, email, and webhook if enabled.
send_notification() {
    local message="$1"
    local priority="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # Unified logging format for all messages
    printf "[%s] %s: %s\n" "$timestamp" "$priority" "$message" >> "$LOG_FILE"

    # Send syslog notification if enabled
    if [ "$ENABLE_ALERTS" = "true" ] && [ "$SYSLOG_ENABLED" = "true" ]; then
        logger -p "auth.$priority" -t "tampering-check[$SERVICE_ID]" "$message"
    fi

    # Send email notification if enabled and EMAIL_RECIPIENT is set
    if [ "$ENABLE_ALERTS" = "true" ] && [ "$EMAIL_ENABLED" = "true" ] && [ -n "$EMAIL_RECIPIENT" ]; then
        # The mail command must be configured on the system.
        echo "$message" | mail -s "Tampering Alert on $SERVICE_ID" "$EMAIL_RECIPIENT"
    fi

    # Send webhook notification if enabled and WEBHOOK_URL is set
    if [ "$ENABLE_ALERTS" = "true" ] && [ "$WEBHOOK_ENABLED" = "true" ] && [ -n "$WEBHOOK_URL" ]; then
        curl -X POST -H "Content-Type: application/json" \
             -d "{\"service_id\": \"$SERVICE_ID\", \"priority\": \"$priority\", \"message\": \"$message\", \"timestamp\": \"$timestamp\"}" \
             "$WEBHOOK_URL" >/dev/null 2>&1 || true
    fi
}

# Function: calculate_initial_hashes
# Calculates and records the hash of all files in WATCH_DIR.
calculate_initial_hashes() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # Use unified logging format for the initial message
    printf "[%s] info: Calculating initial hash values for %s\n" "$timestamp" "$WATCH_DIR" >> "$LOG_FILE"
    
    # Common find options to exclude temporary files
    local common_opts="-type f ! -name '*.swp' ! -name '*.swpx' ! -name '*~' -print0"
    local find_opts=""
    if [ "$RECURSIVE" = "true" ]; then
        find_opts="$common_opts"
    else
        find_opts="-maxdepth 1 $common_opts"
    fi

    find "$WATCH_DIR" $find_opts | xargs -0 -n1 "$HASH_COMMAND" 2>/dev/null > "$HASH_FILE"
    chmod 640 "$HASH_FILE"
}

# Function: verify_integrity
# Compares the current hash of a file with the stored hash and sends an alert if they differ.
verify_integrity() {
    local file="$1"
    [ ! -f "$file" ] && return
    local current_hash stored_hash
    current_hash=$("${HASH_COMMAND}" "$file" 2>/dev/null | cut -d' ' -f1)
    if [ -f "$HASH_FILE" ]; then
        stored_hash=$(grep -F "$file" "$HASH_FILE" 2>/dev/null | cut -d' ' -f1)
        if [ -n "$current_hash" ] && [ -n "$stored_hash" ] && [ "$current_hash" != "$stored_hash" ]; then
            send_notification "Integrity violation detected in file: $file" "alert"
            # Update the stored hash with the new value
            sed -i "\\|$file$|c\\$current_hash  $file" "$HASH_FILE"
        fi
    else
        # If no initial hash exists for the file, record it now.
        "${HASH_COMMAND}" "$file" >> "$HASH_FILE"
    fi
}

# Function: monitor_changes
# Uses inotifywait to monitor WATCH_DIR for file changes and handle events.
monitor_changes() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    send_notification "Starting file monitoring for $WATCH_DIR" "info"
    
    local inotify_opts="-m"
    [ "$RECURSIVE" = "true" ] && inotify_opts="$inotify_opts -r"
    
    inotifywait $inotify_opts --exclude '(\.swp(x)?$|~$)' -e modify,create,delete,move "$WATCH_DIR" | while read -r path event file; do
        local full_path="${path}${file}"
        case "$event" in
            MODIFY)
                send_notification "File modified: $full_path" "warning"
                verify_integrity "$full_path"
                ;;
            CREATE)
                send_notification "File created: $full_path" "notice"
                if [ -f "$full_path" ]; then
                    # Check if an entry for the file already exists in HASH_FILE.
                    if grep -Fq "$full_path" "$HASH_FILE"; then
                        # Update the hash entry for the file.
                        new_hash=$("$HASH_COMMAND" "$full_path" 2>/dev/null | cut -d' ' -f1)
                        sed -i "\\|  $full_path$|c\\$new_hash  $full_path" "$HASH_FILE"
                    else
                        "$HASH_COMMAND" "$full_path" >> "$HASH_FILE"
                    fi
                else
                    send_notification "File $full_path does not exist when attempting to calculate hash" "warning"
                fi
                ;;
            DELETE)
                send_notification "File deleted: $full_path" "warning"
                sed -i "\\|  $full_path$|d" "$HASH_FILE"
                ;;
            MOVED_*)
                send_notification "File moved: $full_path" "notice"
                ;;
        esac
    done
}

# Function: periodic_verification
# Periodically re-checks the integrity of files by comparing stored hashes.
periodic_verification() {
    while true; do
        sleep "$CHECK_INTERVAL"
        if [ -f "$HASH_FILE" ]; then
            while IFS= read -r line; do
                local file
                file=$(echo "$line" | cut -d' ' -f2-)
                [ -f "$file" ] && verify_integrity "$file"
            done < "$HASH_FILE"
        fi
    done
}

# Main execution: calculate initial hashes, start periodic verification in the background, and begin monitoring.
main() {
    calculate_initial_hashes
    periodic_verification &
    monitor_changes
}

# Trap INT and TERM signals to log termination before exiting.
trap 'send_notification "Service terminated: $WATCH_DIR" "alert"; exit' INT TERM

main

