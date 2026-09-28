#!/bin/bash
# swap-guard.sh — detect swap coming back, wipe it, and shout about it.
#
# WHY: if you removed swap for amnesic reasons, a package update or an edited
# fstab could silently bring it back — and then RAM could be paged to disk. This
# guard runs on a randomized timer; if it ever finds active or backing swap, it
# disables and wipes it and raises a loud, visible notification.

L=/var/log/swap-guard.log
A=$(awk 'NR>1{print $1}' /proc/swaps)                     # currently ACTIVE swap devices
V=$(lvs --noheadings -o lv_path 2>/dev/null | grep -i swap) # any swap-named backing LVs

# Nothing to do if there is neither active swap nor a swap-backing volume.
[ -z "$A" ] && [ -z "$V" ] && exit 0

swapoff -a 2>/dev/null                                    # turn any active swap off immediately
# Wipe each backing volume: prefer fast discard, fall back to zeroing.
for s in $V; do
    blkdiscard "$s" 2>/dev/null || dd if=/dev/zero of="$s" bs=4M oflag=direct 2>/dev/null
done

echo "$(date -Is) SWAP DETECTED active=[$A] lv=[$V] wiped" >> "$L"   # audit trail
# dom0 has no network by design, so the alert channel is the local desktop + log.
sudo -u user DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    notify-send -u critical 'SWAP-GUARD' "Swap was detected and wiped. See $L" 2>/dev/null
