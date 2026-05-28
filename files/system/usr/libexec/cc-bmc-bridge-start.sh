#!/usr/bin/env bash
# cc-bmc-bridge-start.sh
#
# Companion-service ExecStart for coolercontrol-bmc-bridge.service.
# Runs BEFORE coolercontrold.service so manual mode is active before
# CoolerControl issues any duty writes.
#
# Strategy: read the BMC's current duty register (which holds whatever
# the BMC's auto-curve currently has set), write those SAME values to
# the manual register, then flip FAN1-5 to manual mode. When mode flips,
# manual mode immediately latches the same duties — no fan-speed jump.
#
# See cc-set-fan-duty.sh for the 0x00/0x01 → 0x05 rationale and the
# fan-index → physical mapping.

set -euo pipefail

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

# Flip FAN1-5 to manual (0x01). FAN6-16 stay on default (0x00) — the
# BMC's auto-curve continues to manage SB_FAN1 / MOS_FAN1 cooling for
# the chipset and VRM.
ipmitool raw 0x3a 0xd8 \
    0x01 0x01 0x01 0x01 0x01 \
    0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 >/dev/null
