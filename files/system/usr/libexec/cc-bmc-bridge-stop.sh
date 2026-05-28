#!/usr/bin/env bash
# cc-bmc-bridge-stop.sh
#
# Companion-service ExecStop for coolercontrol-bmc-bridge.service.
# Switches all 16 fan positions back to default (BMC auto) mode so the
# BMC resumes its own curve when CoolerControl is stopped or crashes.
# Doesn't touch the duty register — irrelevant once fans are in
# default mode (BMC ignores stored manual duties).

set -euo pipefail

ipmitool raw 0x3a 0xd8 \
    0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 \
    0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 >/dev/null
