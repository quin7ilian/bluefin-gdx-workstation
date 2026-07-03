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

The choices to keep in mind if you adapt this image for different hardware: `nvidia-drm.modeset=0` assumes AMD-primary + Nvidia-compute-only display layout; the custom EDID (`drm.edid_firmware`) is hand-built for the Samsung G95SD's specific high-refresh blanking; `vm.dirty_bytes` and `vm.max_map_count` are tuned for 512 GB; the BMC USB ethernet suppression matches by interface name `usb0`.

## What this image adds

On top of `ghcr.io/ublue-os/bluefin-gdx:lts`:

**Applications**
- 1Password (GUI + CLI)
- Insync (GUI + Nautilus extension), background-managed via a systemd user unit
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
- **Custom EDID for the Samsung Odyssey G95SD** — loaded via `drm.edid_firmware=DP-1:edid/g95sd-full.bin` (shipped at `/usr/lib/firmware/edid/`, pulled into the initramfs by a dracut `install_items` drop-in so it applies at early KMS). Fixes intermittent cursor-triggered screen blanking on the Navi 33 (Radeon Pro W7500) at 5120×1440 high refresh. The cause is **not** PSR (the sink advertises PSR ver 0) — the stock EDID's 240 Hz timing leaves only a 6-line vertical back porch, too short for the amdgpu memory-clock (UCLK) switch to settle before active video resumes, so the switch flashes black. The custom EDID redistributes the (unchanged, 47-line) vertical blanking to a 34-line back porch (`Vfront 33→3`, `Vsync 8→10`; pixel clock and bandwidth untouched), so mclk switches cleanly on `auto` — meaning the GPU no longer has to be pinned in `manual` mode and the **shader clock is free to boost**. (The former `amdgpu-pin-mclk.service` fixed the blanking but as a side effect clamped SCLK to ~810 MHz — half of boost — making the desktop sluggish; it has been removed, recoverable from git history.) The EDID also raises the FreeSync floor 48→96 Hz to keep VRR out of the OLED low-refresh flicker band. Built from the monitor's own stock EDID (HDR/colorimetry preserved) plus the timing/VRR delta reverse-engineered from [vpraion's OLED-G9 fix](https://github.com/vpraion/odysseyg9-linux-240hz-vrr-hdr-noflicker) and validated with `edid-decode`; a blanking-only variant (`g95sd-vblank.bin`, no VRR change) ships as a fallback
- zram disabled (workstation with 512GB RAM does not need it)
- Custom sysctl: scheduler, dirty-page limits, mmap count, overcommit, perf paranoid
- Transparent Huge Pages set to `madvise`

**NetworkManager**
- BMC virtual USB ethernet (`usb0`, USB ID `046b:ffb0`) marked unmanaged to suppress NM's auto-activation retry loop and the GNOME "network disconnected" notifications it produces. Re-enable with `nmcli device set usb0 managed yes` if you need it for BMC USB tunneling

**Convenience**
- `ujust enable-insync` / `ujust disable-insync` / `ujust status-insync`
- `ujust toggle-ai-mode` / `ujust status-ai-mode` — flip local AI models (phi-4 curator on `:8081`, Codestral 22B on `:8082`) between AI MODE (on, GPU-backed) and HPO MODE (off, both 4090s freed). Gated by `~/.config/local-ai/enabled`; survives reboot.
- `ujust install-cc-plugin` — installs the CoolerControl custom-device plugin post-rebase (also silences the liquidctl warning)
- `ujust upgrade-cc-plugin` — pulls the latest plugin binary from upstream and re-applies, preserving your customized `manifest.toml`
- `ujust refresh-bmc-channels` — replaces `/etc/coolercontrol/plugins/custom-device/config.json` with the current image's template. Use after a rebase when a new image adds channels (e.g. iteration 2 added FAN6/FAN7). Backs up the existing config first
- `ujust disable-liqctld` — flips `liquidctl_integration = false` in `/etc/coolercontrol/config.toml`. Run standalone if `install-cc-plugin` was done before this feature landed

**BMC fan control bridge**
- `coolercontrol-bmc-bridge.service` switches FAN1-5 (CPU + rear + 3× CHA channels) to BMC manual mode before coolercontrold starts, and back to default mode when it stops. Companion to `coolercontrold.service`; **upstream service file is not modified**
- `/usr/libexec/cc-set-fan-duty.sh` does the per-channel read-modify-write of the BMC's 16-byte duty register via `ipmitool raw 0x3a 0xd6/0xda`. Wrapper has a 5% floor for BMC validation (not thermal safety — that lives in the curves)
- FAN6 (SB_FAN1, chipset) and FAN7 (MOS_FAN1, VRM) intentionally stay on BMC auto in iteration 1
- liquidctl integration is disabled by default (no liquid cooling here, avoids the EPEL dep)
- `ujust install-cc-plugin` deploys a pre-populated `config.json` with all 5 fan channels and 12 temp sensors already defined for the WRX80 BMC — no manual UI setup required. Curves are still configured via the UI per `silent-curves-reference.md`. Channel definitions can be edited at `/etc/coolercontrol/plugins/custom-device/config.json`; see `channels-reference.md` for the current mapping

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

# Sign in to 1Password.

# Install the CoolerControl custom-device plugin (one-off, lives in /var
# and persists across image updates). This also:
#   - deploys a pre-populated config.json with all 5 fan channels and 12
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
# switches FAN1-5 to manual mode when CoolerControl starts.
```

## Verification

Image signed with [Sigstore cosign](https://github.com/sigstore/cosign):

```
cosign verify --key cosign.pub ghcr.io/quin7ilian/bluefin-gdx-workstation
```

## Build

Built and signed automatically via the GitHub Actions workflow in `.github/workflows/build.yml` (BlueBuild template). The daily rebuild picks up the latest upstream Bluefin GDX base on each run.
