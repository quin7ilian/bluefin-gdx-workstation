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

# Enable and start the Proton Mail Bridge user service. Bridge runs in
# the background (GUI hidden via --no-window) and exposes IMAP on
# localhost:1143 and SMTP on localhost:1025 for Thunderbird/Evolution.
#
# First-run requirement: launch "Proton Mail Bridge" from your app menu
# BEFORE enabling this unit. Sign in there once and let Bridge cache
# your credentials in the GNOME keyring. After that, the systemd unit
# can start the background process at every login without prompting.
# (If you enable this before first-run sign-in, the unit will start,
# fail to find credentials, and restart in a loop — harmless but noisy
# in the journal until you do the GUI sign-in.)
enable-protonmail-bridge:
    #!/usr/bin/env bash
    set -euo pipefail
    systemctl --user daemon-reload
    systemctl --user enable --now protonmail-bridge.service
    echo
    echo "Proton Mail Bridge started in the background."
    echo "If this is a fresh install, launch 'Proton Mail Bridge' from"
    echo "the app menu and sign in once so credentials land in the keyring."
    echo "Then point Thunderbird at imap://127.0.0.1:1143 / smtp://127.0.0.1:1025."

# Disable and stop the Proton Mail Bridge user service.
disable-protonmail-bridge:
    systemctl --user disable --now protonmail-bridge.service

# Show the Proton Mail Bridge user service status and recent journal.
status-protonmail-bridge:
    systemctl --user status protonmail-bridge.service || true
    echo
    journalctl --user -u protonmail-bridge.service -n 30 --no-pager

# Apply the Spotify Flatpak window-decoration workaround.
#
# IMPORTANT: this does NOT give you a clean Spotify-themed integrated
# header. There is no upstream path to that today
# (flathub/com.spotify.Client #317, open since Nov 2024). The choice is:
#   - Default Wayland Ozone (do nothing): Spotify draws its OWN client-
#     side decoration as a blue/cyan unstyled bar (Spotify's intent,
#     they just never styled it). No GNOME bar on top.
#   - This workaround (X11 fallback): Spotify runs on XWayland, drops
#     its own CSD, and gets GNOME's normal server-side titlebar on top.
#     Trades "ugly blue bar" for "standard GNOME titlebar".
#
# Pick whichever you prefer aesthetically. Run `ujust unfix-spotify-
# decoration` to revert to the Wayland/blue-bar default.
#
# Writes ~/.var/app/com.spotify.Client/config/spotify-flags.conf and
# sets a per-user flatpak override. Idempotent.
fix-spotify-decoration:
    #!/usr/bin/env bash
    set -euo pipefail
    flags_dir="$HOME/.var/app/com.spotify.Client/config"
    flags_file="$flags_dir/spotify-flags.conf"
    mkdir -p "$flags_dir"
    # Avoid a heredoc — just preserves the 4-space indent in the recipe
    # body and a leading-whitespace EOF terminator wouldn't match.
    printf '%s\n%s\n' \
      '--ozone-platform=x11' \
      '--disable-features=UseOzonePlatform' \
      > "$flags_file"
    flatpak override --user \
      --nosocket=wayland \
      --nosocket=fallback-x11 \
      --socket=x11 \
      com.spotify.Client
    echo
    echo "Applied X11 fallback for Spotify."
    echo "  Wrote: $flags_file"
    echo "  Flatpak override: wayland & fallback-x11 sockets removed, x11 added."
    echo
    echo "Restart Spotify for the change to take effect."
    echo "You should now see GNOME's standard titlebar instead of the blue CSD."

# Revert the Spotify decoration fix — back to Wayland/Ozone (blue CSD).
unfix-spotify-decoration:
    #!/usr/bin/env bash
    set -euo pipefail
    flags_file="$HOME/.var/app/com.spotify.Client/config/spotify-flags.conf"
    [ -f "$flags_file" ] && rm -f "$flags_file" && echo "Removed $flags_file."
    flatpak override --user --reset com.spotify.Client
    echo "Reset flatpak overrides for com.spotify.Client."
    echo "Restart Spotify; the unstyled blue CSD will return."

