#!/bin/bash
# ghost-ram-pool.sh - build a RAM-backed qube pool for the current boot profile.
#
# The pool is a thin LVM pool living inside a tmpfs, so nothing it holds can
# reach a disk and everything is gone at power off.
#
# Why not simply point a file-based qube pool at the tmpfs:
#
#   - the "file" driver registers volumes in the database and then writes
#     nothing at all; a clone reports success, the pool stays empty at zero
#     bytes, and the qube is a shell that cannot boot. Measured, not guessed.
#   - "file-reflink" needs a filesystem with reflink support. tmpfs has none.
#   - a plain copy into a tmpfs also loses thin provisioning: every clone of a
#     template costs its full size in RAM instead of almost nothing.
#
# So the layers are: tmpfs (no swap) -> sparse file -> loop device -> physical
# volume -> volume group -> thin pool -> qube pool. That looks like a lot, but
# every layer above the tmpfs is the same machinery the distribution already
# uses for its on-disk pool, which is the part that has to be trustworthy.
#
# Memory is spent only as blocks are actually written: the backing file is
# sparse and the thin pool allocates on demand. An unwritten clone is free.
set -eu

MNT=${MNT:-/var/lib/qubes/ghost-pool}
IMG=$MNT/pool.img
VG=${VG:-ghostvg}
TP=${TP:-ghostpool}
POOL=${POOL:-ghost}

# dom0 memory left outside the pool, for dom0 itself and its own RAM-backed root
RESERVE_KB=${RESERVE_KB:-$((8 * 1024 * 1024))}
# headroom kept inside the tmpfs, outside the backing file
MARGIN_KB=${MARGIN_KB:-$((256 * 1024))}

SIZE="${1:-auto}"

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run this as root"

DOM0_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
if [ "$SIZE" = auto ]; then
    AUTO_KB=$((DOM0_KB - RESERVE_KB))
    [ "$AUTO_KB" -gt $((2 * 1024 * 1024)) ] ||
        die "dom0 memory minus the reserve leaves too little for a pool"
    SIZE="$((AUTO_KB / 1024))M"
fi

# ---------------------------------------------------------------- no swap ----
# A swapped-out page is a page written to disk, which would defeat the whole
# point. Turn swap off first and keep it off, and refuse to continue if the
# kernel cannot promise the tmpfs itself is never swapped.
swapoff -a 2>/dev/null || true
systemctl mask --now swap.target systemd-zram-setup@zram0.service >/dev/null 2>&1 || true
[ -z "$(swapon --show=NAME --noheadings 2>/dev/null)" ] || die "swap is still active"

# ------------------------------------------------------------------ tmpfs ----
if ! mountpoint -q "$MNT"; then
    mkdir -p "$MNT"
    mount -t tmpfs -o "size=$SIZE,mode=700,noswap" ghost-tmpfs "$MNT" ||
        die "cannot mount the tmpfs with noswap (kernel too old?)"
fi
findmnt -n -o OPTIONS "$MNT" | grep -q noswap || die "tmpfs mounted without noswap"

# ------------------------------------------------------- sparse backing file --
TMPFS_KB=$(df -k --output=size "$MNT" | tail -1 | tr -d ' ')
IMG_KB=$((TMPFS_KB - MARGIN_KB))
[ "$IMG_KB" -gt $((1024 * 1024)) ] || die "tmpfs too small for a pool"

[ -e "$IMG" ] && die "$IMG already exists - run the teardown script first"
truncate -s "${IMG_KB}K" "$IMG"

LOOP=$(losetup --find --show "$IMG") || die "cannot attach a loop device"

# ------------------------------------------------------------------- LVM ------
# dom0 may carry an LVM device filter that hides anything it does not expect.
# If it hides the loop device, pvcreate fails here rather than silently later.
pvcreate -f -y "$LOOP" >/dev/null ||
    die "pvcreate refused $LOOP (an LVM device filter may exclude loop devices)"
pvs --noheadings -o pv_name 2>/dev/null | grep -qF "$LOOP" ||
    die "$LOOP is not visible to LVM after pvcreate"

vgcreate "$VG" "$LOOP" >/dev/null || die "vgcreate failed"
# 95% leaves room for the thin pool's own metadata volume
lvcreate --type thin-pool -l 95%FREE -n "$TP" "$VG" >/dev/null ||
    die "cannot create the thin pool"

# ------------------------------------------------------------- qube pool ------
qvm-pool add "$POOL" lvm_thin \
    -o "volume_group=$VG,thin_pool=$TP,revisions_to_keep=1" >/dev/null ||
    die "cannot register the qube pool"

echo "pool '$POOL' ready: $(lvs --noheadings -o lv_size "$VG/$TP" | tr -d ' ') in RAM, nothing on disk"
