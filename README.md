# bluefin-gdx-workstation

[![bluebuild build badge](https://github.com/quin7ilian/bluefin-gdx-workstation/actions/workflows/build.yml/badge.svg)](https://github.com/quin7ilian/bluefin-gdx-workstation/actions/workflows/build.yml)

A custom [Bluefin GDX](https://projectbluefin.io/) LTS image for HPO/ML workstation use.

## Target hardware

Several pieces of this image are tuned to one specific build — kargs, sysctl values, and BMC handling assume the hardware below. Most of it will also work fine on similar workstations, but the AMD blanking workaround, the BMC USB ethernet suppression, and some of the memory tunings are calibrated against this configuration:

| Component | Spec |
|---|---|
| Motherboard | ASRock WRX80 Creator R2.0 |
| CPU | AMD Ryzen Threadripper PRO 5995WX (64-core / 128-thread) |
| RAM | 512 GB DDR4 ECC |
| Display GPU | AMD Radeon Pro W7500 (Navi 33) |
| Compute GPUs | 2 × NVIDIA GeForce RTX 4090 |
| Primary display | Samsung Odyssey G95SD (5120×1440 @ 240 Hz, DisplayPort) |
| 10G NIC | 2 × Aquantia AQC113CS (driver: `atlantic`) |
| Wireless | Intel AX210 (Wi-Fi 6E + Bluetooth) |
| BMC | ASPEED, exposes virtual USB ethernet (USB ID `046b:ffb0`) |
| Storage | NVMe (Kingston KC3000 4 TB + 1 TB) |

The choices to keep in mind if you adapt this image for different hardware: `nvidia-drm.modeset=0` assumes AMD-primary + Nvidia-compute-only display layout; `amdgpu-pin-mclk.service` is specific to the Navi 33 + high-refresh-ultrawide blanking issue; `vm.dirty_bytes` and `vm.max_map_count` are tuned for 512 GB; the BMC USB ethernet suppression matches by interface name `usb0`.

## What this image adds

On top of `ghcr.io/ublue-os/bluefin-gdx:lts`:

**Applications**
- 1Password (GUI + CLI)
- Brave browser
- Insync (GUI + Nautilus extension), background-managed via a systemd user unit
- Zed editor (official upstream tarball, installed to `/usr/lib/zed.app`)
- `gnome-browser-connector` — native messaging host so extensions.gnome.org "Install" buttons work from the browser

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
- `amdgpu-pin-mclk.service` — systemd oneshot that pins MCLK to its highest DPM state at boot on the AMD GPU. Fixes intermittent screen blanking on Navi 33 (Radeon Pro W7500) driving the Samsung Odyssey G95SD at >60 Hz; root cause is MCLK reclocking failing to fit inside the short V-Blank window of CVT-RB timing at high refresh. SCLK remains on auto so idle power impact is limited to MCLK staying at its highest state (~10 W). Implemented as a sysfs write rather than an `amdgpu.ppfeaturemask` karg because the kernel's `PP_*_MASK` enum doesn't reliably translate to the SMU firmware's runtime feature flags on RDNA3
- zram disabled (workstation with 512GB RAM does not need it)
- Custom sysctl: scheduler, dirty-page limits, mmap count, overcommit, perf paranoid
- Transparent Huge Pages set to `madvise`

**NetworkManager**
- BMC virtual USB ethernet (`usb0`, USB ID `046b:ffb0`) marked unmanaged to suppress NM's auto-activation retry loop and the GNOME "network disconnected" notifications it produces. Re-enable with `nmcli device set usb0 managed yes` if you need it for BMC USB tunneling

**Convenience**
- `ujust enable-insync` / `ujust disable-insync` / `ujust status-insync`
- `ujust install-cc-plugin` — installs the CoolerControl custom-device plugin post-rebase
- `ujust upgrade-cc-plugin` — pulls the latest plugin binary from upstream and re-applies, preserving your customized `manifest.toml`

## Installation

To rebase an existing atomic Fedora installation to the latest build:

```
# First rebase to the unsigned image (to get signing keys and policies):
sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/quin7ilian/bluefin-gdx-workstation:latest
sudo systemctl reboot

# Then rebase to the signed image:
sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/quin7ilian/bluefin-gdx-workstation:latest
sudo systemctl reboot
```

## Post-install steps

```bash
# Enable the Insync sync engine for your user (persists across reboots)
ujust enable-insync

# Open the Insync GUI once to link your Google account and pick a sync
# folder. From the app menu, or:
insync show

# IMPORTANT: in Insync Preferences, UNCHECK "Start Insync at startup".
# The systemd user unit handles autostart now — leaving both on causes
# a duplicate-launch race at login.

# Sign in to 1Password, Brave.

# Install the CoolerControl custom-device plugin (one-off, lives in /var
# and persists across image updates). Then edit
# /etc/coolercontrol/plugins/custom-device/manifest.toml (a symlink into
# /var) to add the per-channel ipmitool commands for the WRX80 BMC, and
# `sudo systemctl restart coolercontrold` to load them.
ujust install-cc-plugin
```

## Verification

Image signed with [Sigstore cosign](https://github.com/sigstore/cosign):

```
cosign verify --key cosign.pub ghcr.io/quin7ilian/bluefin-gdx-workstation
```

## Build

Built and signed automatically via the GitHub Actions workflow in `.github/workflows/build.yml` (BlueBuild template). Rebuilds pick up the latest upstream Zed tarball on each run.