# ─── Chromium (Flatpak) + 1Password bridge + hardware video decode ────
# Chromium ships as a Flatpak, NOT a host RPM, for a hardware reason: this base
# is CentOS Stream 10, whose mesa is built WITHOUT the gallium-VA frontend
# (libgallium-*.so exports no __vaDriverInit*, and no EL10 repo — base, EPEL,
# negativo17, RPM Fusion — ships an AMD mesa-va-drivers). So a host-native
# Chromium would get NO hardware video decode on the W7500. The Flatpak's
# org.freedesktop.Platform.GL.default runtime bundles its OWN
# radeonsi_drv_video.so, so Chromium decodes in hardware against the amdgpu
# render node with zero host-mesa changes — the same reason the Flatpak
# Firefox HW-decodes and a host RPM browser wouldn't. (Trivalent itself is
# not installable here: its RPM needs glibc >= 2.42 and CS10 ships 2.39.)
#
# 1Password lives on the host (RPM) while Chromium is sandboxed, so the extension
# needs a sandbox->host bridge. Three per-user pieces (they live here in ujust,
# not baked into the image, because they land in $HOME/.var/app — the image
# only writes /usr and /etc):
#   1. a wrapper that `flatpak-spawn --host`s the host 1Password-BrowserSupport
#      (byte-identical to the Firefox one).
#   2. a native-messaging manifest. NOTE the Chromium/Firefox divergence:
#      Chromium uses "allowed_origins" with chrome-extension:// IDs (NOT
#      Firefox's "allowed_extensions" with {uuid}s) and reads it from
#      config/chromium/NativeMessagingHosts/ — a different path AND format.
#      The origins below are copied verbatim from the manifest 1Password
#      generates for a NATIVE Chromium, so they're authoritative.
#   3. a flatpak override granting talk access to org.freedesktop.Flatpak —
#      exactly what `flatpak-spawn --host` needs (the "override command").
# Plus 1Password's allowlist must contain `flatpak-session-helper`: for ANY
# flatpak browser, 1Password sees the connection arriving via the session
# helper, not as "chromium", so THAT is the operative entry. We add it
# idempotently at runtime rather than baking files/system/etc/1password/...,
# because that path already exists in the base image's /usr/etc and a
# user-modified /etc copy wins the ostree 3-way merge anyway (constraint #11).
#
# Idempotent — safe to re-run. After it, verify HW decode at chrome://gpu.
setup-chromium:
    #!/usr/bin/env bash
    set -euo pipefail
    APP=org.chromium.Chromium

    echo "==> Installing Chromium (Flathub, system) if missing..."
    if flatpak info "$APP" >/dev/null 2>&1; then
        echo "    Chromium already installed ($(flatpak info "$APP" --show-ref 2>/dev/null || echo "$APP"))."
    else
        flatpak install -y flathub "$APP"
    fi

    base="$HOME/.var/app/$APP"
    wrap="$base/data/bin/1password-wrapper.sh"
    nmdir="$base/config/chromium/NativeMessagingHosts"
    manifest="$nmdir/com.1password.1password.json"

    echo "==> Writing the 1Password sandbox->host wrapper..."
    mkdir -p "$(dirname "$wrap")"
    # printf, not a heredoc: just preserves the recipe's 4-space indent, so a
    # heredoc EOF terminator wouldn't match (same as fix-spotify-decoration).
    printf '%s\n' \
      '#!/bin/bash' \
      'if [ "${container-}" = flatpak ]; then' \
      '    flatpak-spawn --host /opt/1Password/1Password-BrowserSupport "$@"' \
      'else' \
      '    exec /opt/1Password/1Password-BrowserSupport "$@"' \
      'fi' \
      > "$wrap"
    chmod +x "$wrap"

    echo "==> Writing the Chromium native-messaging manifest..."
    mkdir -p "$nmdir"
    printf '%s\n' \
      '{' \
      '  "name": "com.1password.1password",' \
      '  "description": "1Password BrowserSupport",' \
      "  \"path\": \"$wrap\"," \
      '  "type": "stdio",' \
      '  "allowed_origins": [' \
      '    "chrome-extension://hjlinigoblmkhjejkmbegnoaljkphmgo/",' \
      '    "chrome-extension://bkpbhnjcbehoklfkljkkbbmipaphipgl/",' \
      '    "chrome-extension://gejiddohjgogedgjnonbofjigllpkmbf/",' \
      '    "chrome-extension://khgocmkkpikpnmmkgmdnfckapcdkgfaf/",' \
      '    "chrome-extension://aeblfdkhhhdcdjpifhhbdiojplfjncoa/",' \
      '    "chrome-extension://dppgmdbiimibapkepcbdbmkaabgiofem/"' \
      '  ]' \
      '}' \
      > "$manifest"

    echo "==> Applying the flatpak override (talk to org.freedesktop.Flatpak)..."
    flatpak override --user --talk-name=org.freedesktop.Flatpak "$APP"

    echo "==> Ensuring 1Password's allowlist trusts flatpak browsers..."
    allow=/etc/1password/custom_allowed_browsers
    if [ -f "$allow" ] && grep -qE '^[[:space:]]*flatpak-session-helper[[:space:]]*$' "$allow"; then
        echo "    'flatpak-session-helper' already present in $allow."
    else
        echo "    Adding 'flatpak-session-helper' to $allow (needs sudo)..."
        echo "flatpak-session-helper" | sudo tee -a "$allow" >/dev/null
    fi

    echo
    echo "Done. Next steps:"
    echo "  1) Restart Chromium so it re-reads the manifest:"
    echo "       flatpak kill $APP     # then relaunch Chromium"
    echo "  2) Install the 1Password extension in Chromium (Chrome Web Store)."
    echo "     If you already use 1Password with Firefox, desktop browser"
    echo "     integration is on and Chromium should connect on launch. If it says"
    echo "     'browser not detected', fully quit and reopen the 1Password app."
    echo "  3) Confirm hardware video decode at  chrome://gpu"
    echo "     ('Video Decode' should list a hardware-accelerated codec). If it's"
    echo "     software, enable hardware-accelerated video decode in chrome://flags,"
    echo "     or launch with --enable-features=VaapiVideoDecoder,VaapiVideoDecodeLinuxGL."

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
    changed=0

    # ─── Step 1: plugin binary/manifest/UI ──────────────────────────────
    if [ -L /etc/coolercontrol/plugins ] && [ -d /var/lib/coolercontrol/plugins/custom-device ]; then
        echo "Plugin binary already installed and wired up."
        echo "  /etc/coolercontrol/plugins -> $(readlink /etc/coolercontrol/plugins)"
        echo "  /var/lib/coolercontrol/plugins/custom-device/ exists."
        echo "  (To refresh binary/UI: ujust upgrade-cc-plugin)"
    elif [ -d /var/lib/coolercontrol/plugins/custom-device ] && [ ! -e /etc/coolercontrol/plugins ]; then
        echo "Plugin content in /var but /etc symlink missing — re-creating."
        sudo systemctl stop coolercontrold
        sudo ln -s /var/lib/coolercontrol/plugins /etc/coolercontrol/plugins
        sudo systemctl start coolercontrold
        changed=1
    else
        echo "Downloading cc-plugin-custom-device install.sh from upstream..."
        tmp="$(mktemp /tmp/cc-plugin-install-XXXXXX.sh)"
        trap 'rm -f "$tmp"' EXIT
        curl -fsSL https://gitlab.com/coolercontrol/cc-plugin-custom-device/-/raw/main/install.sh -o "$tmp"
        echo "Running install.sh (installs to /etc/coolercontrol/plugins/custom-device/)..."
        sudo sh "$tmp"
        changed=1
    fi

    # ─── Step 2: WRX80 channel config.json ──────────────────────────────
    plugin_config=/etc/coolercontrol/plugins/custom-device/config.json
    template=/usr/share/cc-bmc-bridge/config.json
    if [ -f "$plugin_config" ]; then
        echo "Channel config already at $plugin_config — leaving as-is (skip)."
        echo "  Template: $template"
    else
        echo "Deploying pre-populated config from $template..."
        sudo install -m644 "$template" "$plugin_config"
        echo "  7 fan channels + 12 temp sensors defined; ready to use."
        changed=1
    fi

    # ─── Step 2b: flip plugin to privileged mode ────────────────────────
    # Upstream manifest.toml ships `privileged = false` → plugin runs as
    # unprivileged cc-plugin-user, which can't read /dev/ipmi0. Every
    # ipmitool call fails silently → temps don't populate, fan writes
    # don't work. Flip to privileged = true. Idempotent.
    plugin_manifest=/etc/coolercontrol/plugins/custom-device/manifest.toml
    if [ -f "$plugin_manifest" ]; then
        if grep -qE '^privileged = false' "$plugin_manifest"; then
            echo "Flipping plugin to privileged mode (needed for /dev/ipmi0 access)..."
            sudo sed -i 's/^privileged = false$/privileged = true/' "$plugin_manifest"
            changed=1
        elif grep -qE '^privileged = true' "$plugin_manifest"; then
            echo "Plugin manifest already set to privileged = true."
        else
            echo "WARNING: $plugin_manifest has no 'privileged' line in the expected format."
            echo "  Check it manually — upstream may have changed the manifest schema."
        fi
    fi

    # ─── Step 3: restart daemon if anything changed ─────────────────────
    if [ "$changed" -eq 1 ]; then
        echo "Restarting coolercontrold to apply changes..."
        sudo systemctl restart coolercontrold
    fi

    # ─── Step 4: silence liquidctl warning (idempotent) ─────────────────
    echo
    echo "Ensuring liquidctl integration is disabled..."
    just --justfile {{justfile()}} disable-liqctld

    echo
    echo "Done. Next steps:"
    echo "  - Open http://localhost:11987 — the WRX80 BMC device with"
    echo "    7 fans and 12 temp sensors should appear automatically."
    echo "  - Configure fan curves in the UI per:"
    echo "      /usr/share/cc-bmc-bridge/silent-curves-reference.md"
    echo "  - To edit channels later:"
    echo "      sudo \$EDITOR /etc/coolercontrol/plugins/custom-device/config.json"
    echo "      sudo systemctl restart coolercontrold"

