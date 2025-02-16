# Tampering Check

_A systemd-based file integrity monitoring system that provides real-time detection of unauthorized changes in critical system directories._

## Features

- **Real-time monitoring:** Uses `inotifywait` to detect file changes as they occur.
- **Periodic integrity verification:** Periodically computes and compares file hashes using a configurable hash algorithm (e.g., `sha256`).
- **Flexible notifications:** Supports syslog, aggregated email alerts, and webhook notifications.
- **Customizable alert matrix:** Define how each importance level (e.g., `critical`, `high`, `medium`, `low`, `ignore`) reacts to file events (`create`, `modify`, `delete`, `move`).
- **Configurable email threshold:** Use a `min_priority` (e.g., `notice`, `warning`, `alert`, `critical`) to decide which events get emailed.
- **Customizable logging:** Output log messages in either plain text or JSON format. All logs also appear in the system journal.
- **Various integrity hash storage:** Store file hashes in a text file or an SQLite database.
- **Multi-directory support:** Use the provided systemd service template to monitor multiple directories.
- **YAML-based configuration:** Easily adjust parameters in `/etc/tampering-check/config.yml`.
- **Security hardening:** Leverages systemd security features such as `ProtectSystem=strict`, `PrivateTmp`, and `NoNewPrivileges`.

## Requirements

