# bluefin-gdx-workstation

[![bluebuild build badge](https://github.com/quin7ilian/bluefin-gdx-workstation/actions/workflows/build.yml/badge.svg)](https://github.com/quin7ilian/bluefin-gdx-workstation/actions/workflows/build.yml)

A custom [Bluefin GDX](https://projectbluefin.io/) LTS image for HPO/ML workstation use.

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
- `cc-plugin-custom-device` plugin installed at `/etc/coolercontrol/plugins/custom-device/` — bridges IPMI to CoolerControl via shell commands declared in `manifest.toml`; per-board WRX80 command set is filled in post-rebase, then folded back into the image

**Profiling / HPO benchmarking**
- Host-installed: `perf`, `bpftrace`, `sysstat` (sar/iostat/mpstat/pidstat), `strace`, `ltrace`, `numactl`, `hwloc`
- Kernel-coupled tools (perf, bpftrace) must match the running kernel — installed in the image rather than in a Distrobox where they'd be built against a different kernel
- `kernel.perf_event_paranoid = 1` is set in sysctl, so `perf stat` / `perf record` work against own processes without sudo
- Python-side profilers (`py-spy`, `scalene`, `austin`, `memray`, `pyinstrument`) install in the user's conda env via pip/uv — not in the image

**Kernel and system tunings**
- `nvidia-drm.modeset=0` — for multi-GPU configs where an AMD GPU drives all displays and Nvidia GPUs are compute-only (prevents Mutter from doing cross-GPU framebuffer copies)
- zram disabled (workstation with 512GB RAM does not need it)
- Custom sysctl: scheduler, dirty-page limits, mmap count, overcommit, perf paranoid
- Transparent Huge Pages set to `madvise`

**Convenience**
- `ujust enable-insync` / `ujust disable-insync` / `ujust status-insync`

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
```

## Verification

Image signed with [Sigstore cosign](https://github.com/sigstore/cosign):

```
cosign verify --key cosign.pub ghcr.io/quin7ilian/bluefin-gdx-workstation
```

## Build

Built and signed automatically via the GitHub Actions workflow in `.github/workflows/build.yml` (BlueBuild template). Rebuilds pick up the latest upstream Zed tarball on each run.