# Refresh cc-plugin-custom-device to the latest upstream version while
# preserving local manifest.toml customizations (specifically:
# `privileged = true` which we flip from upstream's default of false;
# without it the plugin can't read /dev/ipmi0). The upstream install.sh
# overwrites every file under custom-device/, so we back up manifest.toml
# first and restore it afterwards. config.json is in /var and untouched
# by install.sh, so it doesn't need backup/restore.
# Use this when a new plugin release fixes a bug or adds features.
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

# Force-refresh the cc-plugin-custom-device config.json from the image's
# current /usr/share/cc-bmc-bridge/config.json template, backing up the
# existing one. Use this when a new image build ships an updated channel
# definition (e.g. iteration 2 added FAN6/FAN7) and you want to adopt it
# without losing the old definition entirely.
#
# This LOSES any UI customizations you've made to the existing config —
# use upgrade-cc-plugin's pattern of diff'ing the backup if you've made
# manual edits worth preserving.
refresh-bmc-channels:
    #!/usr/bin/env bash
    set -euo pipefail
    template=/usr/share/cc-bmc-bridge/config.json
    target=/etc/coolercontrol/plugins/custom-device/config.json
    if [ ! -f "$template" ]; then
        echo "Template missing at $template — not in this image build."
        exit 1
    fi
    if [ ! -e "$target" ]; then
        echo "$target doesn't exist — run \`ujust install-cc-plugin\` first."
        exit 1
    fi
    if cmp -s "$template" "$target"; then
        echo "$target already matches the template — nothing to refresh."
        exit 0
    fi
    backup="${target}.bak-pre-refresh-$(date +%Y%m%d-%H%M%S)"
    echo "Backing up existing config → $backup"
    sudo cp -a "$target" "$backup"
    echo "Deploying new template from $template..."
    sudo install -m644 "$template" "$target"
    echo "Restarting coolercontrold to load the new channel definitions..."
    sudo systemctl restart coolercontrold
    echo
    echo "Done. New channels (if any) appear in the CoolerControl UI."
    echo "Diff your old config: diff $backup $target"
    echo "If you had manual edits, merge them back and:"
    echo "  sudo \$EDITOR $target"
    echo "  sudo systemctl restart coolercontrold"

