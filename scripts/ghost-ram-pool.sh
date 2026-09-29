#!/bin/bash
# ghost-ram-pool.sh — create the RAM-backed Qubes storage pool.
#
# WHAT IT DOES, IN ONE LINE:
#   Guarantees swap is off, mounts a noswap tmpfs, and registers it as a Qubes
#   storage pool named "ghost" so that qubes placed there live only in RAM.
#
# WHY IT MATTERS:
#   Everything the sensitive qubes write must stay in volatile memory. Two things
#   could betray that: (1) swap paging RAM out to the disk, (2) the pool being
#   backed by real storage. This script closes both, and refuses to run if it
#   cannot prove them closed (fail-closed).
#
# USAGE:  sudo ghost-ram-pool.sh [SIZE]     e.g. sudo ghost-ram-pool.sh 20G

set -euo pipefail          # -e: stop on any error; -u: undefined var is an error;
                           # -o pipefail: a failing stage fails the whole pipe.
set +o history 2>/dev/null || true   # don't record these commands in shell history.

# --- Single-instance lock -------------------------------------------------
# All four ghost scripts share this lock so two of them can never run at once
# (which could, e.g., detach media mid-restore). flock -n = fail immediately if
# another script holds it, rather than waiting.
exec 9>/run/lock/qubes-ghost.lock
flock -n 9 || { echo "another ghost script is already running"; exit 1; }

MNT=/var/lib/qubes/ghost-pool          # where the tmpfs is mounted
SIZE="${1:-40G}"                       # requested pool size; default 40G
# Reserve kept free for dom0 itself. Configurable because the right value depends on
# how much dom0 does besides hosting the pool; 8G is a deliberately safe default.
RESERVE_KB_H="${GHOST_RESERVE:-8G}"
RESERVE_KB=$(numfmt --from=iec "$RESERVE_KB_H" 2>/dev/null | awk '{print int($1/1024)}' || true)
[ -n "${RESERVE_KB:-}" ] && [ "$RESERVE_KB" -ge 0 ] 2>/dev/null \
    || { echo "unparseable GHOST_RESERVE '$RESERVE_KB_H'"; exit 1; }

# --- 1) Turn swap OFF and keep it off ------------------------------------
swapoff -a || true                     # deactivate all swap now.
systemctl mask swap.target >/dev/null 2>&1 || true   # stop systemd re-enabling it.
# Mask every individual swap unit too, so nothing re-activates a swap device.
for u in $(systemctl list-unit-files --type=swap --no-legend 2>/dev/null | awk '{print $1}'); do
    systemctl mask "$u" >/dev/null 2>&1 || true
done
# Hard check: if ANY swap is still active, abort — we cannot promise no paging.
# /proc/swaps always has a header line, so "active swap" means 2 or more lines.
if [ "$(awk 'NR>1' /proc/swaps | grep -c .)" -gt 0 ]; then
    echo "ERROR: swap is still active:"; cat /proc/swaps; exit 1
fi

# --- 2) Size sanity: the pool must fit in dom0's RAM ----------------------
DOM0_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)          # dom0 total RAM (KiB)
WANT_KB=$(numfmt --from=iec "$SIZE" 2>/dev/null | awk '{print int($1/1024)}' || true)
[ -n "${WANT_KB:-}" ] || { echo "unparseable size '$SIZE'"; exit 1; }
# Requested size + reserve must not exceed what dom0 has, or dom0 could OOM.
if [ $((WANT_KB + RESERVE_KB)) -gt "$DOM0_KB" ]; then
    FITS_KB=$((DOM0_KB - RESERVE_KB))
    echo "ERROR: tmpfs $SIZE plus the ${RESERVE_KB_H} reserve exceeds dom0 RAM ($((DOM0_KB/1024/1024))G)."
    if [ "$FITS_KB" -gt 0 ]; then
        echo "       The largest pool that fits right now is about $((FITS_KB/1024/1024))G."
    else
        echo "       dom0 has less RAM than the reserve alone; no pool of any size can be created."
    fi
    echo "       Either lower SIZE, lower the reserve (GHOST_RESERVE), or raise dom0_mem on the Xen"
    echo "       command line (re-sign /boot afterwards if your platform measures it)."
    exit 1
