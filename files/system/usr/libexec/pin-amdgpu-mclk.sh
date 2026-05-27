#!/bin/sh
# Pin the amdgpu card's MCLK to its highest DPM state (SCLK stays on auto).
#
# Workaround for intermittent screen blanking on Navi 33 (Radeon Pro
# W7500) driving the Samsung Odyssey G95SD at >60 Hz — MCLK reclock
# transitions fail to fit inside CVT-RB's short V-Blank window, and the
# failed transition manifests as a blanked frame. Empirically verified:
# pinning MCLK alone (with SCLK on auto) eliminates the blanking.
#
# Why this is a sysfs script and not an amdgpu.ppfeaturemask karg:
# the kernel's PP_*_MASK enum is largely legacy framework from older
# AMD architectures. On Navi 33 the SMU firmware exposes its own
# feature flags (DPM_UCLK bit 3, DS_UCLK bit 16, etc. — see
# /sys/class/drm/cardN/device/pp_features) and clearing the kernel
# mask's PP_MCLK_DPM_MASK or PP_STUTTER_MODE does NOT translate to
# disabling DPM_UCLK at runtime. The power_dpm_force_performance_level
# sysfs knob does work — that's what we use.
#
# See AGENTS.md constraint #9.

set -eu

for d in /sys/class/drm/card*/device; do
    drv="$(readlink -f "$d/driver" 2>/dev/null | xargs -r basename)" || drv=""
    [ "$drv" = "amdgpu" ] || continue

    card="$(basename "$(dirname "$d")")"
    max_mclk_state="$(awk -F: '{print $1}' "$d/pp_dpm_mclk" | tail -1)"

    echo "pin-amdgpu-mclk: $card → manual + pp_dpm_mclk=$max_mclk_state"
    echo manual > "$d/power_dpm_force_performance_level"
    echo "$max_mclk_state" > "$d/pp_dpm_mclk"
    exit 0
done

echo "pin-amdgpu-mclk: no amdgpu card found, nothing to do" >&2
exit 0
