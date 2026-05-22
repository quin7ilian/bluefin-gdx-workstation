# vim: set ft=make :

# Enable and start the Insync sync engine as a systemd user service.
# This launches the sync engine in the background without opening the
# GUI window. Use the Insync app from your menu (or `insync show`) to
# configure your account.
enable-insync:
    #!/usr/bin/env bash
    set -euo pipefail
    systemctl --user daemon-reload
    systemctl --user enable --now insync.service
    echo
    echo "Insync sync engine started in the background."
    echo "To configure (link Google account, set sync folder):"
    echo "  - Launch the Insync GUI from your app menu, or run: insync show"
    echo "  - In Preferences, UNCHECK 'Start Insync at startup'"
    echo "    (the systemd unit handles autostart now — leaving both on"
    echo "     causes a duplicate-launch race at login)."

# Disable and stop the Insync user service.
disable-insync:
    systemctl --user disable --now insync.service

# Show the Insync user service status and recent journal.
status-insync:
    systemctl --user status insync.service || true
    echo
    journalctl --user -u insync.service -n 30 --no-pager
