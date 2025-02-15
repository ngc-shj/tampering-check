# Tampering Check

_A systemd-based file integrity monitoring system that provides real-time detection of unauthorized changes in critical system directories._

## Features

- **Real-time monitoring:** Uses inotifywait to detect file changes as they occur.
- **Periodic integrity verification:** Computes and compares file hashes using a configurable hash algorithm.
- **Flexible notifications:** Supports syslog, aggregated email notifications, and webhook alerts.
- **Aggregated email alerts:** Configurable aggregation interval to batch email notifications.
- **Customizable logging:** Log messages are output to stdout (captured by journald) with configurable formats (JSON or plain text).
- **Integrity hash file storage:** Only the hash file is stored in `/var/log/tampering-check`, with no additional log files.
- **Multi-directory support:** Use the provided systemd service template to monitor multiple directories.
- **YAML-based configuration:** Easily adjust parameters via `/etc/tampering-check/config.yml`.
- **Security hardening:** Leverages systemd security features (e.g., ProtectSystem, PrivateTmp, NoNewPrivileges).

## Requirements

- Linux system with systemd
- [inotify-tools](https://github.com/rvoicilas/inotify-tools)
- [yq](https://github.com/kislyuk/yq) (requires jq; see below for installation note)
- A mail client (e.g., mailutils on Debian/Ubuntu or mailx on RHEL/CentOS)
- [curl](https://curl.se/) for webhook notifications

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
     sudo apt-get install inotify-tools jq mailutils curl
     sudo pip install yq
     ```
   - **RHEL/CentOS:**
     ```bash
     sudo dnf install inotify-tools jq mailx curl
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
     hash_algorithm: sha256      # Hash algorithm to use (e.g., sha256)
     enable_alerts: true         # Enable/disable notifications

   directories:
     - path: /etc              # Directory to monitor
       recursive: true         # Monitor subdirectories
       priority: high          # Alert priority for this directory

   notifications:
     syslog:
       enabled: true
       facility: auth
     email:
       enabled: true
       smtp_server: smtp.example.com
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
   - **Hash file:**  
     The only file stored in `/var/log/tampering-check` is the hash file.
     ```bash
     sudo cat /var/log/tampering-check/etc_hashes.txt
     ```

4. **Stop monitoring:**
   ```bash
   sudo systemctl stop tampering-check@etc.service
   sudo systemctl disable tampering-check@etc.service
   ```

## Hash File and Notifications

- **Hash File:**  
  The integrity hash values for monitored files are stored in `/var/log/tampering-check`. No additional log files are written there.
- **Systemd journal:**  
  All log messages (e.g., notifications and status updates) are sent to stdout and managed by journald.
- **Email alerts:**  
  Aggregated email notifications for integrity violations and critical changes are sent based on the configured aggregation interval.
- **Syslog and webhook:**  
  Additional notifications are sent via syslog and webhook as configured.

## Security Considerations

- **File Permissions:**  
  The service runs as root to monitor system directories. The hash file is created with strict permissions (typically 640).
- **Systemd Security:**  
  The provided systemd service file includes security directives such as `ProtectSystem=strict`, `PrivateTmp=true`, and `NoNewPrivileges=true` to limit the service's impact on the system.
- **Notification Controls:**  
  Email notifications are limited to critical events unless explicitly enabled for info-level messages.

## Troubleshooting

1. **Service fails to start:**
   - Check systemd journal logs:
     ```bash
     journalctl -u tampering-check@*.service
     ```
   - Verify that `inotify-tools` is installed.
   - Confirm that directory permissions are correctly set.

2. **Missing notifications:**
   - Ensure configuration in `/etc/tampering-check/config.yml` is correct.
   - Verify mail client configuration and SMTP server settings.
   - Check webhook URL accessibility if using webhook notifications.

3. **High resource usage:**
   - Adjust `check_interval` in the configuration.
   - Exclude high-churn directories if necessary.

## Contributing

1. Fork the repository.
2. Create your feature branch.
3. Run tests (e.g., `./tests/test_tampering.sh`).
4. Commit your changes.
5. Push to your branch.
6. Create a Pull Request.

Please follow the coding guidelines and include detailed commit messages.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Acknowledgments

- **inotify-tools** developers
- **systemd** team
- **yq** and **jq** developers
- All contributors who helped improve this project