# Disable CoolerControl's liquidctl integration in /etc/coolercontrol/config.toml.
# This workstation has no liquid cooling, and python3-liquidctl would require
# enabling EPEL (which we deliberately avoid — see AGENTS.md constraint #7).
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

# ─── Local AI models (Ramalama, gated) ───────────────────────────────
# Two GPU-pinned llama.cpp servers via Ramalama (brew-installed, NOT baked
# into the image), managed as systemd user services under local-ai.target
# and gated by the flag file ~/.config/local-ai/enabled:
#   - ramalama-detector  GPU1 :8081  phi-4 — the Claude Code curator model
#                        (background memory/skill detection over its OpenAI API).
#   - ramalama-coder     GPU0 :8082  Codestral 22B — Zed edit-prediction (FIM
#                        autocomplete via /v1/completions, prompt_format codestral)
#                        AND commit-message generation (/v1/chat/completions).
#
# Default is AI MODE: both models auto-start at login, auto-restart on crash,
# and survive reboot. Before a heavy HPO run, `ujust toggle-ai-mode` flips to
# HPO MODE — both models stop and STAY off (no auto-restart, no return on
# reboot) until you toggle back, freeing both 4090s. The flag is the hard gate
# (ConditionPathExists on every unit); local-ai.target groups them so one
# toggle governs all present and future local GPU models. First start pulls the
# models into ~/.local/share/ramalama (~9GB + ~13GB); later starts are instant.

