#!/usr/bin/env bash
# bmc-ipmi-priority.sh
#
# Raise the scheduling priority of the kernel IPMI polling thread(s).
#
# /dev/ipmi0 on this ASRock Rack WRX80 Creator R2.0 is a POLLED KCS interface
# (the kernel probes it as "kcs ... irq 0" — no interrupt line). The byte-at-a-
# time KCS handshake is therefore driven in software by the `kipmiN` kernel
# thread, which the ipmi_si driver creates at nice 19 (lowest priority). On
# this box the HPO/ML workload routinely saturates all 128 hardware threads,
# starving kipmi0 — every IPMI transaction (including CoolerControl's fan-duty
# writes through cc-set-fan-duty.sh) then stalls for seconds and surfaces as
# "TIMEOUT ... waiting to set fixed duty" in the coolercontrold log.
#
# Lifting kipmi to nice -10 lets it preempt batch compute during the brief
# polls of an IPMI transaction (a handful per minute, each milliseconds long):
# negligible cost to compute throughput, large win for IPMI latency under load.
# The new nice value persists for the thread's lifetime (kipmi lives as long as
# the ipmi_si interface is bound, i.e. the whole uptime), so this only needs to
# run once at boot.
#
# Best-effort: if no kipmi thread exists (no BMC / different interface type)
# we log and exit 0 rather than fail the unit.

set -euo pipefail

target_nice=-10

# kipmi thread comm is "kipmi0" (or kipmi1, ... for multiple interfaces).
# ps comm is reliable here; match the exact name pattern.
mapfile -t pids < <(ps -eo pid=,comm= | awk '$2 ~ /^kipmi[0-9]+$/ {print $1}')

# kipmi0 is created during ipmi_si probe, which runs inside the modprobe that
# systemd-modules-load.service performs (this unit is ordered After it). In
# the rare case the thread hasn't appeared yet, retry briefly — bounded so a
# missing BMC can't delay boot.
if [ "${#pids[@]}" -eq 0 ]; then
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.2
        mapfile -t pids < <(ps -eo pid=,comm= | awk '$2 ~ /^kipmi[0-9]+$/ {print $1}')
        [ "${#pids[@]}" -gt 0 ] && break
    done
fi

if [ "${#pids[@]}" -eq 0 ]; then
    echo "bmc-ipmi-priority: no kipmi* kernel thread found — no polled IPMI interface? Skipping." >&2
    exit 0
fi

for pid in "${pids[@]}"; do
    if renice -n "$target_nice" -p "$pid" >/dev/null; then
        echo "bmc-ipmi-priority: set nice $target_nice on kipmi pid $pid"
    else
        echo "bmc-ipmi-priority: failed to renice kipmi pid $pid" >&2
    fi
done
