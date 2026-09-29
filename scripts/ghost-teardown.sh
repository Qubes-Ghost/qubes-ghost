#!/bin/bash
# ghost-teardown.sh - remove RAM-resident qubes and scrub their traces before power-off.
#
# WHAT IT DOES:
#   Finds every qube that has ANY volume in the "ghost" (RAM) pool, shuts them
#   down and removes them, scrubs their names from logs/journald/shell history,
#   then asserts sterility post-conditions. Only if all post-conditions pass does
#   it declare the machine safe to power off.
#
# NOTE ON POWER-OFF: the strongest guarantee comes from a real power-off (the
# tmpfs and its contents vanish). This script prepares for that; it does not
# power the machine off for you.

set -uo pipefail                       # (no -e: we want to attempt every cleanup
                                       #  step and AGGREGATE failures, not stop early)
set +o history 2>/dev/null || true
exec 9>/run/lock/qubes-ghost.lock
flock -n 9 || { echo "another ghost script is running"; exit 1; }
FAILED=0                                # set to 1 by any step that does not fully succeed

# Same space-separated parser as elsewhere (NOT colon-based).
vol_pool(){ qvm-volume info "$1:$2" 2>/dev/null | awk '$1=="pool"{print $2}'; }

# scrub_file - overwrite a file's contents before unlinking it.
#
# Plain `rm` only drops the directory entry; the blocks keep the data until they
# are reused, so qube names could be recovered from unallocated space. `shred`
# overwrites first, which is strictly better. Be clear about the limit, though:
# on a journaling or copy-on-write filesystem, and on any SSD with wear levelling
# and an FTL, overwriting a file is NOT a guarantee that every copy of those bytes
# is gone. This raises the cost of recovery; it does not make it impossible. The
# design does not rest on it (see the threat model).
scrub_file(){
    [ -e "$1" ] || return 0
    if command -v shred >/dev/null 2>&1; then
        shred -n 1 -u "$1" 2>/dev/null || rm -f "$1" 2>/dev/null
    else
        rm -f "$1" 2>/dev/null
    fi
}

# --- 1) Find qubes with any volume in the RAM pool ------------------------
echo "== finding qubes with any volume in 'ghost':"
GVMS=""
for vm in $(qvm-ls --raw-list); do
    for v in root private volatile; do
        [ "$(vol_pool "$vm" "$v")" = ghost ] && { GVMS="$GVMS $vm"; break; }
    done
done
GVMS=$(echo $GVMS | tr ' ' '\n' | sort -u | tr '\n' ' ')   # dedupe
echo "found:${GVMS:- none}"

# --- 2) Shut down and remove them ----------------------------------------
for vm in $GVMS; do
    [ "$vm" = ghost-vault ] && continue          # the vault is handled separately
    qvm-shutdown --wait "$vm" 2>/dev/null || qvm-kill "$vm" 2>/dev/null || true
    if qvm-remove -f "$vm" 2>/dev/null; then echo "removed: $vm"; else echo "!! not removed: $vm"; FAILED=1; fi
done
qvm-shutdown --wait ghost-vault 2>/dev/null || true

# --- 3) Scrub logs, journald, and history of the qube names --------------
for vm in $GVMS ghost-vault; do
    for f in /var/log/qubes/*"$vm"* /var/log/libvirt/libxl/"$vm"*; do
        scrub_file "$f"
    done
done
# qubesd's own log records qvm-remove with the names; strip matching lines.
if [ -n "${GVMS// /}" ]; then
    PAT=$(echo $GVMS ghost-vault | tr ' ' '|' | sed 's/|$//')
    # `sed -i` writes a new file and renames it over the old one, which leaves the
    # ORIGINAL content sitting in freed blocks. Filter into a new file, overwrite
    # the original in place, and only then replace it.
    QLOG=/var/log/qubes/qubesd.log
    if [ -f "$QLOG" ]; then
        if grep -vE "($PAT)" "$QLOG" > "$QLOG.clean" 2>/dev/null; then
            cat "$QLOG.clean" > "$QLOG" 2>/dev/null || true   # truncate+rewrite in place
            scrub_file "$QLOG.clean"
        fi
    fi
fi
history -c 2>/dev/null; scrub_file /root/.bash_history
# Restart journald against an empty store so nothing sensitive lingers in the journal.
systemctl stop systemd-journald systemd-journald.socket systemd-journald-dev-log.socket 2>/dev/null
rm -rf /var/log/journal/* /run/log/journal/* 2>/dev/null
systemctl start systemd-journald 2>/dev/null

# --- 3b) Remove the pool registration and unmount the tmpfs --------------
# Leaving the pool registered keeps a named artifact of this mode on disk and
# keeps "ghost" mounted. Remove it only once no volume references it.
if qvm-pool | awk '{print $1}' | grep -qx ghost; then
    if qvm-pool remove ghost 2>/dev/null; then echo "pool 'ghost' removed"
    else echo "!! could not remove pool 'ghost' (still in use?)"; FAILED=1; fi
fi
POOLMNT=/var/lib/qubes/ghost-pool
if mountpoint -q "$POOLMNT"; then
    umount "$POOLMNT" 2>/dev/null || umount -l "$POOLMNT" 2>/dev/null || { echo "!! could not unmount $POOLMNT"; FAILED=1; }
fi
chattr -i "$POOLMNT" 2>/dev/null || true
rmdir "$POOLMNT" 2>/dev/null || true

# --- 4) Assert sterility post-conditions ---------------------------------
echo "== post-conditions:"
LEFT=""
for vm in $(qvm-ls --raw-list); do
    [ "$vm" = ghost-vault ] && continue
    for v in root private volatile; do
        [ "$(vol_pool "$vm" "$v")" = ghost ] && LEFT="$LEFT $vm:$v"
    done
done
[ -n "${LEFT// /}" ] && { echo "!! volumes still in ghost:$LEFT"; FAILED=1; }
qvm-ls --running --raw-list | grep -qx ghost-vault && { echo "!! vault still running"; FAILED=1; }
qvm-pool | awk '{print $1}' | grep -qx ghost && { echo "!! pool 'ghost' still registered"; FAILED=1; }
mountpoint -q /var/lib/qubes/ghost-pool && { echo "!! ghost-pool still mounted"; FAILED=1; }
awk 'NR>1{print}' /proc/swaps | grep -q . && { echo "!! swap is active"; FAILED=1; }
sync

# --- 5) Verdict -----------------------------------------------------------
if [ "$FAILED" = 0 ]; then
    echo "DONE: post-conditions clean. Safe to power off."
else
    echo "!!! TEARDOWN NOT CLEAN - see '!!' above. Do NOT treat the disk as sterile."
    exit 1
fi
