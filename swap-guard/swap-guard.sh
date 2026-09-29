#!/bin/bash
# swap-guard.sh — detect swap coming back, wipe it, and shout about it.
#
# WHY: if you removed swap for amnesic reasons, a package update or an edited
# fstab could silently bring it back — and then RAM could be paged to disk. This
# guard runs on a randomized timer; if it ever finds active or backing swap, it
# disables and wipes it and raises a loud, visible notification.

L=/var/log/swap-guard.log

# What is ACTIVE right now, split by kind. /proc/swaps columns: Filename Type ...
# Type is "partition" (block device, incl. LVM and zram) or "file" (swapfile).
A=$(awk 'NR>1{print $1}' /proc/swaps)                     # all active swap names
ADEV=$(awk 'NR>1 && $2=="partition"{print $1}' /proc/swaps)  # active block-backed swap
AFILE=$(awk 'NR>1 && $2=="file"{print $1}' /proc/swaps)      # active swapfiles
# Backing volumes that are not necessarily active yet:
VLV=$(lvs --noheadings -o lv_path 2>/dev/null | grep -i swap)  # swap-named LVs
VZ=$(ls /dev/zram* 2>/dev/null)                               # zram devices (a common cause)

# Nothing to do only if every source is empty.
[ -z "$A" ] && [ -z "$VLV" ] && [ -z "$VZ" ] && exit 0

swapoff -a 2>/dev/null                                    # turn any active swap off immediately

WIPED=""; FAILED=""
wipe_dev(){                                               # overwrite a block device
    if blkdiscard "$1" 2>/dev/null || dd if=/dev/zero of="$1" bs=4M oflag=direct 2>/dev/null; then
        WIPED="$WIPED $1"
    else
        FAILED="$FAILED $1"
    fi
}
# Block-backed swap: active partitions, swap-named LVs, and zram (dedupe by sort).
for s in $(printf '%s\n' $ADEV $VLV $VZ | sort -u); do
    [ -b "$s" ] || continue
    # zram cannot be discarded/zeroed the same way; resetting it frees its pages.
    case "$s" in
        /dev/zram*) echo 1 > "/sys/block/$(basename "$s")/reset" 2>/dev/null \
                        && WIPED="$WIPED $s" || FAILED="$FAILED $s" ;;
        *) wipe_dev "$s" ;;
    esac
done
# Swapfiles: overwrite the file contents, then remove the file.
for f in $AFILE; do
    [ -f "$f" ] || continue
    if { command -v shred >/dev/null 2>&1 && shred -n1 "$f" 2>/dev/null; } \
        || dd if=/dev/zero of="$f" bs=4M 2>/dev/null; then
        rm -f "$f" 2>/dev/null; WIPED="$WIPED $f"
    else
        FAILED="$FAILED $f"
    fi
done

# Report honestly. Only claim "wiped" for what actually wiped; if anything failed,
# say so LOUDER, because failed wipe on re-appeared swap is the dangerous case.
if [ -n "${FAILED// /}" ]; then
    echo "$(date -Is) SWAP DETECTED active=[$A] wiped=[$WIPED] FAILED=[$FAILED]" >> "$L"
    MSG="Swap re-appeared and could NOT be fully wiped: $FAILED. See $L"
    URG=critical
else
    echo "$(date -Is) SWAP DETECTED active=[$A] wiped=[$WIPED] ok" >> "$L"
    MSG="Swap was detected and wiped: $WIPED. See $L"
    URG=critical
fi
# dom0 has no network by design, so the alert channel is the local desktop + log.
sudo -u user DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    notify-send -u "$URG" 'SWAP-GUARD' "$MSG" 2>/dev/null
