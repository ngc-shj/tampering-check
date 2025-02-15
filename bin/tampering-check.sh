#!/bin/bash
set -e

# Configuration file location and default values
CONFIG_FILE="/etc/tampering-check/config.yml"

DEFAULT_CHECK_INTERVAL=300
DEFAULT_HASH_ALGORITHM="sha256"   # Expect to use sha256sum
DEFAULT_ENABLE_ALERTS=true
DEFAULT_RECURSIVE=true
DEFAULT_SYSLOG_ENABLED=true
DEFAULT_EMAIL_ENABLED=false
DEFAULT_EMAIL_INCLUDE_INFO=false
DEFAULT_EMAIL_AGGREGATION_INTERVAL=5
DEFAULT_WEBHOOK_ENABLED=false
DEFAULT_LOG_LEVEL="info"
DEFAULT_LOG_FORMAT="plain"

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
        # Treat empty or "null" result as not found.
        if [ -z "$value" ] || [ "$value" = "null" ]; then
            return 1
        else
            echo "$value"
        fi
    else
        return 1
    fi
}

# Convert instance name (with underscores) to a proper directory path with slashes
WATCH_DIR="/${1//_//}"
if [ -z "$WATCH_DIR" ]; then
    echo "Error: No target directory specified" >&2
    exit 1
fi

# Retrieve configuration values, falling back to default values if necessary
CHECK_INTERVAL=$(parse_config '.general.check_interval' || echo "$DEFAULT_CHECK_INTERVAL")
HASH_ALGORITHM=$(parse_config '.general.hash_algorithm' || echo "$DEFAULT_HASH_ALGORITHM")
ENABLE_ALERTS=$(parse_config '.general.enable_alerts' || echo "$DEFAULT_ENABLE_ALERTS")
RECURSIVE=$(parse_config ".directories[] | select(.path == \"$WATCH_DIR\") | .recursive" || echo "$DEFAULT_RECURSIVE")
SYSLOG_ENABLED=$(parse_config '.notifications.syslog.enabled' || echo "$DEFAULT_SYSLOG_ENABLED")
EMAIL_ENABLED=$(parse_config '.notifications.email.enabled' || echo "$DEFAULT_EMAIL_ENABLED")
EMAIL_RECIPIENT=$(parse_config '.notifications.email.recipient' || echo "")
EMAIL_INCLUDE_INFO=$(parse_config '.notifications.email.include_info' || echo "$DEFAULT_EMAIL_INCLUDE_INFO")
EMAIL_AGGREGATION_INTERVAL=$(parse_config '.notifications.email.aggregation_interval' || echo "$DEFAULT_EMAIL_AGGREGATION_INTERVAL")
WEBHOOK_ENABLED=$(parse_config '.notifications.webhook.enabled' || echo "$DEFAULT_WEBHOOK_ENABLED")
LOG_LEVEL=$(parse_config '.logging.level' || echo "$DEFAULT_LOG_LEVEL")
LOG_FORMAT=$(parse_config '.logging.format' || echo "$DEFAULT_LOG_FORMAT")

# Ensure CHECK_INTERVAL is a valid positive integer
CHECK_INTERVAL=${CHECK_INTERVAL//[!0-9]/}
if [ -z "$CHECK_INTERVAL" ] || [ "$CHECK_INTERVAL" -lt 1 ]; then
    CHECK_INTERVAL=$DEFAULT_CHECK_INTERVAL
fi

# Set hash command based on configuration
HASH_COMMAND="${HASH_ALGORITHM}sum"
echo "Using hash algorithm: ${HASH_COMMAND}" >&2

# Generate SERVICE_ID from the target directory (convert slashes to underscores)
SERVICE_ID=$(echo "$WATCH_DIR" | sed 's#^/##' | tr '/' '_')

# Define log directory and hash file path (log output goes to stdout; hash file is used for hash management)
LOG_DIR="/var/lib/tampering-check"
HASH_FILE="${LOG_DIR}/${SERVICE_ID}_hashes.txt"

# Create directory for hash file and set proper permissions
touch "$HASH_FILE"
chmod 640 "$HASH_FILE"

# Define runtime directory and lock file path (unique per monitored directory)
RUN_DIR="/run/tampering-check"
LOCK_FILE="${RUN_DIR}/${SERVICE_ID}.lock"

# Create a secure temporary file for email queue using mktemp
EMAIL_QUEUE=$(mktemp /tmp/tampering_check_email_queue.XXXXXX)

# Function: log_message
# Outputs a log message in the specified format to stdout.
log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')
    if [ "$LOG_FORMAT" = "json" ]; then
        printf '{"timestamp": "%s", "level": "%s", "service": "tampering-check", "message": "%s"}\n' "$timestamp" "$level" "$message"
    else
        # Plain text format: [timestamp] level: message
        printf "[%s] %s: %s\n" "$timestamp" "$level" "$message"
    fi
}

# Function: queue_email_notification
# Appends the message to the email queue file.
queue_email_notification() {
    local message="$1"
    {
        flock -x 200  # Exclusive lock to prevent concurrent writes
        echo "$message" >> "$EMAIL_QUEUE"
    } 200>"${LOCK_FILE}"
}