# Flip between AI MODE (local models on) and HPO MODE (off — both 4090s freed).
toggle-ai-mode:
    #!/usr/bin/env bash
    set -euo pipefail
    flag="$HOME/.config/local-ai/enabled"
    if [ -f "$flag" ]; then
        # → HPO MODE. Remove the gate FIRST so a queued/boot start can't slip
        # through it, then stop the target (PartOf propagates to the services).
        rm -f "$flag"
        systemctl --user stop local-ai.target
        podman rm -f ramalama-detector ramalama-coder >/dev/null 2>&1 || true
        echo "HPO MODE — local AI models stopped; both 4090s freed for compute."
    else
        # → AI MODE.
        mkdir -p "$(dirname "$flag")"
        touch "$flag"
        # Idempotently enable so the wants symlinks exist (needed on a fresh
        # image where nothing has enabled them yet): local-ai.target into
        # default.target so AI mode survives reboot, and each service into
        # local-ai.target. Then start the target.
        systemctl --user enable local-ai.target ramalama-detector.service ramalama-coder.service >/dev/null 2>&1 || true
        systemctl --user start local-ai.target
        echo "AI MODE — local AI models starting (phi-4 :8081, Codestral :8082)."
        echo "First start pulls the models; watch progress with: ujust status-ai-mode"
    fi

# Show the current mode (AI vs HPO), the unit states, and GPU usage.
status-ai-mode:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -f "$HOME/.config/local-ai/enabled" ]; then
        echo "Mode: AI MODE  (local models enabled)"
    else
        echo "Mode: HPO MODE (local models gated off)"
    fi
    echo
    systemctl --user list-units --all --no-legend --no-pager 'local-ai.target' 'ramalama-*.service' || true
    echo
    nvidia-smi --query-gpu=index,name,memory.used,memory.free,memory.total --format=csv,noheader || true

