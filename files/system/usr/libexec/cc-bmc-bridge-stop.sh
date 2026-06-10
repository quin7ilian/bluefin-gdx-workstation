#!/usr/bin/env bash
# cc-bmc-bridge-stop.sh
#
# Companion-service ExecStop for coolercontrol-bmc-bridge.service.
# Switches all 16 fan positions back to default (BMC auto) mode so the
# BMC resumes its own curve when CoolerControl is stopped or crashes.
# Doesn't touch the duty register — irrelevant once fans are in
# default mode (BMC ignores stored manual duties).

set -euo pipefail

# Take the shared BMC mutex so this mode-flip can't interleave with an
# in-flight duty write or sensor read on the KCS bus. Under the normal stop
# order (coolercontrold -> plugin -> this ExecStop) nothing else is touching
# the BMC, but a manual `systemctl stop coolercontrol-bmc-bridge.service` or
# odd ordering could. Bounded wait + proceed: reverting the fans to the BMC
# auto-curve is a safety action that MUST run, so we never block shutdown on
# the lock indefinitely — if it's still held after 5s we go ahead unlocked.
exec 200>/run/cc-bmc-ipmi.lock
flock -x -w 5 200 || echo "cc-bmc-bridge-stop: lock busy after 5s, proceeding (failsafe mode-flip must run)" >&2

ipmitool raw 0x3a 0xd8 \
    0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 \
    0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 >/dev/null

# Drop the duty shadow: with fans back on the BMC auto-curve it no longer
# describes reality, and cc-bmc-bridge-start.sh re-seeds it from a live read
# next time CoolerControl starts. A stale shadow would otherwise be a
# misleading starting point if a write somehow raced a restart.
rm -f /run/cc-bmc-duty.state