# Function: send_notification
# Sends a notification by logging a message to stdout and optionally forwarding to syslog, email, or webhook.
send_notification() {
    local message="$1"
    local priority="$2"
    log_message "$priority" "$message"
    if [ "$ENABLE_ALERTS" = "true" ] && [ "$SYSLOG_ENABLED" = "true" ]; then
        logger -p "auth.$priority" -t "tampering-check[$SERVICE_ID]" "$message"
    fi
    # Queue email notifications (skip info messages unless EMAIL_INCLUDE_INFO is true)
    if [ "$ENABLE_ALERTS" = "true" ] && [ "$EMAIL_ENABLED" = "true" ] && [ -n "$EMAIL_RECIPIENT" ]; then
        if [ "$priority" != "info" ] || [ "$EMAIL_INCLUDE_INFO" = "true" ]; then
            queue_email_notification "$message"
        fi
    fi
    if [ "$ENABLE_ALERTS" = "true" ] && [ "$WEBHOOK_ENABLED" = "true" ] && [ -n "$WEBHOOK_URL" ]; then
        local timestamp
        timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')
        curl -X POST -H "Content-Type: application/json" \
             -d "{\"service_id\": \"$SERVICE_ID\", \"priority\": \"$priority\", \"message\": \"$message\", \"timestamp\": \"$timestamp\"}" \
             "$WEBHOOK_URL" >/dev/null 2>&1 || true
    fi
}

# Function: send_queued_emails
# Checks the email queue every EMAIL_AGGREGATION_INTERVAL seconds and sends aggregated email notifications if any messages are queued.
send_queued_emails() {
    while true; do
        sleep "$EMAIL_AGGREGATION_INTERVAL"

        {
            flock -x 200  # Ensure exclusive access to the queue

            if [ -s "$EMAIL_QUEUE" ]; then
                local tmp_queue
                tmp_queue="${EMAIL_QUEUE}_$(date +%s).tmp"

                # Safely move the queue file and create a new one
                mv "$EMAIL_QUEUE" "$tmp_queue"
                (umask 077 && touch "$EMAIL_QUEUE")

                # Send the email
                mail -s "Tampering Alert on $SERVICE_ID" "$EMAIL_RECIPIENT" < "$tmp_queue"

                # Cleanup temporary queue file
                rm -f "$tmp_queue"
            fi

        } 200>"${LOCK_FILE}"
    done
}

# Function: calculate_initial_hashes
# Calculates and records initial hash values for all files in the target directory.
calculate_initial_hashes() {
    log_message "info" "Calculating initial hash values for $WATCH_DIR"
    
    # Common find options to exclude temporary files
    local common_opts="-type f ! -name '*.swp' ! -name '*.swpx' ! -name '*.swx' ! -name '*~' -print0"
    local find_opts=""
    if [ "$RECURSIVE" = "true" ]; then
        find_opts="$common_opts"
    else
        find_opts="-maxdepth 1 $common_opts"
    fi

    find "$WATCH_DIR" $find_opts | xargs -0 -n1 "${HASH_COMMAND}" 2>/dev/null > "$HASH_FILE"
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
        stored_hash=$(awk -v f="$file" '$2 == f { print $1 }' "$HASH_FILE")
        if [ -n "$current_hash" ] && [ -n "$stored_hash" ] && [ "$current_hash" != "$stored_hash" ]; then
            send_notification "Integrity violation detected in file: $file" "alert"
            sed -i "\\|[[:space:]]$file\$|c\\$current_hash  $file" "$HASH_FILE"
        fi
    else
        "${HASH_COMMAND}" "$file" >> "$HASH_FILE"
    fi
}

# Function: monitor_changes
# Monitors file changes in the target directory using inotifywait and sends notifications based on events.
monitor_changes() {
    send_notification "Starting file monitoring for $WATCH_DIR" "info"
    
    local inotify_opts="-m"
    [ "$RECURSIVE" = "true" ] && inotify_opts="$inotify_opts -r"
    
    inotifywait $inotify_opts --exclude '(\.swp(x)?$|\.swx$|~$)' -e modify,create,delete,move "$WATCH_DIR" | while read -r path event file; do
        local full_path="${path}${file}"
        case "$event" in
            MODIFY)
                send_notification "File modified: $full_path" "warning"
                verify_integrity "$full_path"
                ;;
            CREATE)
                send_notification "File created: $full_path" "notice"
                if [ -f "$full_path" ]; then
                    if awk -v f="$full_path" '$2 == f { found=1 } END { exit !found }' "$HASH_FILE"; then
                        new_hash=$("${HASH_COMMAND}" "$full_path" 2>/dev/null | cut -d' ' -f1)
                        sed -i "\\|[[:space:]]$full_path\$|c\\$new_hash  $full_path" "$HASH_FILE"
                    else
                        "${HASH_COMMAND}" "$full_path" >> "$HASH_FILE"
                    fi
                else
                    send_notification "File $full_path does not exist when attempting to calculate hash" "warning"
                fi
                ;;
            DELETE)
                send_notification "File deleted: $full_path" "warning"
                sed -i "\\|[[:space:]]$full_path\$|d" "$HASH_FILE"
                ;;
            MOVED_*)
                send_notification "File moved: $full_path" "notice"
                verify_integrity "$full_path"
                ;;
        esac
    done
}

# Function: periodic_verification
# Periodically re-checks the integrity of all files by comparing stored hashes.
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

# Main execution: calculate initial hashes, start periodic verification, email aggregator, and begin monitoring
main() {
    calculate_initial_hashes
    periodic_verification &
    send_queued_emails &
    monitor_changes
}

# Cleanup function to remove temporary email queue file at script exit.
cleanup_temp_files() {
    [ -n "$EMAIL_QUEUE" ] && rm -f "$EMAIL_QUEUE"
}

# Trap INT and TERM signals to send a termination notification before exiting.
trap 'send_notification "Service terminated: $WATCH_DIR" "alert"; exit' INT TERM
# Also trap EXIT to clean up temporary files.
trap cleanup_temp_files EXIT

main

