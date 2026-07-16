#!/usr/bin/env bash
# cc-bmc-bridge-start.sh
#
# Companion-service ExecStart for coolercontrol-bmc-bridge.service.
# Runs BEFORE coolercontrold.service so manual mode is active before
# CoolerControl issues any duty writes.
#
# Strategy: read the BMC's current duty register (which holds whatever
# the BMC's auto-curve currently has set), write those SAME values to
# the manual register, then flip FAN1-7 to manual mode. When mode flips,
# manual mode immediately latches the same duties — no fan-speed jump.
#
# See cc-set-fan-duty.sh for the 0x00/0x01 → 0x05 rationale and the
# fan-index → physical mapping.

set -euo pipefail

# Take the duty-writer lock (shared with cc-set-fan-duty.sh) so the register
# write + shadow seed below can't interleave with a duty write. Nothing else
# touches the BMC this early — coolercontrold and its plugin start AFTER us
# (Before=coolercontrold.service) — but this keeps the invariant clean.
exec 200>/run/cc-bmc-fan.lock
flock -x 200

# Read current duty register
current=$(ipmitool raw 0x3a 0xda)
read -ra bytes <<< "$current"
(( ${#bytes[@]} == 16 )) || {
    echo "expected 16 bytes from 0x3a 0xda, got ${#bytes[@]}: '$current'" >&2
    exit 1
}

# Sanitise: 0x05 floor on unused positions 7-15; defensive clamp on 0-6.
for i in 7 8 9 10 11 12 13 14 15; do
    bytes[$i]="05"
done
for i in 0 1 2 3 4 5 6; do
    val=$((16#${bytes[$i]}))
    (( val < 2 )) && bytes[$i]="05"
done

write_args=()
for byte in "${bytes[@]}"; do
    write_args+=("0x$byte")
done

# Write current speeds back into the manual register so manual mode
# starts at exactly the speed the BMC was at.
ipmitool raw 0x3a 0xd6 "${write_args[@]}" >/dev/null

# Flip FAN1-7 to manual (0x01). FAN8-16 stay on default (0x00).
# Iteration 2 added SB_FAN1 (FAN6) and MOS_FAN1 (FAN7) — chipset and
# VRM cooling — to CoolerControl. ExecStop reverts all fans to default
# mode if coolercontrold stops/crashes, so the BMC's own thermal-
# protection curve remains the failsafe for these critical fans.
ipmitool raw 0x3a 0xd8 \
    0x01 0x01 0x01 0x01 0x01 0x01 0x01 \
    0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 >/dev/null

# Seed the duty shadow with exactly what we just wrote, so the first
# cc-set-fan-duty.sh after boot modifies the shadow instead of paying a live
# `0x3a 0xda` read. The sanitised bytes[] here equal the manual register's
# contents, which (FAN1-7 now in manual mode) the BMC holds steady.
printf '%s\n' "${bytes[*]}" > /run/cc-bmc-duty.state.tmp \
    && mv /run/cc-bmc-duty.state.tmp /run/cc-bmc-duty.state
