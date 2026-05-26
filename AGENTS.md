# AGENTS.md

Guidance for AI coding agents (Claude Code, Codex, Cursor, Aider, etc.) working in this repository.

## What this repo is

A [BlueBuild](https://blue-build.org/) recipe that produces a signed OCI image (`ghcr.io/quin7ilian/bluefin-gdx-workstation`) layered on top of `ghcr.io/ublue-os/bluefin-gdx:lts` for an HPO/ML workstation. There is no application code — the deliverable is a bootable container image. `recipes/recipe.yml` is the canonical source of truth for what the image contains.

## Build & test

Builds run in CI only: `.github/workflows/build.yml` invokes `blue-build/github-action@v1.11` against each entry of the `matrix.recipe` list. To trigger one, push to the branch (the workflow ignores `**.md` changes), open a PR, or use **Actions → bluebuild → Run workflow**. There is no local build loop on Windows — to iterate locally you need a Linux host with `bluebuild` installed and would run `bluebuild build recipes/recipe.yml`. Verification is post-deploy on the target machine — e.g. `swapon --show` (expect no output), `cat /proc/cmdline | grep nvidia-drm.modeset`, `nvidia-smi`, `sysctl vm.dirty_bytes`, `ls /dev/ipmi*`, `systemctl status coolercontrold`.

## Architecture

- **`recipes/recipe.yml`** — top-level declarative pipeline. The `modules:` list runs in order. Four module types are used here:
  - `files` — copies `files/system/**` onto `/` in the image (so `files/system/etc/sysctl.d/foo.conf` lands at `/etc/sysctl.d/foo.conf`).
  - `script` — inline bash run in the build container; this is where third-party repos are added and `dnf install` runs.
  - `kargs` — writes `/usr/lib/bootc/kargs.d/` entries that bootc applies on `bootc upgrade`. The dedicated module, **not** `rpm-ostree: kargs:` (that property was removed from the rpm-ostree schema when GDX moved to bootc; using it fails recipe validation).
  - `signing` — wires up cosign signing using `SIGNING_SECRET` from repo secrets; the public key is `cosign.pub` at the repo root.
- **`files/system/`** — mounted to `/` at build time. Put OS config here (`etc/sysctl.d/`, `etc/systemd/`, `etc/tmpfiles.d/`, `etc/modules-load.d/`, `usr/share/ublue-os/just/`, etc.) rather than `cp`ing files inside a `script` module.
- **`files/scripts/`** — referenced from script modules when a snippet grows past a few lines. Currently only contains the BlueBuild example.
- **`modules/`** — empty; reserved for custom BlueBuild modules. Don't add files here unless you're authoring a new module type.

## Hard constraints

These will silently break builds or runtime behaviour if violated. Each has been verified empirically — don't re-derive.

1. **Base is CentOS Stream 10, which ships dnf4, not dnf5.** The BlueBuild `dnf` module requires dnf5 and fails with `Main dependency 'dnf5' is not installed`. Use `type: script` with `dnf install -y …` for all third-party RPMs.
2. **GDX has no rpm-ostree package layering at runtime.** Every RPM the user needs must be baked in at build time. Note: the BlueBuild `rpm-ostree` module's `kargs:` property is no longer in the schema — use the dedicated `kargs` module (writes to `/usr/lib/bootc/kargs.d/`, applied by bootc).
3. **`/usr` is read-only at runtime; `/etc` is writable.** Drop persistent config in `/etc/…` via `files/system/etc/`.
4. **No swap, ever.** This is a 512GB-RAM workstation; OOM killer is the desired failure mode. Override `/usr/lib/systemd/zram-generator.conf` with an empty file at `/etc/systemd/zram-generator.conf` — do not add swap files, swap partitions, or zram configuration.
5. **Zed must come from the official upstream tarball** (current working URL: `https://zed.dev/api/releases/stable/latest/zed-linux-x86_64.tar.gz` — 307s to the corresponding GitHub release asset), not Terra (Fedora glibc mismatch), Flatpak (breaks client-side decorations), or Homebrew (cask is macOS-only). The tarball extracts to `zed.app/`. On Zed 0.139+ the previously separate `bin/cli` and `bin/zed` binaries were consolidated into a single `bin/zed` — `/usr/bin/zed` symlinks to it, and `.desktop Exec=` points at the same path.
6. **Insync: install the `insync` GUI + `insync-nautilus` from the native EL10 repo** (`https://yum.insync.io/centos/10/`). The upstream RPM does not ship a systemd unit; we provide a user-level one (`files/system/usr/lib/systemd/user/insync.service`) that runs the sync engine via `insync --synchronous-full start` so the GUI window is only opened on demand. After first GUI launch, the user must uncheck "Start Insync at startup" in Preferences to avoid a duplicate-launch race against the systemd unit.
7. **Don't touch Nvidia/CUDA/Docker/Podman config.** The GDX base provides it correctly. For the AMD-primary + Nvidia-compute-only display arrangement, the only knob is `nvidia-drm.modeset=0` as a kernel arg — not a modprobe blacklist.
8. **CoolerControl: install `coolercontrold` only from the COPR** (`codifryed/CoolerControl`, `epel-10-x86_64` chroot — the COPR `.repo` file is self-contained and does NOT require enabling EPEL). The Qt `coolercontrol` desktop wrapper RPM is unnecessary: the daemon serves a web UI on `http://localhost:11987`. Use `--setopt=install_weak_deps=False` to skip the `python3-liquidctl` Recommend (would otherwise pull EPEL; we have no liquid cooling). `ipmi_si` + `ipmi_devintf` are autoloaded via `files/system/etc/modules-load.d/ipmi.conf` so `/dev/ipmi0` is available for `ipmitool`. The IPMI ↔ CoolerControl bridge uses the official `cc-plugin-custom-device` plugin (installed via its upstream `install.sh` to `/etc/coolercontrol/plugins/custom-device/`); declare per-channel `ipmitool` commands in `manifest.toml` with `privileged = true`, restart `coolercontrold`. Do NOT replace this with a custom file-sensor + glue-script architecture — the plugin supersedes that pattern.
9. **Profiling tools must be host-installed, not Distrobox-installed.** `perf` and `bpftrace` are built from the kernel source tree and must match the running kernel's ABI; a Distrobox ships them built for a different kernel and produces cryptic errors, miscounted events, or unresolved symbols. Same for ftrace consumers and anything reading `/sys/kernel/debug`. Userland Python profilers (`py-spy`, `scalene`, `austin`, `memray`, etc.) read process memory rather than kernel counters and don't have this constraint — those go in the conda env, not the recipe. The host profiling pack (`perf bpftrace sysstat strace ltrace numactl hwloc`) is all from CS10 AppStream/BaseOS.

## Working on the recipe

- Single `dnf install` transaction for all third-party packages in the same module is faster than per-package calls; keep `dnf clean all && rm -rf /var/cache/dnf /var/cache/yum` at the end of any package-installing script snippet to keep the image small.
- When adding kernel args, append to the existing `kargs` module's list rather than adding a second `kargs` module.
- The build is signed: `cosign.key` / `cosign.private` are gitignored; `cosign.pub` is committed and used by end users (`cosign verify --key cosign.pub …`).
- CI builds daily at 06:00 UTC (20 min after ublue upstream rebuilds), so the image picks up upstream Zed/Bluefin updates automatically.
- Day-to-day updates on the deployed system happen automatically via Bluefin's `uupd` daemon (6-hour timer, uses `bootc` under the hood). Manual on-demand update is `sudo bootc upgrade` then reboot — NOT `rpm-ostree upgrade`, which won't reliably re-apply `/usr/lib/bootc/kargs.d/` entries.
