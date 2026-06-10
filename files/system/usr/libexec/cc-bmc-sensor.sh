#!/bin/sh
# cc-bmc-sensor.sh <SENSOR_NAME> <temp|fan>
#
# Cached BMC sensor reader for cc-plugin-custom-device on the WRX80
# Creator R2.0. The plugin polls every channel sequentially each status
# cycle (17 channels × ~300ms per ipmitool roundtrip = ~5s of IPMI
# traffic), which exceeded CoolerControl's plugin-response timeout and
# triggered "Significant issue retrieving status / Setting failsafe
# values" log spam.
#
# This wrapper batches: one `ipmitool sensor list` call (~300ms)
# populates /run/cc-bmc-sensors.cache; subsequent reads parse from the
# cache (microseconds). Cache TTL = 5s, comfortably longer than CC's
# typical 1-3s poll interval so all channels in a single cycle share
# one IPMI fetch.
#
# Output:
#   temp mode: integer millidegrees Celsius (plugin's expected unit;
#              also accepts plain degrees via the >1000 fallback in
#              cc-plugin-custom-device/src/executor.rs)
#   fan mode:  integer RPM
#
# Empty output (script exits 0) for: 'na' values, sensor name not in
# cache, BMC unreachable. The plugin treats empty as "no value" and
# omits the channel/temp from its status response — same behaviour
# as the original per-channel `sensor get` approach.

set -eu

if [ $# -ne 2 ]; then
    echo "usage: $0 <SENSOR_NAME> <temp|fan>" >&2
    exit 64
fi

sensor="$1"
mode="$2"
cache="/run/cc-bmc-sensors.cache"
# Shared BMC mutex — the SAME lock cc-set-fan-duty.sh takes for duty writes.
# Both this `ipmitool sensor list` and a duty write hit the one KCS interface;
# serialising them on one lock stops a refresh from interleaving with a write
# on the bus (which caused KCS retries/timeouts). We take it non-blocking
# below: if a write holds it, we skip the refresh and serve the existing cache.
lockfile="/run/cc-bmc-ipmi.lock"
ttl=5

cache_age() {
    if [ ! -f "$cache" ]; then
        echo 999999
    else
        echo $(( $(date +%s) - $(stat -c %Y "$cache") ))
    fi
}

# Refresh cache if stale (with non-blocking lock; if someone else is
# already refreshing OR a duty write holds the shared BMC lock, we skip and
# read what's there — possibly a few hundred ms stale, fine for fan curves).
if [ "$(cache_age)" -gt "$ttl" ]; then
    {
        if flock -n -x 100; then
            # Re-check staleness inside lock — another invocation may
            # have refreshed between our check and lock acquisition.
            if [ "$(cache_age)" -gt "$ttl" ]; then
                # Atomic write: only replace the cache if ipmitool
                # succeeded with non-empty output. Prevents wiping a
                # good cache when BMC is transiently unreachable.
                if ipmitool sensor list > "${cache}.tmp" 2>/dev/null && [ -s "${cache}.tmp" ]; then
                    mv "${cache}.tmp" "$cache"
                else
                    rm -f "${cache}.tmp"
                fi
            fi
        fi
    } 100>"$lockfile"
fi

# Parse cache for the requested sensor.
# Lines look like: "SENSOR_NAME      | 73.000     | degrees C  | ok    | na | ...".
# Match $1 exactly (after stripping surrounding whitespace) so e.g.
# "TEMP_CPU" doesn't also match "TEMP_CPU2_Socket".
value=$(awk -F'|' -v s="$sensor" '
    {
        gsub(/^[ \t]+|[ \t]+$/, "", $1)
        gsub(/^[ \t]+|[ \t]+$/, "", $2)
        if ($1 == s) { print $2; exit }
    }
' "$cache" 2>/dev/null || true)

# 'na' = sensor present but no reading (e.g., TEMP_PSU1 without a PSU
# advertising over PMBus). Empty = sensor name not in cache or no
# cache. Either way, emit nothing.
case "$value" in
    na|"") exit 0 ;;
esac

# Strip decimals — ipmitool sensor list emits values like "73.000".
# parse::<u32> in the plugin would reject these, so we round to int.
int=$(printf '%s' "$value" | awk '{print int($1+0.5)}')

case "$mode" in
    temp) echo "$((int * 1000))" ;;
    fan)  echo "$int" ;;
    *)    echo "usage: mode must be 'temp' or 'fan'" >&2; exit 64 ;;
esac
