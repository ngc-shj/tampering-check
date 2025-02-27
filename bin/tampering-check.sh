#!/bin/bash
set -e

################################################################################
# Global variables
################################################################################

STATE_DIR="/var/lib/tampering-check"
RUN_DIR="/run/tampering-check"
CONFIG_FILE="/etc/tampering-check/config.yml"
YQ_AVAILABLE=-1  # -1 means "not checked yet"; 0 means "not available"; 1 means "available"

################################################################################
# Configuration default values
################################################################################

DEFAULT_CHECK_INTERVAL=3600
DEFAULT_STORAGE_MODE="text"       # Default to text storage
DEFAULT_HASH_ALGORITHM="sha256"
DEFAULT_ENABLE_ALERTS=true
DEFAULT_RECURSIVE=true
DEFAULT_IMPORTANCE="low"
DEFAULT_ALERT_MATRIX="ignore"
DEFAULT_SYSLOG_ENABLED=true
DEFAULT_EMAIL_ENABLED=false
DEFAULT_EMAIL_AGGREGATION_INTERVAL=5
DEFAULT_EMAIL_MIN_PRIORITY="notice"  # e.g., "info", "notice", "warning", "alert", "critical", "ignore"
DEFAULT_WEBHOOK_ENABLED=false
DEFAULT_LOG_LEVEL="info"
DEFAULT_LOG_FORMAT="plain"

################################################################################
# In-memory structures for directories/files importance and event-level mapping
################################################################################

declare -A DIRECTORIES=()   # index => JSON {path, recursive, default_importance}
declare -A FILES_MAP=()     # filePath => importance
declare -A ALERT_MATRIX=()  # For reading an 'alert_matrix' from config.yml.

################################################################################
# Usage
################################################################################

usage() {
    echo "Usage: $(basename $0) [-c CONFIG_FILE] WATCH_DIR"
    echo "  -c CONFIG_FILE : specify custom configuration file path (optional)"
    echo "  WATCH_DIR      : directory to monitor"
}

################################################################################
# parse_options
# where we handle command-line arguments and set WATCH_DIR
################################################################################

parse_options() {
    while getopts "c:h" opt; do
        case "$opt" in
            c)
                CONFIG_FILE="$OPTARG"
                ;;
            h|\?)
                usage
                exit 0
                ;;
        esac
    done
    shift $((OPTIND - 1))

    if [ $# -lt 1 ]; then
        usage
        exit 1
    fi

    # Convert underscores to slashes and prepend a leading slash
    WATCH_DIR="/${1//_//}"

    # Remove consecutive slashes by repeatedly replacing '//' with '/'
    # until no more '//' remains in the string.
    while [[ "$WATCH_DIR" == *"//"* ]]; do
        WATCH_DIR="${WATCH_DIR//\/\//\/}"
    done

    if [ -z "$WATCH_DIR" ] || [ "$WATCH_DIR" = "/" ]; then
        echo "Error: No target directory specified" >&2
        exit 1
    fi

}

################################################################################
# Priority mapping: convert string to numeric for comparisons
################################################################################

priority_to_level() {
    case "$1" in
        ignore)   echo 0 ;;
        info)     echo 1 ;;
        notice)   echo 2 ;;
        warning)  echo 3 ;;
        alert)    echo 4 ;;
        critical) echo 5 ;;
        *)        echo 2 ;; # fallback to "notice"
    esac
}

################################################################################
# Syslog priority mapping (e.g., 'critical' => 'crit')
################################################################################

map_to_syslog_priority() {
    case "$1" in
        critical) echo "crit" ;;
        warning)  echo "warn" ;; # syslog uses 'warn' or 'warning'
        error)    echo "err"  ;; # if you have an 'error' level
        *)        echo "$1"   ;;
    esac
}

################################################################################
# is_yq_available
#  - Checks global variable YQ_AVAILABLE. If unknown, runs command -v yq once.
################################################################################
is_yq_available() {
    if [ "$YQ_AVAILABLE" -eq -1 ]; then
        if command -v yq &>/dev/null; then
            YQ_AVAILABLE=1
        else
            YQ_AVAILABLE=0
        fi
    fi

    # Return 0 (false) if YQ_AVAILABLE=0, or 1 (true) if YQ_AVAILABLE=1
    [ "$YQ_AVAILABLE" -eq 1 ]
}

################################################################################
# parse_config
# Reads a configuration key from CONFIG_FILE using yq. Falls back to default
# values if yq is missing or the key is absent.
################################################################################

