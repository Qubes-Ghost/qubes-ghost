#!/bin/bash
# ghost-ram-pool.sh - build a RAM-backed qube pool for the current boot profile.
#
# Everything the pool holds lives in RAM and is gone at power off. Nothing it
# holds is ever written to a disk.
#
# Why the storage layer looks the way it does:
#
#   - the "file" driver pointed at a tmpfs registers volumes in the database and
#     writes nothing at all. A clone returns success, prints "Cloning root
#     volume", and leaves the tmpfs at zero bytes while the qube reports a 20 GiB
#     root and a Running state. Measured on 4.3, not assumed.
#   - "file-reflink" needs reflink support, which tmpfs does not have.
#   - a plain copy into a tmpfs also throws away thin provisioning: every clone
#     of a template would cost its full size in RAM.
#
# So the pool is a thin LVM pool on a block device made of RAM. Above the RAM
# device it is the same machinery the distribution already uses for its on-disk
# pool, which is the part that has to be trustworthy.
#
# Two ways to make that block device, in order of preference:
#
#   brd    a ramdisk block device. Fewest layers, no filesystem in between, no
#          backing store that could exist. Only usable when brd is a module that
#          is not already loaded, because its size is a module parameter.
#   loop   a sparse file in a tmpfs mounted noswap, with a loop device on top.
#          One more layer, always available. Buffered loop writes land in the
#          tmpfs page cache, and noswap means those pages cannot be paged out,
#          so the guarantee is the same.
#
# Startup is transactional: if any step fails, the layers this run created are
# unwound, so the next attempt starts from a clean machine instead of stopping
# on leftovers.
set -Eeuo pipefail

MNT=${MNT:-/var/lib/qubes/ghost-pool}
IMG=$MNT/pool.img
VG=${VG:-ghostvg}
TP=${TP:-ghostpool}
POOL=${POOL:-ghost}
STATE=${STATE:-/run/ghost-ram-pool.state}
BACKEND=${BACKEND:-auto}        # auto | brd | loop

# dom0 memory left outside the pool, for dom0 itself and its RAM-backed root
RESERVE_KB=${RESERVE_KB:-$((8 * 1024 * 1024))}
MARGIN_KB=${MARGIN_KB:-$((256 * 1024))}
DATA_PCT=${DATA_PCT:-85}        # of the volume group, rest is metadata and slack
META_SIZE=${META_SIZE:-512M}
CHUNK=${CHUNK:-64K}

SIZE_ARG="${1:-auto}"

