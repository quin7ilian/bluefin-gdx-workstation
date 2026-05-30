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
        echo "  5 fan channels + 12 temp sensors defined; ready to use."
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
    echo "    5 fans and 12 temp sensors should appear automatically."
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

# ─── Local AI models (Ramalama) ──────────────────────────────────────
# Three GPU-pinned llama.cpp servers via Ramalama (installed via Homebrew,
# NOT baked into the image — `brew install ramalama`):
#   - ramalama-coder        GPU1 :8081  Qwen3-Coder-30B-A3B-Instruct (MoE,
#                           tool-calling). Zed built-in-agent default_model +
#                           commit_message_model (wired in ~/.config/zed/settings.json).
#   - ramalama-autocomplete GPU0 :8080  Qwen2.5-Coder-7B-Instruct. DUAL-USE:
#                           Zed edit prediction (FIM via /v1/completions,
#                           prompt_format qwen — a SEPARATE Zed subsystem) AND
#                           the Hermes claim-discipline flagger (chat on :8080).
#   - ramalama-verifier     GPU0 :8082  Granite Guardian 3.3 8B. Hermes
#                           claim-discipline groundedness verifier (NOT Zed).
#
# Deliberately NOT autostarted: this box isn't headless and the 4090s are
# also the compute GPUs for HPO/ML. Start when coding; `ujust stop-local-ai`
# frees both cards (~46GB of VRAM) before an HPO run. First `start-local-ai`
# pulls the models (~17GB + ~4.5GB + ~5GB); later starts are instant (cached
# in ~/.local/share/ramalama). GPU pinning is via CUDA_VISIBLE_DEVICES —
# without it, llama.cpp tensor-splits one model across both cards (not wanted).

# Start both local AI servers (coder on GPU1, autocomplete on GPU0).
# Idempotent: skips a server that's already running, (re)creates otherwise.
start-local-ai:
    #!/usr/bin/env bash
    set -euo pipefail
    export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"
    command -v ramalama >/dev/null 2>&1 || { echo "ramalama not found — install it first: brew install ramalama"; exit 1; }
    _start() {
        name="$1"; gpu="$2"; port="$3"; model="$4"
        if [ -n "$(podman ps -q --filter name=^${name}$ --filter status=running)" ]; then
            echo "  $name already running (GPU$gpu :$port)"
            return 0
        fi
        podman rm -f "$name" >/dev/null 2>&1 || true
        echo "  starting $name (GPU$gpu :$port) — first run pulls the model, please wait..."
        CUDA_VISIBLE_DEVICES="$gpu" ramalama serve -d --name "$name" -p "$port" --ngl auto "$model"
    }
    _start ramalama-coder        1 8081 hf://unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF
    _start ramalama-autocomplete 0 8080 hf://Qwen/Qwen2.5-Coder-7B-Instruct-GGUF
    _start ramalama-verifier     0 8082 hf://ibm-granite/granite-guardian-3.3-8b-GGUF
    echo
    echo "Local AI up:"
    echo "  coder        :8081 (GPU1) — Zed built-in agent + commit messages"
    echo "  autocomplete :8080 (GPU0) — Zed edit prediction + Hermes flagger"
    echo "  verifier     :8082 (GPU0) — Hermes claim-discipline groundedness check"

# Stop both local AI servers and free both 4090s (e.g. before an HPO run).
stop-local-ai:
    #!/usr/bin/env bash
    set -euo pipefail
    for n in ramalama-coder ramalama-autocomplete ramalama-verifier; do
        if [ -n "$(podman ps -aq --filter name=^${n}$)" ]; then
            podman stop "$n" >/dev/null 2>&1 || true
            podman rm -f "$n" >/dev/null 2>&1 || true
            echo "  stopped $n"
        else
            echo "  $n not running"
        fi
    done
    echo "Both 4090s freed for compute."

# Show local AI server + GPU status.
status-local-ai:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Ramalama containers ==="
    podman ps -a --filter name=ramalama-coder --filter name=ramalama-autocomplete --filter name=ramalama-verifier || true
    echo
    echo "=== GPU memory ==="
    nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv,noheader || true
