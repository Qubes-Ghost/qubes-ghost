#!/bin/bash
# ghost-ram-pool-down.sh - take the RAM-backed pool apart, innermost layer first.
#
# Nothing here is needed for secrecy: the pool lives in RAM and is gone at power
# off either way. It exists so a reboot does not hang on a volume group whose
# backing store is about to disappear, and so the pool can be rebuilt without
# rebooting while testing.
#
# Every step is best effort on purpose. A machine must always be able to shut
# down, so a layer that is already gone, or refuses to go, must not stop the
# rest.
set -u

MNT=${MNT:-/var/lib/qubes/ghost-pool}
IMG=$MNT/pool.img
VG=${VG:-ghostvg}
POOL=${POOL:-ghost}

[ "$(id -u)" = 0 ] || { echo "run this as root" >&2; exit 1; }

# qubes still placed in the pool would keep its volumes busy
qvm-shutdown --wait --all >/dev/null 2>&1 || true

qvm-pool remove "$POOL" >/dev/null 2>&1 || true
vgchange -an "$VG" >/dev/null 2>&1 || true
vgremove -f "$VG" >/dev/null 2>&1 || true

LOOP=$(losetup -j "$IMG" 2>/dev/null | cut -d: -f1)
if [ -n "${LOOP:-}" ]; then
    pvremove -ff -y "$LOOP" >/dev/null 2>&1 || true
    losetup -d "$LOOP" >/dev/null 2>&1 || true
fi

rm -f "$IMG"
umount "$MNT" >/dev/null 2>&1 || true

# put dom0's own swap back the way the distribution had it
systemctl unmask swap.target systemd-zram-setup@zram0.service >/dev/null 2>&1 || true

mountpoint -q "$MNT" && echo "note: $MNT is still mounted" || echo "pool torn down"
