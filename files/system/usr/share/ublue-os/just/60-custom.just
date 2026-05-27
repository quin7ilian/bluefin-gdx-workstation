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

# Install the cc-plugin-custom-device CoolerControl plugin. The plugin
# is NOT baked into the image — coolercontrold 4.x migrates
# /etc/coolercontrol/plugins → symlink to /var/lib/coolercontrol/plugins
# on first start, and a build-time install creates an ostree /etc merge
# conflict on every subsequent image update. Installing here, post-rebase,
# keeps the plugin contents in /var (which persists across image updates)
# and the image's /etc clean. Run this once after a fresh rebase; the
# manifest.toml you edit (per-channel ipmitool commands for the WRX80
# BMC) lives in /var and survives upgrades.
install-cc-plugin:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -L /etc/coolercontrol/plugins ] && [ -d /var/lib/coolercontrol/plugins/custom-device ]; then
        echo "cc-plugin-custom-device is already installed and wired up correctly."
        echo "  /etc/coolercontrol/plugins -> $(readlink /etc/coolercontrol/plugins)"
        echo "  /var/lib/coolercontrol/plugins/custom-device/ exists."
        echo
        echo "Nothing to do. If you want to refresh the plugin binary/UI from"
        echo "upstream while keeping your customized manifest.toml, run:"
        echo "  ujust upgrade-cc-plugin"
        echo "To force a clean reinstall (loses your manifest.toml customizations),"
        echo "remove /var/lib/coolercontrol/plugins/custom-device and re-run this command."
        exit 0
    fi
    if [ -d /var/lib/coolercontrol/plugins/custom-device ] && [ ! -e /etc/coolercontrol/plugins ]; then
        echo "Plugin content already in /var (from a previous install), but the"
        echo "/etc/coolercontrol/plugins symlink is missing — re-creating it."
        sudo systemctl stop coolercontrold
        sudo ln -s /var/lib/coolercontrol/plugins /etc/coolercontrol/plugins
        sudo systemctl start coolercontrold
        echo "Done — daemon restarted, symlink restored."
        exit 0
    fi
    echo "Downloading cc-plugin-custom-device install.sh from upstream..."
    tmp="$(mktemp /tmp/cc-plugin-install-XXXXXX.sh)"
    trap 'rm -f "$tmp"' EXIT
    curl -fsSL https://gitlab.com/coolercontrol/cc-plugin-custom-device/-/raw/main/install.sh -o "$tmp"
    echo "Running install.sh (sudo required — installs to /etc/coolercontrol/plugins/custom-device/)..."
    sudo sh "$tmp"
    echo
    echo "Restarting coolercontrold to load the plugin and migrate to /var/lib/coolercontrol/plugins..."
    sudo systemctl restart coolercontrold
    echo
    echo "Done. Next steps:"
    echo "  - Open http://localhost:11987 to see the CoolerControl UI"
    echo "  - Edit /etc/coolercontrol/plugins/custom-device/manifest.toml"
    echo "    (a symlink into /var/lib/coolercontrol/plugins) to add your"
    echo "    per-channel ipmitool commands for the WRX80 BMC. Set"
    echo "    privileged = true on commands that need root."
    echo "  - sudo systemctl restart coolercontrold after editing"

# Refresh cc-plugin-custom-device to the latest upstream version while
# preserving the customized manifest.toml (the per-channel ipmitool
# commands for the WRX80 BMC). The upstream install.sh overwrites
# every file under custom-device/, so we back up manifest.toml first
# and restore it afterwards. Use this when a new plugin release fixes
# a bug or adds features.
upgrade-cc-plugin:
    #!/usr/bin/env bash
    set -euo pipefail
    plugin_dir=/var/lib/coolercontrol/plugins/custom-device
    manifest="$plugin_dir/manifest.toml"
    if [ ! -d "$plugin_dir" ]; then
        echo "No existing plugin install at $plugin_dir."
        echo "Run \`ujust install-cc-plugin\` for the first-time install."
        exit 1
    fi
    backup="$(mktemp /tmp/cc-plugin-manifest-XXXXXX.toml)"
    tmp_install="$(mktemp /tmp/cc-plugin-install-XXXXXX.sh)"
    trap 'rm -f "$backup" "$tmp_install"' EXIT
    echo "Backing up existing manifest.toml to $backup..."
    sudo cp -a "$manifest" "$backup"
    echo "Downloading latest install.sh from upstream..."
    curl -fsSL https://gitlab.com/coolercontrol/cc-plugin-custom-device/-/raw/main/install.sh -o "$tmp_install"
    echo "Stopping coolercontrold so the running plugin doesn't hold open files..."
    sudo systemctl stop coolercontrold
    echo "Running install.sh (will overwrite plugin files including manifest.toml)..."
    sudo sh "$tmp_install"
    echo "Restoring your manifest.toml from backup..."
    sudo cp -a "$backup" "$manifest"
    echo "Restarting coolercontrold..."
    sudo systemctl start coolercontrold
    echo
    echo "Done. Plugin binary/UI upgraded; your manifest.toml customizations are preserved."
    echo "Check the new binary is loaded:"
    echo "  journalctl -u coolercontrold -b -n 20 | grep -i custom-device"