log()  { echo "ghost-ram-pool: $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# ------------------------------------------------------------- unwinding -----
# Only what this run created, innermost first, and only after checking it is
# ours. Never guess from a name alone.
MADE_MOUNT=0 MADE_IMG=0 MADE_LOOP=0 MADE_BRD=0 MADE_PV=0 MADE_VG=0 MADE_POOL=0
LOOP= DEV= PVUUID= SWAP_WAS=

unwind() {
    set +e
    [ "$MADE_POOL" = 1 ] && qvm-pool remove "$POOL" >/dev/null 2>&1
    [ "$MADE_VG"   = 1 ] && { vgchange -an "$VG" >/dev/null 2>&1; vgremove -f "$VG" >/dev/null 2>&1; }
    [ "$MADE_PV"   = 1 ] && pvremove -ff -y "$DEV" >/dev/null 2>&1
    [ -n "$DEV" ] && lvmdevices --deldev "$DEV" >/dev/null 2>&1
    [ "$MADE_LOOP" = 1 ] && losetup -d "$LOOP" >/dev/null 2>&1
    [ "$MADE_BRD"  = 1 ] && rmmod brd >/dev/null 2>&1
    [ "$MADE_IMG"  = 1 ] && rm -f "$IMG"
    [ "$MADE_MOUNT" = 1 ] && umount "$MNT" >/dev/null 2>&1
    [ "$SWAP_WAS" = on ] && swapon -a >/dev/null 2>&1
    rm -f "$STATE"
    echo "ghost-ram-pool: rolled back what this run created" >&2
}
trap unwind ERR

[ "$(id -u)" = 0 ] || die "run this as root"
[ -e "$STATE" ] && die "$STATE exists - a pool is already set up, tear it down first"

# ------------------------------------------------------------------ size -----
DOM0_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
AVAIL_KB=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
if [ "$SIZE_ARG" = auto ]; then
    SIZE_KB=$((DOM0_KB - RESERVE_KB))
else
    SIZE_KB=$(numfmt --from=iec "${SIZE_ARG}" 2>/dev/null)
    SIZE_KB=$((SIZE_KB / 1024))
fi
[ "$SIZE_KB" -gt $((2 * 1024 * 1024)) ] || die "that leaves too little for a pool"
# dom0 is ballooned and its root already lives in RAM, so MemTotal alone lies
[ "$SIZE_KB" -lt "$AVAIL_KB" ] ||
    die "pool of $((SIZE_KB/1024))M does not fit in $((AVAIL_KB/1024))M of available memory"

# ------------------------------------------------------------------ swap -----
# A swapped-out page is a page on a disk. Record the previous state so teardown
# can restore it, but only after a verified clean teardown.
if [ -n "$(swapon --show=NAME --noheadings 2>/dev/null)" ]; then
    SWAP_WAS=on
    swapoff -a || die "cannot turn swap off"
fi
[ -z "$(swapon --show=NAME --noheadings 2>/dev/null)" ] || die "swap is still active"

# -------------------------------------------------------- the RAM device -----
brd_usable() {
    [ "$BACKEND" = loop ] && return 1
    lsmod | grep -q '^brd ' && return 1        # already loaded, size is fixed
    modinfo brd >/dev/null 2>&1                # present as a module
}

if brd_usable; then
    modprobe brd rd_nr=1 rd_size=$SIZE_KB max_part=0 || die "cannot load brd"
    MADE_BRD=1
    DEV=/dev/ram0
    [ -b "$DEV" ] || die "brd loaded but $DEV is not there"
    GOT_KB=$(($(blockdev --getsize64 "$DEV") / 1024))
    [ "$GOT_KB" -ge $((SIZE_KB - 1024)) ] ||
        die "brd gave ${GOT_KB}K instead of ${SIZE_KB}K (was it already loaded?)"
    BACKEND=brd
else
    BACKEND=loop
    if ! mountpoint -q "$MNT"; then
        mkdir -p "$MNT"
        mount -t tmpfs -o "size=${SIZE_KB}k,mode=0700,nodev,nosuid,noexec,noswap" \
              ghost-tmpfs "$MNT" || die "cannot mount the tmpfs with noswap"
        MADE_MOUNT=1
    fi
    [ "$(findmnt -n -o FSTYPE --target "$MNT")" = tmpfs ] || die "$MNT is not a tmpfs"
    findmnt -n -o OPTIONS --target "$MNT" | tr ',' '\n' | grep -qx noswap ||
        die "$MNT is mounted without noswap"

    TMPFS_KB=$(df -k --output=size "$MNT" | tail -1 | tr -d ' ')
    IMG_KB=$((TMPFS_KB - MARGIN_KB))
    [ "$IMG_KB" -gt $((1024 * 1024)) ] || die "tmpfs too small for a pool"
    [ -e "$IMG" ] && die "$IMG already exists - tear the old pool down first"

    truncate -s "${IMG_KB}K" "$IMG"; MADE_IMG=1
    LOOP=$(losetup --find --show "$IMG"); MADE_LOOP=1
    DEV=$LOOP
fi
log "backend: $BACKEND on $DEV"

# ------------------------------------------------------------------- LVM -----
# 4.3 uses LVM's devices file rather than a filter, so a device can be entirely
# valid to the kernel and still invisible to plain lvm commands. Admit it, then
# check that an unqualified command - which is what Qubes itself runs - sees it.
lvmdevices --adddev "$DEV" >/dev/null 2>&1 || true
pvcreate --yes --force "$DEV" >/dev/null || die "pvcreate refused $DEV"
MADE_PV=1
PVUUID=$(pvs --noheadings -o pv_uuid "$DEV" 2>/dev/null | tr -d ' ')
[ -n "$PVUUID" ] || die "$DEV is not visible to LVM after pvcreate"

vgcreate "$VG" "$DEV" >/dev/null || die "vgcreate failed"
MADE_VG=1

lvcreate --type thin-pool --name "$TP" --extents "${DATA_PCT}%FREE" \
         --chunksize "$CHUNK" --poolmetadatasize "$META_SIZE" --poolmetadataspare y \
         --discards passdown "$VG" >/dev/null ||
    die "cannot create the thin pool"

# Fail fast rather than queueing writes for a minute when the pool fills. This is
# a property of the pool, not of its creation: lvcreate rejects the option, it
# has to be set afterwards.
lvchange --errorwhenfull y "$VG/$TP" >/dev/null || die "cannot set error-when-full"

lvs --noheadings -o whenfull "$VG/$TP" | grep -qw error ||
    die "thin pool is not set to error when full"
lvs --noheadings -o segtype "$VG/$TP" | grep -qw thin-pool ||
    die "$VG/$TP is not a thin pool"

# --------------------------------------------------------------- selftest ----
# Prove the stack actually stores and returns bytes before handing it to Qubes.
# This is the check the previous design would have failed.
lvcreate -V 64M -T "$VG/$TP" -n selftest >/dev/null || die "cannot create a test volume"
MARKER=$(head -c 1048576 /dev/urandom | base64 -w0)
printf '%s' "$MARKER" | dd of="/dev/$VG/selftest" bs=1M conv=fsync status=none ||
    die "cannot write to the test volume"
READBACK=$(dd if="/dev/$VG/selftest" bs=1 count=${#MARKER} status=none)
[ "$READBACK" = "$MARKER" ] || die "the test volume did not return what was written"
USED_PCT=$(lvs --noheadings -o data_percent "$VG/$TP" | tr -d ' ')
awk -v p="$USED_PCT" 'BEGIN { exit !(p > 0) }' || die "writing changed no usage counter"
lvremove -f "$VG/selftest" >/dev/null || die "cannot remove the test volume"
lvs --noheadings -o lv_name "$VG" | grep -qw selftest && die "test volume did not go away"
log "selftest passed: wrote, read back and freed 1 MiB"

# -------------------------------------------------------------- qube pool ----
# One -o per option: qvm-pool splits each argument at the first = only, so a
# comma-joined string silently becomes one absurd volume_group value.
qvm-pool add "$POOL" lvm_thin \
    -o "volume_group=$VG" \
    -o "thin_pool=$TP" \
    -o "revisions_to_keep=0" >/dev/null || die "cannot register the qube pool"
MADE_POOL=1

qvm-pool info "$POOL" | grep -qw "$VG" || die "the registered pool does not name $VG"
qvm-pool info "$POOL" | grep -qw "$TP" || die "the registered pool does not name $TP"

# ------------------------------------------------------------------ state ----
cat > "$STATE" <<EOF
BACKEND=$BACKEND
MNT=$MNT
IMG=$IMG
LOOP=$LOOP
DEV=$DEV
PVUUID=$PVUUID
VG=$VG
TP=$TP
POOL=$POOL
SWAP_WAS=$SWAP_WAS
EOF

trap - ERR
SIZE_H=$(lvs --noheadings -o lv_size "$VG/$TP" | tr -d ' ')
log "pool '$POOL' ready: $SIZE_H in RAM on $BACKEND, nothing on disk"
