# Tampering Check

A systemd-based file integrity monitoring system that provides real-time detection of unauthorized changes in critical system directories.

## Features

- Real-time file monitoring using inotifywait
- Periodic integrity verification using configurable hash algorithms
- Flexible notification system (syslog, email, webhook)
- Systemd service template for monitoring multiple directories
- YAML-based configuration
- Detailed logging with log rotation
- Security hardening through systemd security features

## Requirements

- Linux system with systemd
- inotify-tools package
- yq (YAML parser)
- mail command (for email notifications)
- curl (for webhook notifications)

## Installation

1. Clone the repository:
```bash
git clone https://github.com/ngc-shj/tampering-check.git
cd tampering-check
```

2. Install dependencies:
```bash
# For Debian/Ubuntu
sudo apt-get install inotify-tools yq mailutils curl

# For RHEL/CentOS
sudo yum install inotify-tools yq mailx curl
```

3. Run the installation script:
```bash
sudo ./scripts/install.sh
```

## Configuration

The service can be configured through `/etc/tampering-check/config.yml`. 
A template configuration file is provided at `config/config.yml.example`.

1. Create your configuration:
```bash
sudo cp /etc/tampering-check/config.yml.example /etc/tampering-check/config.yml
sudo nano /etc/tampering-check/config.yml
```

2. Key configuration options:

```yaml
general:
  check_interval: 300    # Seconds between integrity checks
  hash_algorithm: sha256 # Hash algorithm to use
  enable_alerts: true    # Enable/disable notifications

directories:
  - path: /etc          # Directory to monitor
    recursive: true     # Monitor subdirectories
    priority: high      # Priority level for alerts

notifications:
  syslog:
    enabled: true
    facility: auth
    min_priority: notice
  email:
    enabled: false
    smtp_server: smtp.example.com
    to: admin@example.com
```

## Usage

1. Enable monitoring for specific directories:

```bash
# Monitor /etc directory
sudo systemctl enable tampering-check@etc.service
sudo systemctl start tampering-check@etc.service

# Monitor /bin directory
sudo systemctl enable tampering-check@bin.service
sudo systemctl start tampering-check@bin.service
```

2. Check service status:

```bash
sudo systemctl status tampering-check@etc.service
```

3. View logs:

```bash
# View systemd journal logs
sudo journalctl -u tampering-check@etc.service

# View detailed logs
sudo cat /var/log/tampering-check/etc.log
```

4. Stop monitoring:

```bash
sudo systemctl stop tampering-check@etc.service
sudo systemctl disable tampering-check@etc.service
```

## Logs and Alerts

The service generates several types of logs:

1. Service-specific logs in `/var/log/tampering-check/`:
   - File modifications
   - Hash verification results
   - Service status changes

2. System journal entries for:
   - Critical file changes
   - Service starts/stops
   - Error conditions

3. Email alerts (if configured) for:
   - Integrity violations
   - Critical system file modifications
   - Service failures

## Security Considerations

1. File Permissions:
   - Service runs as root to access system directories
   - Log files are created with 640 permissions
   - Configuration files are created with 640 permissions

2. Systemd Security:
   - ProtectSystem=strict
   - PrivateTmp=true
   - NoNewPrivileges=true
   - Other security directives enabled

3. Notifications:
   - Syslog messages use auth facility
   - Email notifications for critical events only
   - Webhook notifications support HTTPS

## Troubleshooting

1. Service fails to start:
   - Check systemd journal: `journalctl -u tampering-check@*.service`
   - Verify inotify-tools installation
   - Check directory permissions

2. Missing notifications:
   - Verify configuration in config.yml
   - Check mail configuration for email notifications
   - Verify webhook URL accessibility

3. High resource usage:
   - Adjust check_interval in config
   - Reduce number of monitored directories
   - Consider excluding high-churn directories

## Contributing

1. Fork the repository
2. Create your feature branch
3. Run the tests: `./tests/test_tampering.sh`
4. Commit your changes
5. Push to the branch
6. Create a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- inotify-tools developers
- systemd team
- YAML parser (yq) developers