fi

# --- 3) Mount the tmpfs (noswap is mandatory) ----------------------------
if ! mountpoint -q "$MNT"; then
    mkdir -p "$MNT"
    chattr -i "$MNT" 2>/dev/null || true    # clear immutable bit if left from a prior run.
    # The mount dir must be empty: leftovers would be real files on disk.
    if [ -n "$(ls -A "$MNT")" ]; then
        echo "WARNING: $MNT is not empty (crash residue?) — deleting its contents from disk"
        rm -rf "${MNT:?}"/*                  # ${MNT:?} guards against an empty var wiping /
    fi
    chattr +i "$MNT"                         # make the mountpoint immutable so nothing
                                             # can write *under* the mount by accident.
    # noswap is the whole point: without it, tmpfs pages could be swapped to disk.
    # If the kernel lacks noswap support, we fail closed rather than pretend.
    mount -t tmpfs -o size="$SIZE",mode=0700,noswap ghost-tmpfs "$MNT" \
      || { echo "ERROR: kernel has no tmpfs 'noswap' support — guarantee cannot hold, stopping"; exit 1; }
    echo "tmpfs $SIZE (noswap) mounted"
fi

# Verify unconditionally, including on a re-run where the mount already existed.
# A mount already being present at this path is NOT evidence that it is the mount
# we want: it could be a plain tmpfs without noswap, or a disk-backed filesystem
# someone left there. Skipping the check on the "already mounted" path was a
# fail-open: sensitive volumes would then land on storage that can page out.
FSTYPE=$(findmnt -n -o FSTYPE --mountpoint "$MNT" 2>/dev/null || true)
MOPTS=$(findmnt -n -o OPTIONS --mountpoint "$MNT" 2>/dev/null || true)
[ "$FSTYPE" = tmpfs ] || {
    echo "ERROR: $MNT is not tmpfs (found '${FSTYPE:-nothing mounted}') — refusing to use it"; exit 1; }
case ",$MOPTS," in
    *,noswap,*) ;;
    *) echo "ERROR: $MNT is mounted without 'noswap' (options: $MOPTS)."
       echo "       Its pages could be written to swap, so the guarantee does not hold."
       echo "       Unmount it and re-run so it is mounted correctly."; exit 1 ;;
esac

# --- 4) Register it as a Qubes storage pool ------------------------------
# Driver "file" (NOT file-reflink): reflink needs btrfs/XFS and does not work on
# tmpfs. revisions_to_keep=1 avoids keeping extra on-memory copies.
if ! qvm-pool | awk '{print $1}' | grep -qx ghost; then
    qvm-pool add ghost file -o dir_path="$MNT",revisions_to_keep=1 \
      || { echo "ERROR: could not create pool 'ghost'"; exit 1; }
fi

# A pool merely NAMED "ghost" proves nothing: a stale registration from a previous
# boot, or one planted deliberately, could point at real storage. The placement
# checks in ghost-load.sh compare pool NAMES, so if the name maps to a disk-backed
# pool every one of those checks passes while the data goes to the NVMe. Bind the
# name to the thing we actually built, here and once.
POOL_INFO=$(qvm-pool info ghost 2>/dev/null || true)
POOL_DRV=$(printf '%s\n' "$POOL_INFO" | awk '$1=="driver"{print $2; exit}')
POOL_DIR=$(printf '%s\n' "$POOL_INFO" | awk '$1=="dir_path"{print $2; exit}')
[ "$POOL_DRV" = file ] || {
    echo "ERROR: pool 'ghost' uses driver '${POOL_DRV:-unknown}', expected 'file'."
    echo "       Refusing to continue: this pool is not the RAM pool this script creates."; exit 1; }
[ "$POOL_DIR" = "$MNT" ] || {
    echo "ERROR: pool 'ghost' points at '${POOL_DIR:-unknown}', expected '$MNT'."
    echo "       Refusing to continue: data placed there would not be in RAM."; exit 1; }

echo "pool 'ghost' ready and verified (driver=$POOL_DRV, dir=$POOL_DIR, tmpfs+noswap)."
echo "Next: ghost-load.sh"