- A Linux system with systemd
- [inotify-tools](https://github.com/rvoicilas/inotify-tools)
- [yq](https://github.com/kislyuk/yq) (requires jq; see installation notes below)
- A mail client (e.g., `mailutils` on Debian/Ubuntu or `mailx` on RHEL/CentOS) if email alerts are needed
- [curl](https://curl.se/) if webhook notifications are used
- [sqlite3](https://www.sqlite.org/) (only required if `storage_mode` is set to `sqlite3`)

**Note on yq:**
When installing yq via `pip install yq`, it is typically placed in `/usr/local/bin/yq`. If desired, create a symbolic link to `/usr/bin/yq`:

```bash
sudo ln -s /usr/local/bin/yq /usr/bin/yq
```

Also ensure `jq` is installed (`sudo apt-get install jq` on Debian/Ubuntu, etc.).

## Installation

1. **Clone the repository**:
   ```bash
   git clone https://github.com/ngc-shj/tampering-check.git
   cd tampering-check
   ```

2. **Install dependencies**:

   - **Debian/Ubuntu**:
     ```bash
     sudo apt-get install inotify-tools jq mailutils curl sqlite3
     sudo pip install yq
     ```

   - **RHEL 7,8/CentOS 7,8**:
     ```bash
     sudo dnf install inotify-tools jq mailx curl sqlite
     sudo pip install yq
     ```

   - **RHEL 9/Rocky Linux 9**:
     ```bash
     sudo dnf install inotify-tools jq s-nail curl sqlite
     sudo pip install yq
     ```

3. **Run the installation script**:
   ```bash
   sudo ./scripts/install.sh
   ```

This script installs the main `tampering-check.sh` script, sets up systemd service files, and copies a sample config to `/etc/tampering-check/config.yml.example`.

## Configuration

The main configuration file is `/etc/tampering-check/config.yml`. A sample file is provided at `config/config.yml.example`. Copy or edit it to match your environment.

### Key Sections in `config.yml`

```yaml
general:
  check_interval: 3600           # Interval (seconds) for periodic re-check
  storage_mode: sqlite3          # Either "text" or "sqlite3"
  hash_algorithm: sha256         # e.g., "sha256sum"
  enable_alerts: true            # Globally enable or disable alerts

alert_matrix:
  # For each importance (critical, high, medium, low, ignore) and each file event
  # (create, modify, delete, move), define the resulting alert level (e.g., "critical", "warning", "info", "ignore").

  critical:
    create: "alert"
    modify: "critical"
    delete: "critical"
    move:   "critical"

  high:
    create: "warning"
    modify: "alert"
    delete: "alert"
    move:   "warning"

  medium:
    create: "notice"
    modify: "warning"
    delete: "warning"
    move:   "notice"

  low:
    create: "info"
    modify: "notice"
    delete: "notice"
    move:   "info"

  ignore:
    create: "ignore"
    modify: "ignore"
    delete: "ignore"
    move:   "ignore"

directories:
  # Define directories to monitor.
  - path: /etc
    recursive: true
    default_importance: high

files:
  # Override importance for specific files.
  - path: /etc/shadow
    importance: critical
  - path: /etc/passwd
    importance: critical
  - path: /var/log
    importance: ignore

notifications:
  syslog:
    enabled: true
    facility: auth

  email:
    # Default to false to be fail-safe; only enable if you have a proper mail setup.
    enabled: false
    recipient: "admin@example.com"
    # min_priority => only events at or above this priority get emailed
    min_priority: "notice"
    aggregation_interval: 5      # Aggregation frequency (seconds)

  webhook:
    enabled: false
    url: "https://example.com/webhook"

logging:
  level: info
  format: plain
```

- **`alert_matrix`**: Defines how each importance level (e.g. `critical`, `high`, etc.) reacts to file events (`create`, `modify`, `delete`, `move`).
- **`directories`**: Each entry specifies a path, whether subdirectories are included (`recursive`), and a `default_importance` to assign if no file entry overrides it.
- **`files`**: Specific file paths override the directory's default importance. 
  - Valid `importance` values: `critical`, `high`, `medium`, `low`, `ignore`.
- **`notifications.email.min_priority`**: Only events at or above this level (e.g. `notice`, `warning`, `alert`, `critical`) will be emailed.

## Usage

1. **Enable monitoring** for a specific directory, e.g. `/etc`:
   ```bash
   sudo systemctl enable tampering-check@etc.service
   sudo systemctl start tampering-check@etc.service
   ```
   For `/bin`, you would do:
   ```bash
   sudo systemctl enable tampering-check@bin.service
   sudo systemctl start tampering-check@bin.service
   ```

2. **Check service status**:
   ```bash
   sudo systemctl status tampering-check@etc.service
   ```

3. **View logs**:
   - **Systemd journal logs**:
     ```bash
     sudo journalctl -u tampering-check@etc.service
     ```
   - **Stored hash data**:
     - If using `text` mode:
       ```bash
       sudo cat /var/lib/tampering-check/etc_hashes.txt
       ```
     - If using `sqlite3` mode:
       ```bash
       sudo sqlite3 /var/lib/tampering-check/etc_hashes.db "SELECT * FROM hashes;"
       ```

4. **Stop monitoring**:
   ```bash
   sudo systemctl stop tampering-check@etc.service
   sudo systemctl disable tampering-check@etc.service
   ```

## Hash Storage and Notifications

- **Hash Storage**:
  Files are stored in `/var/lib/tampering-check`. Depending on `storage_mode`, either a text file (`*_hashes.txt`) or an SQLite DB (`*_hashes.db`) is used.
- **Syslog**:
  If enabled, relevant events are logged via `logger` at a mapped priority (e.g. `critical` => `crit`).
- **Email**:
  If `enabled: true` and `min_priority` is set, then events at or above that level are aggregated and emailed every `aggregation_interval` seconds.
- **Webhook**:
  If enabled, each event triggers an HTTP POST to the specified `url`.

## Security Considerations

- **File Permissions**:
  Because the service monitors system directories, it typically runs as root. Hash files (`*_hashes.txt`) or the SQLite DB are created with restrictive permissions (e.g., `640`).
- **Systemd Security**:
  The service file uses:
  ```ini
  ProtectSystem=strict
  PrivateTmp=true
  NoNewPrivileges=true
  ```
  If you need to allow additional writes (e.g., Postfix maildrop), you can add:
  ```ini
  ReadWritePaths=/var/spool/postfix/maildrop
  ```
  or adjust `ProtectSystem` to `"full"`.

## Troubleshooting

1. **Service fails to start**:
   - Check systemd logs:
     ```bash
     journalctl -u tampering-check@*.service
     ```
   - Ensure you have installed `inotify-tools` and (if using sqlite3) `sqlite3`.

2. **Notifications missing**:
   - Verify `enable_alerts: true` and your config for `email` or `webhook` sections.
   - Check if `EMAIL_MIN_PRIORITY` is set too high (e.g. `critical`) so that lower-level events are not emailed.
   - Make sure your mail system is configured if you rely on email.

3. **High resource usage**:
   - Increase `check_interval` in the config if periodic checks are too frequent.
   - Avoid monitoring directories with extremely high churn, or mark them with `ignore`.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