parse_config() {
    local key="$1"
    local def="$2"

    # 1) If yq not available, immediately return default
    if ! is_yq_available; then
        echo "$def"
        return 0
    fi

    # 2) If the config file doesn't exist, return default
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "$def"
        return 0
    fi

    # 3) Attempt to parse with yq
    local val
    val=$(yq -r "$key" "$CONFIG_FILE" 2>/dev/null)

    # 4) If empty or "null", return default
    if [ -z "$val" ] || [ "$val" = "null" ]; then
        echo "$def"
    else
        echo "$val"
    fi
}

################################################################################
# parse_alert_matrix
# Reads the alert_matrix from config.yml and populates an associative array:
# ALERT_MATRIX["importance,event"] = level
################################################################################

parse_alert_matrix() {
    # We can parse the set of importances and events dynamically if we like, or
    # we can define them statically. We'll define a small list for example:
    local importances=("critical" "high" "medium" "low" "ignore")
    local events=("create" "modify" "delete" "move")

    for imp in "${importances[@]}"; do
        for ev in "${events[@]}"; do
            local key=".alert_matrix.$imp.$ev"
            local val
            val=$(parse_config "$key" "$DEFAULT_ALERT_MATRIX")
            ALERT_MATRIX["$imp,$ev"]="$val"
        done
    done
}

################################################################################
# get_alert_level(importance, event_type)
# If loaded from config, we retrieve from ALERT_MATRIX. Fallback to "ignore".
################################################################################

get_alert_level_from_config() {
    local importance="$1"
    local event_type="$2"
    local idx="$importance,$event_type"
    local level="${ALERT_MATRIX["$idx"]}"
    if [ -z "$level" ]; then
        level="$DEFAULT_ALERT_MATRIX"
    fi
    echo "$level"
}

################################################################################
# parse_directories_config
# Reads the "directories" section but keeps only entries that match WATCH_DIR.
# We consider an entry "relevant" if the directory path is equal to or a prefix
# of WATCH_DIR. Adjust the logic as needed to match your exact policy.
################################################################################

parse_directories_config() {
  local dir_count
  dir_count=$(parse_config '.directories | length' 0)
  if [ "$dir_count" -gt 0 ]; then
      for i in $(seq 0 $((dir_count-1))); do
          local dir_path
          dir_path=$(parse_config ".directories[$i].path" "")
          [ -z "$dir_path" ] && continue

          local dir_recursive
          dir_recursive=$(parse_config ".directories[$i].recursive" "$DEFAULT_RECURSIVE")

          local def_imp
          def_imp=$(parse_config ".directories[$i].default_importance" "$DEFAULT_IMPORTANCE")

          # If WATCH_DIR is a subpath of dir_path OR dir_path is a subpath of WATCH_DIR
          # We only store this entry if it is relevant. For instance, if WATCH_DIR = /etc
          # then directories with path "/etc", "/etc/ssh" might be relevant. Adjust logic
          # based on exact requirement. Below we do the simplest approach: we only store
          # the directory config if it is a prefix of WATCH_DIR or vice versa.
          if [[ "$WATCH_DIR" == "$dir_path"* || "$dir_path" == "$WATCH_DIR"* ]]; then
              DIRECTORIES["$i"]="{\"path\":\"$dir_path\",\"recursive\":\"$dir_recursive\",\"default_importance\":\"$def_imp\"}"
          fi
      done
  fi
}

################################################################################
# parse_files_config
# Reads the "files" section but only keeps entries that match WATCH_DIR.
################################################################################

parse_files_config() {
    local file_count
    file_count=$(parse_config '.files | length' "$CONFIG_FILE" 0)
    if [ "$file_count" -gt 0 ]; then
        for i in $(seq 0 $((file_count-1))); do
            local fpath
            fpath=$(parse_config ".files[$i].path" "")
            [ -z "$fpath" ] && continue

            local fimp
            fimp=$(parse_config ".files[$i].importance" "$DEFAULT_IMPORTANCE")

            # We skip if the file is not under WATCH_DIR
            # e.g., if file is /var/log/syslog but WATCH_DIR=/etc
            if [[ "$fpath" == "$WATCH_DIR"* ]]; then
                FILES_MAP["$fpath"]="$fimp"
            fi
        done
    fi
}

################################################################################
# get_importance(filePath)
# 1) If files: has an explicit setting, use that.
# 2) Otherwise, match directories with the longest prefix to get default_importance
# 3) Fallback to "low".
################################################################################

