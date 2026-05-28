#!/usr/bin/env bash
# cc-set-fan-duty.sh <fan_idx 1-5> <duty_percent 0-100>
#
# Per-channel fan-duty writer for cc-plugin-custom-device on the ASRock Rack
# WRX80 Creator R2.0 BMC. Reads the BMC's current 16-byte duty register via
# `ipmitool raw 0x3a 0xda`, modifies the byte for FAN<idx> with the requested
# duty, then writes the full 16-byte array back via `ipmitool raw 0x3a 0xd6`.
# This RMW pattern is required because the BMC's set-duty command is global
# (all 16 fan positions at once).
#
# The 5% floor is a BMC-validation floor, NOT a thermal safety floor:
# the BMC rejects writes containing 0x00 or 0x01 in some positions with
# "Invalid data field" (0xcc). Clamping to 5% (0x05) avoids that rejection
# and also keeps any fan above its physical stall threshold in practice
# (Dynamic X2 fans typically stall around 5-8% PWM). Thermal safety is
# the responsibility of CoolerControl's curve configuration; if a curve
# can sensibly request 0%, design the curve to express "off" intent
# above the wrapper layer.
#
# Concurrency: flock on /run/cc-bmc-fan.lock prevents two concurrent RMWs
# from racing (e.g., CoolerControl updates multiple fan channels in
# parallel — without the lock, two reads could overlap and the second
# write would clobber the first's modification).
#
# Idx → physical mapping (verified empirically 2026-05-28):
#   1 = CPU_FAN1
#   2 = CPU_FAN2/WP   (rear exhaust)
#   3 = CHA_FAN1/WP   (bottom 3-fan hub)
#   4 = CHA_FAN2/WP   (top front)
#   5 = CHA_FAN3/WP   (bottom front)
#   6 = SB_FAN1       (chipset — small high-RPM fan; floor in curve >= 20%)
#   7 = MOS_FAN1      (VRM — small high-RPM fan; floor in curve >= 30%, ramp aggressively past 70°C)

set -euo pipefail

usage() { echo "usage: $0 <fan_idx 1-7> <duty_percent 0-100>" >&2; exit 64; }
[[ $# -eq 2 ]] || usage

fan_idx="$1"
duty_pct="$2"

[[ "$fan_idx" =~ ^[1-7]$ ]] || { echo "fan_idx must be 1-7, got: $fan_idx" >&2; exit 64; }
[[ "$duty_pct" =~ ^[0-9]+$ ]] || { echo "duty_pct must be a non-negative integer, got: $duty_pct" >&2; exit 64; }
(( duty_pct <= 100 )) || { echo "duty_pct must be 0-100, got: $duty_pct" >&2; exit 64; }

# BMC-validation floor: clamp anything below 5% up to 5%.
(( duty_pct >= 5 )) || duty_pct=5

# Serialize RMW operations across concurrent invocations.
exec 200>/run/cc-bmc-fan.lock
flock -x 200

# Read current 16-byte duty register. Output is space-separated hex bytes
# with a leading space, e.g. ' 50 50 32 32 32 1e 3c 01 1e 1e 1e 1e 1e 1e 1e 1e'.
current=$(ipmitool raw 0x3a 0xda)
read -ra bytes <<< "$current"
(( ${#bytes[@]} == 16 )) || {
    echo "expected 16 bytes from 0x3a 0xda, got ${#bytes[@]}: '$current'" >&2
    exit 1
}

# Build the write payload:
#   positions 0-4 (FAN1-5): preserve from current, overwrite (idx-1) with new value
#   positions 5-6 (FAN6/7): preserve from current (board fans on BMC default mode)
#   positions 7-15 (FAN8-16): hard-code 0x05 — unused fan slots; BMC rejects
#                              writes containing 0x00/0x01 here, so we force
#                              a valid value. These positions don't affect
#                              any physical fan because no fan exists there.
duty_hex=$(printf '%02x' "$duty_pct")
bytes[$((fan_idx - 1))]="$duty_hex"
for i in 7 8 9 10 11 12 13 14 15; do
    bytes[$i]="05"
done
# Defensive: if BMC ever reports < 0x02 at positions 0-6 (shouldn't happen
# for live fan positions, but documented for clarity), clamp to 0x05.
for i in 0 1 2 3 4 5 6; do
    val=$((16#${bytes[$i]}))
    (( val < 2 )) && bytes[$i]="05"
done

# Compose and write
write_args=()
for byte in "${bytes[@]}"; do
    write_args+=("0x$byte")
done
ipmitool raw 0x3a 0xd6 "${write_args[@]}" >/dev/null
