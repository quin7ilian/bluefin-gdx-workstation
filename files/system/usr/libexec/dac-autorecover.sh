#!/usr/bin/env bash
# Watchdog tick (run every ~20s by dac-autorecover.timer): if the Schiit
# Multibit (C-Media CM6631A, 0d8c:0004) is *actively failing* to enumerate
# through the KVM's USB hub, re-drive that hub to force a clean enumeration —
# the same proven recovery as `ujust reconnect-dac`. The 90-dac-wireplumber-
# nudge udev rule then brings up the sink once it enumerates.
#
# Catches the dynamic case the boot check can't: booting with the DAC off and
# turning it on (or a KVM switch-back) later. The pre-descriptor failure
# (`device descriptor read … error -32`) never creates a udev device, so there's
# no add event to hook — we detect it from the kernel log instead.
#
# Deliberately does NOTHING in the common cases:
#   - DAC present and working  → clear state, exit.
#   - KVM switched away        → no populated hub found, exit.
#   - DAC simply turned off     → no recent enumeration errors, exit.
# It only re-drives the hub when it sees real, recent enumeration failures on
# that hub, and gives up (with a cooldown) after MAX_TRIES so a device that
# genuinely needs a physical VBUS power-cycle doesn't cause an endless rebind
# loop (which would blink the keyboard/Yubikey forever).
set -uo pipefail

VID=0d8c
PID=0004
STATE=/run/dac-autorecover.state          # rebind attempt counter for this episode
COOLDOWN=/run/dac-autorecover.cooldown     # back-off marker after giving up
MAX_TRIES=3
COOLDOWN_MIN=5
LOOKBACK=40s                               # kernel-log window for "recent failures"

present() {
    local d
    for d in /sys/bus/usb/devices/*/; do
        [ "$(cat "$d/idVendor" 2>/dev/null)" = "$VID" ] &&
        [ "$(cat "$d/idProduct" 2>/dev/null)" = "$PID" ] && return 0
    done
    return 1
}

# (1) DAC is up → episode over, reset everything.
if present; then
    rm -f "$STATE" "$COOLDOWN"
    exit 0
fi

# (2) Identify the KVM hub: the top-level external hub (a <bus>-<port> node, not
#     a usbN root hub) with the most downstream devices. The KVM aggregates the
#     switched peripherals (keyboard, DAC, Yubikey…); a motherboard-internal hub
#     has few. If none is populated, the KVM is switched away — leave it alone.
hub=""
bestn=0
for d in /sys/bus/usb/devices/*/; do
    n="$(basename "$d")"
    [[ "$n" =~ ^[0-9]+-[0-9]+$ ]] || continue
    [ "$(cat "$d/bDeviceClass" 2>/dev/null)" = "09" ] || continue
    c="$(ls -d /sys/bus/usb/devices/"${n}".* 2>/dev/null | wc -l)"
    if [ "$c" -gt "$bestn" ]; then bestn="$c"; hub="$n"; fi
done
if [ -z "$hub" ]; then
    rm -f "$STATE"
    exit 0
fi

# (3) Is the DAC actively FAILING (vs simply turned off)? Look for recent
#     enumeration failures on this hub's ports in the kernel log.
if ! journalctl -k --since "-${LOOKBACK}" --no-pager 2>/dev/null \
     | grep -Eq "usb ${hub}[.-].*(unable to enumerate|error -32|error -71|not responding to setup|not accepting address)"; then
    rm -f "$STATE"          # DAC is off/unplugged — nothing wrong; reset episode.
    exit 0
fi

# (4) Failing. If we're in the post-give-up cooldown window, wait it out.
if [ -f "$COOLDOWN" ] && find "$COOLDOWN" -mmin -"$COOLDOWN_MIN" 2>/dev/null | grep -q .; then
    exit 0
fi

tries=0
[ -f "$STATE" ] && tries="$(cat "$STATE" 2>/dev/null || echo 0)"
[[ "$tries" =~ ^[0-9]+$ ]] || tries=0

if [ "$tries" -ge "$MAX_TRIES" ]; then
    : > "$COOLDOWN"          # start the back-off; reset the counter for next episode.
    rm -f "$STATE"
    echo "DAC still failing after ${MAX_TRIES} hub rebinds — backing off ${COOLDOWN_MIN}m; a physical USB replug (or a powered hub) may be needed." >&2
    exit 0
fi

echo "DAC failing to enumerate on hub ${hub} — re-driving it (rebind $((tries + 1))/${MAX_TRIES})."
echo "$hub" > /sys/bus/usb/drivers/usb/unbind
sleep 2
echo "$hub" > /sys/bus/usb/drivers/usb/bind
echo "$((tries + 1))" > "$STATE"
exit 0
