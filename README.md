# Tampering Check

_A systemd-based file integrity monitoring system that provides real-time detection of unauthorized changes in critical system directories._

## Features

- **Real-time monitoring:** Uses inotifywait to detect file changes as they occur.
- **Periodic integrity verification:** Computes and compares file hashes using a configurable hash algorithm.
- **Flexible notifications:** Supports syslog, aggregated email notifications, and webhook alerts.
- **Aggregated email alerts:** Configurable aggregation interval to batch email notifications.
- **Customizable logging:** Log messages are output to stdout (captured by journald) with configurable formats (JSON or plain text).
- **Integrity hash storage:** Supports `text` file or `sqlite3` database for storing integrity hashes.
- **Multi-directory support:** Use the provided systemd service template to monitor multiple directories.
- **YAML-based configuration:** Easily adjust parameters via `/etc/tampering-check/config.yml`.
- **Security hardening:** Leverages systemd security features (e.g., ProtectSystem, PrivateTmp, NoNewPrivileges).

## Requirements

- Linux system with systemd
- [inotify-tools](https://github.com/rvoicilas/inotify-tools)
- [yq](https://github.com/kislyuk/yq) (requires jq; see below for installation note)
- A mail client (e.g., mailutils on Debian/Ubuntu or mailx on RHEL/CentOS)
- [curl](https://curl.se/) for webhook notifications
- [sqlite3](https://www.sqlite.org/) (only required when using `sqlite3` storage mode)

**Note:** When installing yq via `pip install yq`, it is typically placed in `/usr/local/bin/yq`. To have it in `/usr/bin/yq`, create a symbolic link:
```bash
sudo ln -s /usr/local/bin/yq /usr/bin/yq
```
Ensure that `jq` is installed on your system (e.g., `sudo apt-get install jq` on Debian/Ubuntu).

## Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/ngc-shj/tampering-check.git
   cd tampering-check
   ```

2. **Install dependencies:**
   - **Debian/Ubuntu:**
     ```bash
     sudo apt-get install inotify-tools jq mailutils curl sqlite3
     sudo pip install yq
     ```
   - **RHEL/CentOS:**
     ```bash
     sudo dnf install inotify-tools jq mailx curl sqlite3
     sudo pip install yq
     ```

3. **Run the installation script:**
   ```bash
   sudo ./scripts/install.sh
   ```

## Configuration

The service is configured through `/etc/tampering-check/config.yml`. A template configuration file is provided at `config/config.yml.example`.

1. **Create your configuration file:**
   ```bash
   sudo cp /etc/tampering-check/config.yml.example /etc/tampering-check/config.yml
   sudo nano /etc/tampering-check/config.yml
   ```

2. **Key configuration options:**

   ```yaml
   general:
     check_interval: 300       # Seconds between periodic integrity checks
     storage_mode: text        # Storage mode: "text" or "sqlite3"
     hash_algorithm: sha256    # Hash algorithm to use (e.g., sha256)
     enable_alerts: true       # Enable/disable notifications

   directories:
     - path: /etc              # Directory to monitor
       recursive: true         # Monitor subdirectories

   notifications:
     syslog:
       enabled: true
       facility: auth
     email:
       enabled: true
       recipient: "admin@example.com"   # Recipient email address
       include_info: false      # Set to true to send info-level messages via email
       aggregation_interval: 5  # Interval in seconds to aggregate email notifications
     webhook:
       enabled: false
       url: "https://example.com/webhook"

   logging:
     level: info
     format: json              # Options: "json" or "plain"
   ```

## Usage

1. **Enable monitoring for a specific directory:**
   ```bash
   # Monitor the /etc directory
   sudo systemctl enable tampering-check@etc.service
   sudo systemctl start tampering-check@etc.service
   
   # Monitor the /bin directory
   sudo systemctl enable tampering-check@bin.service
   sudo systemctl start tampering-check@bin.service
   ```

2. **Check service status:**
   ```bash
   sudo systemctl status tampering-check@etc.service
   ```

3. **View logs:**
   - **Systemd journal logs:**
     Log messages are output to stdout and captured by journald.
     ```bash
     sudo journalctl -u tampering-check@etc.service
     ```
   - **Stored hash data:**
     Depending on the `storage_mode`, hashes are stored as follows:
     ```bash
     # If using text mode:
     sudo cat /var/lib/tampering-check/etc_hashes.txt
     
     # If using sqlite3 mode:
     sudo sqlite3 /var/lib/tampering-check/etc_hashes.db "SELECT * FROM hashes;"
     ```

4. **Stop monitoring:**
   ```bash
   sudo systemctl stop tampering-check@etc.service
   sudo systemctl disable tampering-check@etc.service
   ```

## Hash Storage and Notifications

- **Hash Storage:**
  The integrity hash values for monitored files are stored in `/var/lib/tampering-check`. Depending on `storage_mode`, this is either a text file (`*_hashes.txt`) or an SQLite database (`*_hashes.db`).
- **Systemd journal:**
  All log messages (e.g., notifications and status updates) are sent to stdout and managed by journald.
- **Email alerts:**
  Aggregated email notifications for integrity violations and critical changes are sent based on the configured aggregation interval.
- **Syslog and webhook:**
  Additional notifications are sent via syslog and webhook as configured.

## Security Considerations

- **File Permissions:**
  The service runs as root to monitor system directories. The hash file/database is created with strict permissions (typically 640).
- **Systemd Security:**
  The provided systemd service file includes security directives to limit the service's impact.
  **Note:** By default, the service file uses:
  ```ini
  ProtectSystem=strict
  PrivateTmp=true
  NoNewPrivileges=true
  ```
  If your environment requires additional write access (for example, if Postfix must write to its maildrop directory), you may:
  - Add extra paths to ReadWritePaths (e.g., `/var/spool/postfix/maildrop`), or
  - Change `ProtectSystem` from "strict" to "full".
  Adjust these settings based on your system configuration and security requirements.
- **Notification Controls:**
  Email notifications are limited to critical events unless explicitly enabled for info-level messages.

## Troubleshooting

1. **Service fails to start:**
   - Check systemd journal logs:
     ```bash
     journalctl -u tampering-check@*.service
     ```
   - Verify that `inotify-tools` and `sqlite3` (if applicable) are installed.

2. **Missing notifications:**
   - Ensure configuration in `/etc/tampering-check/config.yml` is correct.
   - Check webhook URL accessibility if using webhook notifications.

3. **High resource usage:**
   - Adjust `check_interval` in the configuration.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.


