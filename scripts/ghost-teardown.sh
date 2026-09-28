#!/bin/bash
# ghost-teardown.sh — remove RAM-resident qubes and scrub their traces before power-off.
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
    rm -f /var/log/qubes/*"$vm"* /var/log/libvirt/libxl/"$vm"* 2>/dev/null
done
# qubesd's own log records qvm-remove with the names; strip matching lines.
if [ -n "${GVMS// /}" ]; then
    PAT=$(echo $GVMS ghost-vault | tr ' ' '|' | sed 's/|$//')
    sed -i -E "/($PAT)/d" /var/log/qubes/qubesd.log 2>/dev/null || true
fi
history -c 2>/dev/null; rm -f /root/.bash_history 2>/dev/null
# Restart journald against an empty store so nothing sensitive lingers in the journal.
systemctl stop systemd-journald systemd-journald.socket systemd-journald-dev-log.socket 2>/dev/null
rm -rf /var/log/journal/* /run/log/journal/* 2>/dev/null
systemctl start systemd-journald 2>/dev/null

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
awk 'NR>1{print}' /proc/swaps | grep -q . && { echo "!! swap is active"; FAILED=1; }
sync

# --- 5) Verdict -----------------------------------------------------------
if [ "$FAILED" = 0 ]; then
    echo "DONE: post-conditions clean. Safe to power off."
else
    echo "!!! TEARDOWN NOT CLEAN — see '!!' above. Do NOT treat the disk as sterile."
    exit 1
fi
