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
    # Copy our pre-populated WRX80 config.json into the plugin dir so all
    # channels (5 fans + 12 temps) are defined out of the box. Skip-if-exists
    # so any manual edits aren't clobbered on re-runs.
    plugin_config=/etc/coolercontrol/plugins/custom-device/config.json
    template=/usr/share/cc-bmc-bridge/config.json
    if [ -f "$plugin_config" ]; then
        echo "  $plugin_config already exists — leaving as-is (skip)."
        echo "  Template available at: $template"
    else
        echo "Copying pre-populated config from $template..."
        sudo install -m644 "$template" "$plugin_config"
        echo "  All 5 fan channels + 12 temp sensors defined; ready to use."
    fi
    echo
    echo "Restarting coolercontrold to load the plugin and migrate to /var/lib/coolercontrol/plugins..."
    sudo systemctl restart coolercontrold
    echo
    echo "Also silencing the liquidctl 'package not detected' warning"
    echo "(this workstation has no liquid cooling)..."
    just --justfile {{justfile()}} disable-liqctld
    echo
    echo "Done. Next steps:"
    echo "  - Open http://localhost:11987 to see the CoolerControl UI."
    echo "    The WRX80 BMC device with all 5 fans and 12 temp sensors"
    echo "    should appear automatically."
    echo "  - Configure fan curves in the UI under each fan channel."
    echo "    Suggested starting points:"
    echo "      /usr/share/cc-bmc-bridge/silent-curves-reference.md"
    echo "  - To edit channel definitions later (add FAN6/7, rename, etc.):"
    echo "      sudo \$EDITOR /etc/coolercontrol/plugins/custom-device/config.json"
    echo "      sudo systemctl restart coolercontrold"

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

# Disable CoolerControl's liquidctl integration in /etc/coolercontrol/config.toml.
# This workstation has no liquid cooling, and python3-liquidctl would require
# enabling EPEL (which we deliberately avoid — see AGENTS.md constraint #8).
# Without this, coolercontrold logs a "liquidctl package not detected" warning
# on every start and spawns liqctld as a subprocess that exits non-zero.
# Idempotent: only edits if liquidctl_integration is currently `true`.
disable-liqctld:
    #!/usr/bin/env bash
    set -euo pipefail
    config=/etc/coolercontrol/config.toml
    if [ ! -f "$config" ]; then
        echo "$config does not exist yet — coolercontrold may not have started for the first time."
        echo "Start coolercontrold once (sudo systemctl start coolercontrold), then re-run this command."
        exit 1
    fi
    if grep -qE '^liquidctl_integration = false' "$config"; then
        echo "liquidctl_integration is already false in $config — nothing to do."
        exit 0
    fi
    if ! grep -qE '^liquidctl_integration = true' "$config"; then
        echo "Could not find 'liquidctl_integration = true' in $config."
        echo "Either it has been hand-edited to a different value, or the setting moved in a"
        echo "newer CoolerControl release. Check $config manually."
        exit 1
    fi
    backup="${config}.bak-pre-liqctld-disable-$(date +%Y%m%d-%H%M%S)"
    echo "Backing up $config → $backup"
    sudo cp -a "$config" "$backup"
    echo "Flipping liquidctl_integration to false..."
    sudo sed -i 's/^liquidctl_integration = true$/liquidctl_integration = false/' "$config"
    if grep -qE '^liquidctl_integration = false' "$config"; then
        echo "Restarting coolercontrold..."
        sudo systemctl restart coolercontrold
        echo "Done. liquidctl warning should no longer appear on startup."
    else
        echo "WARNING: sed did not produce the expected result. Inspect $config and the backup."
        exit 1
    fi