# ─── USB DAC (Schiit Multibit) reconnect ─────────────────────────────
# Recover the DAC when it has no sink after a KVM switch or at boot. Three
# failure modes, handled in escalating order:
#   1. Enumerated but no sink — WirePlumber missed it during the messy re-attach.
#      Fix: restart WirePlumber. (The 90-dac-wireplumber-nudge udev rule does
#      this automatically on reconnect; this is the manual equivalent.)
#   2. Enumerated but no ALSA card — reset the device's USB port (authorized
#      toggle), then re-probe.
#   3. Not enumerated AT ALL — the pre-descriptor failure (`device descriptor
#      read … error -32` through the KVM's Genesys hub). The host never learns
#      it's a DAC, so the usbcore.quirks karg can't help and a port-disable
#      toggle isn't enough (it doesn't cut VBUS). What works (verified on this
#      box) is unbind/rebind of the whole hub the DAC sits on, which forces a
#      fresh enumeration of its port. Peripherals on that hub blink briefly.
#
# Bind this to a GNOME keyboard shortcut for one-tap recovery. Pass hub=3-1
# (find it with `lsusb -t`) to force which hub is re-driven if auto-detect is
# ever wrong.
reconnect-dac hub="":
    #!/usr/bin/env bash
    set -euo pipefail
    VID=0d8c PID=0004

    # The DAC's USB sysfs node by VID:PID, if it's on the bus at all.
    dac=""
    for d in /sys/bus/usb/devices/*/; do
        [ "$(cat "$d/idVendor" 2>/dev/null)" = "$VID" ] || continue
        [ "$(cat "$d/idProduct" 2>/dev/null)" = "$PID" ] || continue
        dac="$(basename "$d")"; break
    done

    if grep -qix "${VID}:${PID}" /proc/asound/card*/usbid 2>/dev/null; then
        echo "DAC present with an ALSA card — re-probing WirePlumber only."
    elif [ -n "$dac" ]; then
        echo "DAC on the bus ($dac) but no ALSA card — resetting its USB port..."
        echo 0 | sudo tee "/sys/bus/usb/devices/$dac/authorized" >/dev/null
        echo 1 | sudo tee "/sys/bus/usb/devices/$dac/authorized" >/dev/null
        sleep 3
    else
        # Mode 3: re-drive the hub the DAC lives on to force re-enumeration.
        kvmhub="{{hub}}"
        if [ -z "$kvmhub" ]; then
            # Auto-detect: the KVM hub is the top-level external hub (a
            # <bus>-<port> node, not a usbN root hub) with the most downstream
            # devices — the KVM aggregates the switched peripherals (keyboard,
            # DAC, Yubikey…), unlike a motherboard-internal hub.
            bestn=-1
            for d in /sys/bus/usb/devices/*/; do
                n="$(basename "$d")"
                [[ "$n" =~ ^[0-9]+-[0-9]+$ ]] || continue
                [ "$(cat "$d/bDeviceClass" 2>/dev/null)" = "09" ] || continue
                c="$(ls -d /sys/bus/usb/devices/"${n}".* 2>/dev/null | wc -l)"
                if [ "$c" -gt "$bestn" ]; then bestn="$c"; kvmhub="$n"; fi
            done
        fi
        if [ -z "${kvmhub:-}" ] || [ ! -e "/sys/bus/usb/devices/$kvmhub" ]; then
            echo "Couldn't find a hub to re-drive — is the KVM switched to this PC?"
            echo "If so:  lsusb -t  to find the DAC's hub, then:  ujust reconnect-dac hub=3-1"
            exit 1
        fi
        echo "DAC not enumerated — re-driving its USB hub ($kvmhub) to force re-enumeration."
        echo "  (Keyboard / mouse / Yubikey on that hub will blink for a few seconds.)"
        echo "$kvmhub" | sudo tee /sys/bus/usb/drivers/usb/unbind >/dev/null
        sleep 2
        echo "$kvmhub" | sudo tee /sys/bus/usb/drivers/usb/bind   >/dev/null
        sleep 5
        if grep -qix "${VID}:${PID}" /proc/asound/card*/usbid 2>/dev/null || lsusb 2>/dev/null | grep -qi "${VID}:${PID}"; then
            echo "DAC re-enumerated."
        else
            echo ">>> DAC STILL ABSENT after the hub rebind."
            echo "    This is the hard pre-descriptor failure; the reliable cure is a"
            echo "    VBUS power-cycle — a physical USB replug, or a powered hub between"
            echo "    the KVM and the DAC."
            exit 1
        fi
    fi

    systemctl --user restart wireplumber
    echo "WirePlumber re-probed. Verify:  wpctl status | grep -iE 'cm6631|multibit'"
