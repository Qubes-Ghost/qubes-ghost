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
RESERVE_KB=$((8*1024*1024))            # keep 8 GiB free for dom0 itself (in KiB)

# --- 1) Turn swap OFF and keep it off ------------------------------------
swapoff -a || true                     # deactivate all swap now.
systemctl mask swap.target >/dev/null 2>&1 || true   # stop systemd re-enabling it.
# Mask every individual swap unit too, so nothing re-activates a swap device.
for u in $(systemctl list-unit-files --type=swap --no-legend 2>/dev/null | awk '{print $1}'); do
    systemctl mask "$u" >/dev/null 2>&1 || true
done
# Hard check: if ANY swap is still active, abort — we cannot promise no paging.
grep -q ^ /proc/swaps && awk 'NR>1{print}' /proc/swaps | grep -q . \
    && { echo "ERROR: swap is still active:"; cat /proc/swaps; exit 1; }

# --- 2) Size sanity: the pool must fit in dom0's RAM ----------------------
DOM0_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)          # dom0 total RAM (KiB)
WANT_KB=$(numfmt --from=iec "$SIZE" 2>/dev/null | awk '{print int($1/1024)}' || true)
[ -n "${WANT_KB:-}" ] || { echo "unparseable size '$SIZE'"; exit 1; }
# Requested size + reserve must not exceed what dom0 has, or dom0 could OOM.
[ $((WANT_KB + RESERVE_KB)) -le "$DOM0_KB" ] || {
    echo "tmpfs $SIZE + reserve exceeds dom0 RAM ($((DOM0_KB/1024/1024))G). Lower SIZE or raise dom0 memory."; exit 1; }

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

# --- 4) Register it as a Qubes storage pool ------------------------------
# Driver "file" (NOT file-reflink): reflink needs btrfs/XFS and does not work on
# tmpfs. revisions_to_keep=1 avoids keeping extra on-memory copies.
if ! qvm-pool | awk '{print $1}' | grep -qx ghost; then
    qvm-pool add ghost file -o dir_path="$MNT",revisions_to_keep=1 \
      || { echo "ERROR: could not create pool 'ghost'"; exit 1; }
fi
echo "pool 'ghost' ready. Next: ghost-load.sh"