get_importance() {
    local filePath="$1"
    if [ -n "${FILES_MAP["$filePath"]}" ]; then
        echo "${FILES_MAP["$filePath"]}"
        return
    fi

    local best_importance="low"
    local best_len=0
    for i in "${!DIRECTORIES[@]}"; do
        local json="${DIRECTORIES["$i"]}"
        local dpath
        local dimp
        dpath=$(echo "$json" | jq -r '.path')
        dimp=$(echo "$json" | jq -r '.default_importance')

        if [[ "$filePath" == "$dpath"* ]]; then
            local plen=${#dpath}
            if [ "$plen" -gt "$best_len" ]; then
                best_len=$plen
                best_importance="$dimp"
            fi
        fi
  done

  echo "$best_importance"
}

################################################################################
# MAIN CONFIG PARSING
################################################################################

parse_main_config() {
    # These rely on parse_config() to fetch values from CONFIG_FILE
    CHECK_INTERVAL=$(parse_config '.general.check_interval' "$DEFAULT_CHECK_INTERVAL")
    STORAGE_MODE=$(parse_config '.general.storage_mode' "$DEFAULT_STORAGE_MODE")
    HASH_ALGORITHM=$(parse_config '.general.hash_algorithm' "$DEFAULT_HASH_ALGORITHM")
    ENABLE_ALERTS=$(parse_config '.general.enable_alerts' "$DEFAULT_ENABLE_ALERTS")

    parse_alert_matrix
    parse_directories_config
    parse_files_config

    RECURSIVE=$(parse_config ".directories[] | select(.path == \"$WATCH_DIR\") | .recursive" "$DEFAULT_RECURSIVE")
    SYSLOG_ENABLED=$(parse_config '.notifications.syslog.enabled' "$DEFAULT_SYSLOG_ENABLED")
    EMAIL_ENABLED=$(parse_config '.notifications.email.enabled' "$DEFAULT_EMAIL_ENABLED")
    EMAIL_RECIPIENT=$(parse_config '.notifications.email.recipient' "")
    EMAIL_MIN_PRIORITY=$(parse_config '.notifications.email.min_priority' "$DEFAULT_EMAIL_MIN_PRIORITY")
    EMAIL_AGGREGATION_INTERVAL=$(parse_config '.notifications.email.aggregation_interval' "$DEFAULT_EMAIL_AGGREGATION_INTERVAL")
    WEBHOOK_ENABLED=$(parse_config '.notifications.webhook.enabled' "$DEFAULT_WEBHOOK_ENABLED")
    LOG_LEVEL=$(parse_config '.logging.level' "$DEFAULT_LOG_LEVEL")
    LOG_FORMAT=$(parse_config '.logging.format' "$DEFAULT_LOG_FORMAT")

    CHECK_INTERVAL=${CHECK_INTERVAL//[!0-9]/}
    if [ -z "$CHECK_INTERVAL" ] || [ "$CHECK_INTERVAL" -lt 1 ]; then
        CHECK_INTERVAL=$DEFAULT_CHECK_INTERVAL
    fi

    HASH_COMMAND="${HASH_ALGORITHM}sum"
    SERVICE_ID=$(echo "$WATCH_DIR" | sed 's#^/##' | tr '/' '_')

    if [ "$STORAGE_MODE" = "sqlite3" ]; then
        HASH_DB="${STATE_DIR}/${SERVICE_ID}_hashes.db"
        mkdir -p "$STATE_DIR"
        sqlite3 "$HASH_DB" "CREATE TABLE IF NOT EXISTS hashes (path TEXT PRIMARY KEY, hash TEXT NOT NULL);"
    else
        HASH_FILE="${STATE_DIR}/${SERVICE_ID}_hashes.txt"
        mkdir -p "$STATE_DIR"
        touch "$HASH_FILE"
        chmod 640 "$HASH_FILE"
    fi

    mkdir -p "$RUN_DIR"
    LOCK_FILE="${RUN_DIR}/${SERVICE_ID}.lock"

    EMAIL_QUEUE=$(mktemp /tmp/tampering_check_email_queue.XXXXXX)

    echo "Using hash algorithm: ${HASH_COMMAND}" >&2
}

################################################################################
# LOGGING AND NOTIFICATION
################################################################################

log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')

    if [ "$LOG_FORMAT" = "json" ]; then
        printf '{"timestamp":"%s","level":"%s","service":"tampering-check","message":"%s"}\n' \
          "$timestamp" "$level" "$message"
    else
        printf "[%s] %s: %s\n" "$timestamp" "$level" "$message"
    fi
}

queue_email_notification() {
    local message="$1"
    {
        flock -x 200
        echo "$message" >> "$EMAIL_QUEUE"
    } 200>"${LOCK_FILE}"
}

send_notification() {
    local message="$1"
    local priority="$2"

    # Log to stdout/journald
    log_message "$priority" "$message"

    # Syslog if enabled
    if [ "$ENABLE_ALERTS" = "true" ] && [ "$SYSLOG_ENABLED" = "true" ]; then
        local syslog_pri
        syslog_pri=$(map_to_syslog_priority "$priority")
        logger -p "auth.$syslog_pri" -t "tampering-check[$SERVICE_ID]" "$message"
    fi

    # Email if priority >= EMAIL_MIN_PRIORITY
    if [ "$ENABLE_ALERTS" = "true" ] && [ "$EMAIL_ENABLED" = "true" ] && [ -n "$EMAIL_RECIPIENT" ]; then
        local p_current
        p_current=$(priority_to_level "$priority")
        local p_min
        p_min=$(priority_to_level "$EMAIL_MIN_PRIORITY")

        if [ "$p_current" -ge "$p_min" ]; then
            queue_email_notification "$message"
        fi
    fi

    # Webhook if enabled
    if [ "$ENABLE_ALERTS" = "true" ] && [ "$WEBHOOK_ENABLED" = "true" ] && [ -n "$WEBHOOK_URL" ]; then
        local timestamp
        timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')
        curl -X POST -H "Content-Type: application/json" \
             -d "{\"service_id\":\"$SERVICE_ID\",\"priority\":\"$priority\",\"message\":\"$message\",\"timestamp\":\"$timestamp\"}" \
             "$WEBHOOK_URL" >/dev/null 2>&1 || true
    fi
}

send_queued_emails() {
    while true; do
        sleep "$EMAIL_AGGREGATION_INTERVAL"

        {
            flock -x 200
            if [ -s "$EMAIL_QUEUE" ]; then
                local tmp_queue
                tmp_queue="${EMAIL_QUEUE}_$(date +%s).tmp"
                mv "$EMAIL_QUEUE" "$tmp_queue"
                (umask 077 && touch "$EMAIL_QUEUE")

                mail -s "Tampering Alert on $SERVICE_ID" "$EMAIL_RECIPIENT" < "$tmp_queue"
                rm -f "$tmp_queue"
            fi
        } 200>"${LOCK_FILE}"
    done
}

################################################################################
# HASH CALCULATION AND VERIFICATION
################################################################################

calculate_initial_hashes() {
    log_message "info" "Calculating initial hash values for $WATCH_DIR"

    local common_opts="-type f ! -name '*.swp' ! -name '*.swpx' ! -name '*.swx' ! -name '*~'"
    local find_opts=""
    if [ "$RECURSIVE" = "true" ]; then
        find_opts="$common_opts"
    else
        find_opts="-maxdepth 1 $common_opts"
    fi

    if [ "$STORAGE_MODE" = "sqlite3" ]; then
        find "$WATCH_DIR" $find_opts -print | while read -r f; do
            local h
            h=$("$HASH_COMMAND" "$f" 2>/dev/null | cut -d' ' -f1)
            sqlite3 "$HASH_DB" "INSERT OR REPLACE INTO hashes (path, hash) VALUES ('$f', '$h');"
        done
    else
        find "$WATCH_DIR" $find_opts -print0 | xargs -0 -n1 "$HASH_COMMAND" > "$HASH_FILE"
        chmod 640 "$HASH_FILE"
    fi
}

verify_integrity() {
    local file="$1"
    [ ! -f "$file" ] && return
    local current_hash
    current_hash=$("$HASH_COMMAND" "$file" 2>/dev/null | cut -d' ' -f1)

    if [ "$STORAGE_MODE" = "sqlite3" ]; then
        local stored_hash
        stored_hash=$(sqlite3 "$HASH_DB" "SELECT hash FROM hashes WHERE path = '$file';")
        if [ -n "$stored_hash" ] && [ "$current_hash" != "$stored_hash" ]; then
            send_notification "Integrity violation detected in file: $file" "alert"
            sqlite3 "$HASH_DB" "UPDATE hashes SET hash = '$current_hash' WHERE path = '$file';"
        fi
    else
        local stored_hash
        stored_hash=$(awk -v f="$file" '$2 == f { print $1 }' "$HASH_FILE")
        if [ -n "$stored_hash" ] && [ "$current_hash" != "$stored_hash" ]; then
            send_notification "Integrity violation detected in file: $file" "alert"
            sed -i "\\|[[:space:]]$file\$|c\\$current_hash  $file" "$HASH_FILE"
        fi
    fi
}

################################################################################
# monitor_changes
# Uses inotifywait to monitor the WATCH_DIR for file changes and handle events.
################################################################################

monitor_changes() {
    send_notification "Starting file monitoring for $WATCH_DIR" "info"

    local inotify_opts="-m"
    [ "$RECURSIVE" = "true" ] && inotify_opts="$inotify_opts -r"

    inotifywait $inotify_opts --exclude '(\.swp(x)?$|\.swx$|~$)' \
      -e modify,create,delete,move "$WATCH_DIR" | while read -r path event file; do

        local full_path="${path}${file}"
        local e_lower
        e_lower=$(echo "$event" | tr '[:upper:]' '[:lower:]')

        local base_event
        case "$e_lower" in
            *create*) base_event="create" ;;
            *modify*) base_event="modify" ;;
            *delete*) base_event="delete" ;;
            *move*)   base_event="move" ;;
            *)        base_event="modify" ;;
        esac

        local imp
        imp=$(get_importance "$full_path")

        # If you want to read from the user-provided alert_matrix (parsed in parse_alert_matrix),
        # you can do:
        local level
        local key="$imp,$base_event"
        level="${ALERT_MATRIX[$key]}"
        if [ -z "$level" ]; then
            level="ignore"
        fi

        if [ "$level" = "ignore" ]; then
            continue
        fi

        send_notification "File ${base_event}d: $full_path" "$level"

        # Handle hash updates based on the event
        case "$base_event" in
          create|modify)
              if [ -f "$full_path" ]; then
                  if [ "$STORAGE_MODE" = "sqlite3" ]; then
                      local new_hash
                      new_hash=$("$HASH_COMMAND" "$full_path" 2>/dev/null | cut -d' ' -f1)
                      sqlite3 "$HASH_DB" "INSERT OR REPLACE INTO hashes (path, hash) VALUES ('$full_path', '$new_hash');"
                  else
                      if awk -v f="$full_path" '$2 == f { found=1 } END { exit !found }' "$HASH_FILE"; then
                          local new_hash
                          new_hash=$("$HASH_COMMAND" "$full_path" 2>/dev/null | cut -d' ' -f1)
                          sed -i "\\|[[:space:]]$full_path\$|c\\$new_hash  $full_path" "$HASH_FILE"
                      else
                          "$HASH_COMMAND" "$full_path" >> "$HASH_FILE"
                      fi
                  fi
              else
                  send_notification "File $full_path does not exist when attempting to calculate hash" "warning"
              fi
              ;;
          delete)
              if [ "$STORAGE_MODE" = "sqlite3" ]; then
                  sqlite3 "$HASH_DB" "DELETE FROM hashes WHERE path = '$full_path';"
              else
                  sed -i "\\|[[:space:]]$full_path\$|d" "$HASH_FILE"
              fi
              ;;
          move)
              verify_integrity "$full_path"
              ;;
        esac
    done
}

