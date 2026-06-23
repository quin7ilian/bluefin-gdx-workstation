#!/usr/bin/env bash
# bluefin-gdx-swtpm-policy.sh
#
# Load the swtpm SELinux policy module on the running system (run-if-absent).
#
# Win11 VMs need an emulated TPM 2.0 (swtpm). On this bootc/ostree base swtpm's
# per-VM log under /var/log/swtpm (recreated at boot by
# tmpfiles.d/bluefin-gdx-swtpm.conf) ends up labeled virt_log_t, which the base
# policy does NOT let swtpm_t write — so swtpm dies on launch with the
# misleading "swtpm ... does not support TPM 2" and every TPM-2.0 VM fails to
# start. The shipped .cil restores that one allow.
#
# Why this runs at boot instead of being baked in at image-build time: loading
# the module with `semodule -i` inside the BuildKit/overlayfs build sandbox is
# fragile — the SELinux store's 'active' dir is inherited from a read-only lower
# layer, and libsemanage's store transaction (atomic rename / relink) breaks in
# the overlay in ways that shift with upstream churn. It twice began exiting 0
# while silently failing to register the module, red-building the whole image
# over this one non-critical allow. On the deployed system /etc/selinux is an
# ordinary writable filesystem, so `semodule -i` works the way it's designed to
# — the same path Silverblue/Bluefin use for local `audit2allow` policy.
#
# Idempotent + self-healing: if the module is already in the store this is a
# sub-second no-op, so the boot cost (a brief policy rebuild) is only paid the
# first time — or again if a future image update / ostree /etc merge ever drops
# the store entry, in which case the next boot re-adds it. Priority 300 leaves
# the default 400 free for local overrides.

set -euo pipefail

cil=/usr/share/selinux/packages/bluefin-gdx-swtpm.cil

# Already in the store? Don't trigger a policy rebuild on every boot.
if semodule -lfull 2>/dev/null | grep -q 'bluefin-gdx-swtpm'; then
    exit 0
fi

test -f "$cil" || {
    echo "bluefin-gdx-swtpm-policy: $cil missing — files module didn't stage it?" >&2
    exit 1
}

echo "bluefin-gdx-swtpm-policy: installing SELinux module (swtpm_t -> virt_log_t log write)…"
semodule -X 300 -i "$cil"
echo "bluefin-gdx-swtpm-policy: installed bluefin-gdx-swtpm at priority 300"
