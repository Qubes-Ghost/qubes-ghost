#!/bin/bash
# ghost-ram-pool-down.sh - take the RAM-backed pool apart, innermost layer first.
#
# Nothing here is needed for secrecy: the pool lives in RAM and is gone at power
# off either way. It exists so a reboot does not hang on a volume group whose
# backing store is about to vanish, and so the pool can be rebuilt while testing
# without rebooting.
#
# Two rules, both learned the hard way:
#
#   - act only on what this machine's own state file says this setup created,
#     and only after checking it really is ours. A teardown that trusts a name
#     can destroy an unrelated volume group that happens to be called the same.
#   - if a layer refuses to go, stop. Deleting the backing file while the loop
#     device is still attached leaves a live device over a deleted inode that
#     nothing can find afterwards.
#
# It never blocks a shutdown: it reports failure with an exit code instead.
set -uo pipefail

STATE=${STATE:-/run/ghost-ram-pool.state}

log()  { echo "ghost-ram-pool-down: $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || fail "run this as root"

if [ ! -e "$STATE" ]; then
    log "no state file, nothing of ours to take apart"
    exit 0
fi
# shellcheck disable=SC1090
. "$STATE"

# ------------------------------------------------------------- provenance ----
# Everything below is destructive, so each fact is checked before it is used.
if vgs --noheadings -o vg_name 2>/dev/null | grep -qw "$VG"; then
    PVCOUNT=$(vgs --noheadings -o pv_count "$VG" | tr -d ' ')
    [ "$PVCOUNT" = 1 ] ||
        fail "$VG spans $PVCOUNT physical volumes, expected one - not touching it"
    PVNAME=$(pvs --noheadings -o pv_name --select "vg_name=$VG" | tr -d ' ')
    [ "$PVNAME" = "$DEV" ] ||
        fail "$VG sits on $PVNAME, not on our $DEV - not touching it"
    NOWUUID=$(pvs --noheadings -o pv_uuid "$DEV" 2>/dev/null | tr -d ' ')
    [ "$NOWUUID" = "$PVUUID" ] ||
        fail "$DEV carries a different physical volume now - not touching it"
fi
if [ "$BACKEND" = loop ] && [ -n "${LOOP:-}" ]; then
    BACKING=$(losetup --noheadings -O BACK-FILE "$LOOP" 2>/dev/null | tr -d ' ')
    [ -z "$BACKING" ] || [ "$BACKING" = "$IMG" ] ||
        fail "$LOOP is backed by $BACKING, not by our $IMG - not touching it"
fi

# ------------------------------------------------------------- unwinding -----
# Qubes first: a running qube holds its volumes open.
qvm-shutdown --wait --all >/dev/null 2>&1 || true
qvm-pool remove "$POOL" >/dev/null 2>&1 || true
qvm-pool list 2>/dev/null | grep -qw "$POOL" && fail "qube pool $POOL is still registered"

if vgs --noheadings -o vg_name 2>/dev/null | grep -qw "$VG"; then
    vgchange -an "$VG" >/dev/null 2>&1 || fail "cannot deactivate $VG - stopping here"
    lvs --noheadings -o lv_attr "$VG" 2>/dev/null | grep -q '^ *....a' &&
        fail "$VG still has active volumes - stopping here"
fi

if [ "$BACKEND" = loop ] && [ -n "${LOOP:-}" ] && losetup "$LOOP" >/dev/null 2>&1; then
    losetup -d "$LOOP" >/dev/null 2>&1 || fail "cannot detach $LOOP - stopping here"
fi
[ -n "${DEV:-}" ] && lvmdevices --deldev "$DEV" >/dev/null 2>&1

if [ "$BACKEND" = brd ]; then
    rmmod brd >/dev/null 2>&1 ||
        log "note: brd stayed loaded; its pages are freed at power off anyway"
else
    rm -f "$IMG"
    umount "$MNT" >/dev/null 2>&1 || true
    mountpoint -q "$MNT" && fail "$MNT is still mounted"
fi

# --------------------------------------------------- only now, swap policy ---
# Restored after a verified teardown, never before, and only if we changed it.
[ "${SWAP_WAS:-}" = on ] && swapon -a >/dev/null 2>&1

rm -f "$STATE"
log "pool torn down and verified"
