#!/usr/bin/env bash
# Re-probe WirePlumber so a freshly re-enumerated USB DAC (Schiit Multibit /
# C-Media CM6631A, 0d8c:0004) gets a node + sink. Started detached by
# dac-wireplumber-nudge.service, which the 90-dac-wireplumber-nudge.rules udev
# rule pulls in when the DAC's ALSA control device appears after a KVM switch.
#
# Why this is needed: the kernel usually brings the ALSA card up after the
# switch-back enumeration storm, but WirePlumber sees the device appear amid the
# -71 errors, fails to create a node, and never retries. Restarting WirePlumber
# makes it re-probe and the sink appears (verified live). `ujust reconnect-dac`
# is the manual equivalent of this script.
set -uo pipefail

VID=0d8c
PID=0004

# Debounce: only one nudge in flight. If we can't take the lock, an earlier add
# event in the same storm is already handling it — coalesce and exit.
exec 9>/run/dac-wireplumber-nudge.lock
flock -n 9 || exit 0

# Let the enumeration storm settle before re-probing — the card can flap for
# several seconds on a KVM switch-back, and re-probing mid-flap just re-fails.
sleep 5

# Bail if the DAC didn't actually end up with an ALSA card; nothing to pick up
# (e.g. it never got past the pre-descriptor enumeration failures this time).
grep -qix "${VID}:${PID}" /proc/asound/card*/usbid 2>/dev/null || exit 0

# Restart WirePlumber for every user with a live PipeWire session. udev/systemd
# run this as root; WirePlumber is per-user, reached via its systemd user
# manager (`--machine=<user>@.host`). No username is hard-coded — we enumerate
# active PipeWire runtime sockets, matching this image's no-baked-identity rule.
rc=0
for run in /run/user/*; do
    [ -S "$run/pipewire-0" ] || continue
    uid=$(basename "$run")
    user=$(getent passwd "$uid" | cut -d: -f1)
    [ -n "$user" ] || continue
    if systemctl --machine="${user}@.host" --user restart wireplumber; then
        echo "Re-probed WirePlumber for ${user} (uid ${uid})."
    else
        echo "WARNING: failed to restart WirePlumber for ${user} (uid ${uid})." >&2
        rc=1
    fi
done
exit "$rc"