################################################################################
# periodic_verification
# Periodically re-checks the integrity of all files by comparing stored hashes.
################################################################################

periodic_verification() {
    while true; do
        sleep "$CHECK_INTERVAL"
        if [ "$STORAGE_MODE" = "sqlite3" ]; then
            sqlite3 "$HASH_DB" "SELECT path FROM hashes;" | while read -r f; do
                [ -f "$f" ] && verify_integrity "$f"
            done
        else
            [ -f "$HASH_FILE" ] || continue
            while IFS= read -r line; do
                local file
                file=$(echo "$line" | cut -d' ' -f2-)
                [ -f "$file" ] && verify_integrity "$file"
            done < "$HASH_FILE"
        fi
    done
}

################################################################################
# Cleanup function
################################################################################

cleanup_temp_files() {
    [ -n "$EMAIL_QUEUE" ] && rm -f "$EMAIL_QUEUE"
    return
}

################################################################################
# Main execution: calculate initial hashes, start periodic verification, email
# aggregator, and begin monitoring.
################################################################################

trap 'send_notification "Service terminated: $WATCH_DIR" "alert"; exit' INT TERM
trap cleanup_temp_files EXIT

main() {
    parse_options "$@"
    parse_main_config
    calculate_initial_hashes
    periodic_verification &
    send_queued_emails &
    monitor_changes
}

main "$@"

