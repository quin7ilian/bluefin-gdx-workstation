# bluefin-gdx-workstation

[![bluebuild build badge](https://github.com/quin7ilian/bluefin-gdx-workstation/actions/workflows/build.yml/badge.svg)](https://github.com/quin7ilian/bluefin-gdx-workstation/actions/workflows/build.yml)

A custom [Bluefin LTS NVIDIA](https://github.com/projectbluefin/bluefin-lts) image for HPO/ML workstation use.

## Target hardware

Several pieces of this image are tuned to one specific build — kargs, sysctl values, and BMC handling assume the hardware below. Most of it will also work fine on similar workstations, but the AMD blanking workaround, the BMC USB ethernet suppression, and some of the memory tunings are calibrated against this configuration:

| Component | Spec |
|---|---|
| Motherboard | ASRock WRX80 Creator R2.0 |
| CPU | AMD Ryzen Threadripper PRO 5995WX (64-core / 128-thread) |
| RAM | 512 GB DDR4 ECC |
| Display GPU | ASUS Radeon RX 9070 XT Prime OC 16 GB (Navi 48) |
| Compute GPU | NVIDIA GeForce RTX 4090 |
| Primary display | Samsung Odyssey G95SD (5120×1440 @ 240 Hz) |
| 10G NIC | 2 × Aquantia AQC113CS (driver: `atlantic`) |
| Wireless | Intel AX210 (Wi-Fi 6E + Bluetooth) |
| BMC | ASPEED, exposes virtual USB ethernet (USB ID `046b:ffb0`) |
| Storage | NVMe (Kingston KC3000 4 TB + 1 TB) |

The choices to keep in mind if you adapt this image for different hardware: `nvidia-drm.modeset=0` assumes an AMD-primary + Nvidia-compute-only display layout; `amdgpu.dcdebugmask=0x20000` is an RX 9070 XT/DCN4 workaround validated against this G95SD at 240 Hz and intentionally trades idle GPU power for display stability; `vm.dirty_bytes` and `vm.max_map_count` are tuned for 512 GB; the BMC USB ethernet suppression matches by interface name `usb0`.

## What this image adds

On top of `ghcr.io/projectbluefin/bluefin-lts-nvidia:stable`:

The upstream base supplies the kernel-matched Nvidia driver, CUDA host driver
libraries (`libcuda`), Nvidia Container Toolkit, and rootless Podman CDI. It
keeps optional developer applications outside the host image. The native
GPU-container path is rootless Podman with CDI. Use `ujust devmode` to select
Homebrew/Flatpak developer tools; those installations persist independently of
image updates. Its Docker option installs the Docker CLI and Compose through
Homebrew, not a host `docker-ce` daemon.

**Applications**
- 1Password (GUI + CLI)
- Insync (GUI + Nautilus extension), background-managed via a systemd user unit
- Zed editor (official upstream tarball, installed to `/usr/lib/zed.app`)
- `gnome-browser-connector` — native messaging host so extensions.gnome.org "Install" buttons work from the browser
- Chromium — installed and wired to the host 1Password app via `ujust setup-chromium`. Deliberately a **Flatpak, not a host RPM**: CentOS Stream 10's mesa is built without the VA-API frontend (no `mesa-va-drivers` exists for EL10 in any repo), so a host-native Chromium would decode video in software. The Flatpak's freedesktop runtime bundles its own AMD VA driver, so hardware video decode on the RX 9070 XT is available with no host-mesa changes — verify at `chrome://gpu`. (Trivalent itself can't be layered here: its RPM requires glibc ≥ 2.42 and CS10 ships 2.39.)

**Thermal / fan control**
- `coolercontrold` from the upstream COPR — enabled at build time, web UI on `http://localhost:11987`
- `ipmitool` + `lm_sensors` for BMC and hwmon access
- `ipmi_si` / `ipmi_devintf` kernel modules autoloaded for `/dev/ipmi0` access on the ASRock WRX80 Creator R2.0
- `cc-plugin-custom-device` plugin installed via `ujust install-cc-plugin` post-rebase (kept out of the image because coolercontrold migrates `/etc/coolercontrol/plugins` to a `/var` symlink at runtime, which conflicts with ostree's `/etc` merge if the path is baked in). Bridges IPMI to CoolerControl via shell commands declared in `manifest.toml`; per-board WRX80 command set is filled in post-install and lives in `/var`

**Profiling / HPO benchmarking**
- Host-installed: `perf`, `bpftrace`, `sysstat` (sar/iostat/mpstat/pidstat), `strace`, `ltrace`, `numactl`, `hwloc`
- Kernel-coupled tools (perf, bpftrace) must match the running kernel — installed in the image rather than in a Distrobox where they'd be built against a different kernel
- `kernel.perf_event_paranoid = 1` is set in sysctl, so `perf stat` / `perf record` work against own processes without sudo
- Python-side profilers (`py-spy`, `scalene`, `austin`, `memray`, `pyinstrument`) install in the user's conda env via pip/uv — not in the image

**Kernel and system tunings**
- `nvidia-drm.modeset=0` — for multi-GPU configs where an AMD GPU drives all displays and Nvidia GPUs are compute-only (prevents Mutter from doing cross-GPU framebuffer copies)
- **RX 9070 XT / G95SD 240 Hz stability** — `amdgpu.dcdebugmask=0x20000` disables DCN4 Sub-Viewport and Firmware-Assisted Memory Clock Switching (FAMS2). On this card, FAMS2 memory-clock transitions could stall the display stream long enough for the G95SD to blank and re-lock even though the DP link remained healthy. The workaround was validated for a full day at native **5120×1440@240 over DP 1.4 with DSC**: the performance policy stays `auto`, SCLK remains dynamic, and MCLK stays at its highest state. DSC, HDR/10-bit, and VRR remain available; the cost is higher idle GPU power. This matches the failure class tracked in [drm/amd #4795](https://gitlab.freedesktop.org/drm/amd/-/work_items/4795) and [#4753](https://gitlab.freedesktop.org/drm/amd/-/work_items/4753).
- zram disabled (workstation with 512GB RAM does not need it)
- Custom sysctl: scheduler, dirty-page limits, mmap count, overcommit, perf paranoid
- Transparent Huge Pages set to `madvise`

**NetworkManager**
- BMC virtual USB ethernet (`usb0`, USB ID `046b:ffb0`) marked unmanaged to suppress NM's auto-activation retry loop and the GNOME "network disconnected" notifications it produces. Re-enable with `nmcli device set usb0 managed yes` if you need it for BMC USB tunneling

**Convenience**
- `ujust devmode` — upstream Bluefin Developer Mode for optional Homebrew/Flatpak developer tools. Its Docker selection provides the Homebrew Docker CLI and Compose, not a host Docker daemon; rootless Podman + CDI is the image's native GPU-container path
- `ujust setup-chromium` — installs the Chromium Flatpak and bridges it to the host 1Password app (native-messaging wrapper + Chromium manifest + `flatpak override`), and adds `flatpak-session-helper` to 1Password's allowlist. Idempotent; run once post-rebase
- `ujust enable-insync` / `ujust disable-insync` / `ujust status-insync`
- `ujust install-cc-plugin` — installs the CoolerControl custom-device plugin post-rebase (also silences the liquidctl warning)
- `ujust upgrade-cc-plugin` — pulls the latest plugin binary from upstream and re-applies, preserving your customized `manifest.toml`
- `ujust refresh-bmc-channels` — replaces `/etc/coolercontrol/plugins/custom-device/config.json` with the current image's template. Use after a rebase when you want to adopt a changed channel definition. Backs up the existing config first
- `ujust disable-liqctld` — flips `liquidctl_integration = false` in `/etc/coolercontrol/config.toml`. Run standalone if `install-cc-plugin` was done before this feature landed

**BMC fan control bridge**
- `coolercontrol-bmc-bridge.service` switches FAN1-7 (CPU + rear + 3× CHA + chipset + VRM channels) to BMC manual mode before coolercontrold starts, and back to default mode when it stops. Companion to `coolercontrold.service`; **upstream service file is not modified**
- `/usr/libexec/cc-set-fan-duty.sh` does the per-channel read-modify-write of the BMC's 16-byte duty register via `ipmitool raw 0x3a 0xd6/0xda`. Wrapper has a 5% floor for BMC validation (not thermal safety — that lives in the curves)
- FAN6 (SB_FAN1, chipset) and FAN7 (MOS_FAN1, VRM) use higher safety floors and aggressive ramp-up; see `silent-curves-reference.md`
- liquidctl integration is disabled by default (no liquid cooling here, avoids the EPEL dep)
- `ujust install-cc-plugin` deploys a pre-populated `config.json` with all 7 fan channels and 12 temp sensors already defined for the WRX80 BMC — no manual UI setup required. Curves are still configured via the UI per `silent-curves-reference.md`. Channel definitions can be edited at `/etc/coolercontrol/plugins/custom-device/config.json`; see `channels-reference.md` for the current mapping

## Installation

To switch an existing bootc system to the latest signed build:

```
sudo bootc switch ghcr.io/quin7ilian/bluefin-gdx-workstation:latest --enforce-container-sigpolicy
sudo systemctl reboot
```

## Post-install steps

```bash
# Optional: select Homebrew/Flatpak developer tools from upstream Bluefin
# Developer Mode. Its Docker option installs the Docker CLI and Compose, not
# a host docker-ce daemon; use rootless Podman for the native container engine.
ujust devmode

# Enable the Insync sync engine for your user (persists across reboots)
ujust enable-insync

# Open the Insync GUI once to link your Google account and pick a sync
# folder. From the app menu, or:
insync show

# IMPORTANT: in Insync Preferences, UNCHECK "Start Insync at startup".
# The systemd user unit handles autostart now — leaving both on causes
# a duplicate-launch race at login.

# Sign in to 1Password.

# Install the CoolerControl custom-device plugin (one-off, lives in /var
# and persists across image updates). This also:
#   - deploys a pre-populated config.json with all 7 fan channels and 12
#     temp sensors defined for the WRX80 BMC (skip-if-exists, so manual
#     edits aren't clobbered)
#   - disables the liquidctl integration (no liquid cooling on this build)
ujust install-cc-plugin

# Open the CoolerControl UI at http://localhost:11987. The WRX80 BMC
# device with all channels appears automatically; you only need to:
#   - Under each fan channel, configure a curve (Speed mode → Profile →
#     Graph editor). Suggested points are in:
#       /usr/share/cc-bmc-bridge/silent-curves-reference.md
#
# The BMC bridge service is enabled at build time and automatically
# switches FAN1-7 to manual mode when CoolerControl starts.
```

## Verification

After switching to a new deployment, verify the Nvidia compute-only split:

```bash
(
set -euo pipefail

# Must contain nvidia-drm.modeset=0.
grep -o 'nvidia-drm.modeset=[^ ]*' /proc/cmdline
grep -qw 'nvidia-drm.modeset=0' /proc/cmdline

# Host driver and every installed Nvidia compute card should be visible.
nvidia-smi

# Refuse to let the DRM check pass vacuously when no Nvidia PCI device is
# bound to the driver.
shopt -s nullglob
nvidia_gpus=(/sys/bus/pci/drivers/nvidia/????:??:??.?)
(( ${#nvidia_gpus[@]} > 0 )) || {
  echo "ERROR: no PCI devices are bound to the Nvidia driver" >&2
  exit 1
}

# Neither graphics module may be loaded.
if lsmod | grep -Eq '^(nvidia_drm|nvidia_modeset)[[:space:]]'; then
  lsmod | grep -E '^(nvidia_drm|nvidia_modeset)[[:space:]]'
  echo "ERROR: Nvidia graphics module is loaded" >&2
  exit 1
fi

# Every Nvidia device should report "compute-only" rather than a DRM directory.
for gpu in "${nvidia_gpus[@]}"; do
  if [ -d "$gpu/drm" ]; then
    echo "ERROR: DRM node present: $gpu/drm" >&2
    exit 1
  fi
  echo "compute-only: $(basename "$gpu")"
done

# Rootless Podman CDI smoke test.
podman run --rm \
  --device nvidia.com/gpu=all \
  --security-opt=label=disable \
  nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04 \
  nvidia-smi
)
```

Image signed with [Sigstore cosign](https://github.com/sigstore/cosign):

```
cosign verify --key cosign.pub ghcr.io/quin7ilian/bluefin-gdx-workstation
```

## Build

Built and signed automatically via the GitHub Actions workflow in `.github/workflows/build.yml` (BlueBuild template). The daily rebuild picks up the latest upstream Bluefin LTS NVIDIA stable base on each run.
Each rebuild also picks up the latest stable upstream Zed tarball.
