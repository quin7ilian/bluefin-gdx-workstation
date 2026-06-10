#!/usr/bin/env bash
# cc-set-fan-duty.sh <fan_idx 1-7> <duty_percent 0-100>
#
# Per-channel fan-duty writer for cc-plugin-custom-device on the ASRock Rack
# WRX80 Creator R2.0 BMC. The BMC's set-duty command (`ipmitool raw 0x3a 0xd6`)
# is GLOBAL — it writes all 16 fan positions at once — so a single-channel
# change must be expressed as a modify-then-write of the whole 16-byte array.
#
# Shadow register (perf): instead of reading the live array from the BMC on
# every call (`ipmitool raw 0x3a 0xda`, ~300ms over the polled-KCS interface),
# we keep a shadow of the last-written array in /run/cc-bmc-duty.state and
# modify that. This halves the IPMI traffic per duty change — one write
# instead of read+write. The read roundtrip was the larger, avoidable half of
# the latency that blew through CoolerControl's plugin set-duty timeout when
# several channels changed in one poll cycle (each call serialises behind the
# BMC lock below, so the tail channel waited on N full read+writes). The
# shadow is authoritative because FAN1-7 are held in MANUAL mode (see
# cc-bmc-bridge-start.sh), so the BMC does not change these bytes underneath
# us; the bridge seeds it at startup and every write here refreshes it. If the
# shadow is missing or malformed (cold start, /run wiped), we fall back to a
# live `0x3a 0xda` read so we never write a guessed array.
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
# Concurrency: a single shared BMC mutex (/run/cc-bmc-ipmi.lock) serialises
# this writer against (a) other concurrent duty writes and (b) the sensor
# cache refresh in cc-bmc-sensor.sh. All three touch the one KCS interface;
# without a shared lock a duty write could interleave with an in-flight
# `ipmitool sensor list` on the bus, causing KCS retries/timeouts. We block
# (-x) because a duty write must complete; the sensor refresh takes the same
# lock non-blocking and simply serves slightly-stale cache while we hold it.
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

shadow="/run/cc-bmc-duty.state"

# True iff the args are exactly 16 tokens, each a 1-2 digit hex byte. Guards
# every later `16#${bytes[i]}` arithmetic expansion against non-hex input
# (which would otherwise abort cryptically under set -e). Used for both the
# shadow and the live-read paths so they fail the same, clear way.
is_valid_register() {
    (( $# == 16 )) || return 1
    local b
    for b in "$@"; do
        [[ "$b" =~ ^[0-9a-fA-F]{1,2}$ ]] || return 1
    done
    return 0
}

# Serialize all BMC access (duty writes + sensor refresh) on one shared lock.
exec 200>/run/cc-bmc-ipmi.lock
flock -x 200

# Source the current 16-byte array from the shadow; fall back to a live BMC
# read only if the shadow is absent or not a valid 16-byte register image.
bytes=()
[[ -r "$shadow" ]] && read -ra bytes < "$shadow" || true
if ! is_valid_register ${bytes[@]+"${bytes[@]}"}; then
    # Cold start / corrupt shadow: read the live 16-byte duty register.
    # Output is space-separated hex, e.g. ' 50 50 32 32 32 1e 3c 01 1e 1e ...'.
    current=$(ipmitool raw 0x3a 0xda)
    read -ra bytes <<< "$current"
    is_valid_register ${bytes[@]+"${bytes[@]}"} || {
        echo "invalid 16-byte register from 0x3a 0xda: '$current'" >&2
        exit 1
    }
fi

# Build the write payload:
#   position (idx-1):       set to the requested duty
#   positions 0-6 (FAN1-7): preserve the rest; defensive clamp of any <0x02 to 0x05
#   positions 7-15 (FAN8-16): hard-code 0x05 — unused fan slots; the BMC rejects
#                             writes containing 0x00/0x01 here, and no physical
#                             fan exists there so the value is inert.
duty_hex=$(printf '%02x' "$duty_pct")
bytes[$((fan_idx - 1))]="$duty_hex"
for i in 7 8 9 10 11 12 13 14 15; do
    bytes[$i]="05"
done
for i in 0 1 2 3 4 5 6; do
    val=$((16#${bytes[$i]}))
    (( val < 2 )) && bytes[$i]="05"
done

# Compose and write.
write_args=()
for byte in "${bytes[@]}"; do
    write_args+=("0x$byte")
done
ipmitool raw 0x3a 0xd6 "${write_args[@]}" >/dev/null

# Refresh the shadow with exactly what we wrote (atomic replace, so a reader
# never sees a half-written array).
printf '%s\n' "${bytes[*]}" > "${shadow}.tmp" && mv "${shadow}.tmp" "$shadow"
