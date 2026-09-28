#!/bin/bash
# ghost-load.sh — restore selected qubes from the encrypted volume INTO the RAM pool.
#
# FLOW:
#   attach media -> you open the encrypted volume INSIDE the offline vault ->
#   restore chosen qubes into pool "ghost" -> verify every volume really landed
#   in RAM -> dismount + detach the media. Then you physically remove it and work.
#
# INVARIANTS ENFORCED:
#   * the vault is a networkless DisposableVM (no path off the machine);
#   * the passphrase is entered only inside the vault, never in dom0;
#   * media is detached only after a PROVEN dismount, even on the error path;
#   * if any restored volume did not land in RAM, everything is removed (fail-closed).

set -euo pipefail
set +o history 2>/dev/null || true
exec 9>/run/lock/qubes-ghost.lock
flock -n 9 || { echo "another ghost script is already running"; exit 1; }

VAULT=ghost-vault                       # the networkless DisposableVM
VMNT=/mnt/vera                          # mount point of the volume INSIDE the vault
BACKDIR="$VMNT/qubes"                   # where backups live on the volume
POOLMNT=/var/lib/qubes/ghost-pool       # the RAM pool's tmpfs mount in dom0
export TMPDIR="$POOLMNT/tmp"            # force restore staging into RAM, not disk
mkdir -p "$TMPDIR" 2>/dev/null || true

# Guard: the pool must exist and truly be tmpfs, else data would hit the disk.
mountpoint -q "$POOLMNT" || { echo "RAM pool not mounted — run ghost-ram-pool.sh"; exit 1; }
[ "$(findmnt -n -o FSTYPE "$POOLMNT")" = tmpfs ] || { echo "pool backing is not tmpfs — stop"; exit 1; }

# Helper: print which pool a given qube:volume lives in.
# NOTE: `qvm-volume info` uses SPACE-separated "key   value" lines, so we match
# the field, not a colon. (A colon-based parser silently returns nothing.)
vol_pool(){ qvm-volume info "$1:$2" 2>/dev/null | awk '$1=="pool"{print $2}'; }

# --- Enforce the vault is safe BEFORE attaching any media -----------------
[ "$(qvm-prefs "$VAULT" netvm 2>/dev/null)" = "" ] || { echo "ERROR: $VAULT has a netvm — air-gap broken"; exit 1; }
[ "$(qvm-prefs "$VAULT" klass 2>/dev/null)" = DispVM ] || { echo "ERROR: $VAULT is not a DispVM"; exit 1; }

DEV=""; MOUNTED=0
# safe_detach: only ever detaches media once the volume is proven unmounted.
safe_detach(){
    if [ "$MOUNTED" = 1 ]; then
        qvm-run --user root --pass-io "$VAULT" "sync; veracrypt --text --dismount $VMNT" >/dev/null 2>&1 || true
        # poll up to ~10s for the mountpoint to actually be gone
        for i in 1 2 3 4 5; do
            qvm-run --user root --pass-io -q "$VAULT" "! mountpoint -q $VMNT" 2>/dev/null && { MOUNTED=0; break; }
            sleep 2
        done
    fi
    if [ "$MOUNTED" = 1 ]; then
        echo "!!! VOLUME DID NOT DISMOUNT — media left attached, resolve by hand"; return 1
    fi
    [ -n "$DEV" ] && qvm-block detach "$VAULT" "$DEV" >/dev/null 2>&1 && DEV=""
    return 0
}
# Ensure detach happens on normal exit AND on interrupt/kill.
trap 'safe_detach || true' EXIT
trap 'echo interrupted; safe_detach || true; exit 130' INT TERM HUP

# --- 1) Attach the media to the vault ------------------------------------
echo "== 1) block devices:"; qvm-block list
read -rp "Device (e.g. sys-usb:sdb): " DEV
qvm-start --skip-if-running "$VAULT"
qvm-block attach "$VAULT" "$DEV"

# --- 2) You open the encrypted volume INSIDE the vault -------------------
echo "== 2) block devices seen inside $VAULT:"
qvm-run --user root --pass-io "$VAULT" "lsblk -o NAME,SIZE,TYPE | grep -v loop" || true
echo "   In a $VAULT terminal:  veracrypt --text --mount /dev/<dev> $VMNT   (enter passphrase HERE)"
# Wait up to 5 minutes for the mount to appear; the passphrase never reaches dom0.
for i in $(seq 1 60); do
    qvm-run --user root --pass-io -q "$VAULT" "mountpoint -q $VMNT" 2>/dev/null && { MOUNTED=1; echo mounted; break; }
    [ "$i" = 60 ] && { echo "volume was not mounted in time"; exit 1; }
    sleep 5
done

# --- 3) Choose which backup to restore ----------------------------------
echo "== 3) backups on the volume:"; qvm-run --user root --pass-io "$VAULT" "ls -la $BACKDIR" || { echo "no $BACKDIR"; exit 1; }
read -rp "Directory/archive to restore: " ARC

# --- 4) Restore INTO the RAM pool ---------------------------------------
# Qubes 4.x `qvm-backup-restore` has no --pool flag, so we temporarily point
# ALL default pools at "ghost", restore, then restore the previous settings.
echo "== 4) restore: redirecting default pools to 'ghost' for the restore"
declare -A OLDP
for prop in default_pool default_pool_root default_pool_private default_pool_volatile; do
    OLDP[$prop]=$(qubes-prefs "$prop" 2>/dev/null || echo __unset__)   # remember current
    qubes-prefs "$prop" ghost 2>/dev/null || true                     # point at RAM pool
done
restore_pools(){ for prop in "${!OLDP[@]}"; do
    [ "${OLDP[$prop]}" = __unset__ ] && qubes-prefs --default "$prop" 2>/dev/null || qubes-prefs "$prop" "${OLDP[$prop]}" 2>/dev/null || true
done; }
trap 'restore_pools; safe_detach || true' EXIT   # also restore pools on exit

BEFORE=$(qvm-ls --raw-list | sort)               # snapshot of existing qubes
qvm-backup-restore -d "$VAULT" "$BACKDIR/$ARC"   # asks for the backup passphrase, then confirm
restore_pools                                    # put default pools back immediately
trap 'safe_detach || true' EXIT

# --- 5) Verify EVERY restored volume actually landed in RAM -------------
echo "== 5) verifying placement of each restored volume:"
NEWVMS=$(comm -13 <(echo "$BEFORE") <(qvm-ls --raw-list | sort))   # qubes that appeared
BAD=0
for vm in $NEWVMS; do
    # Check only 'private' and 'volatile': an AppVM's 'root' legitimately points
    # at its TEMPLATE's pool (that's shared, not this qube's secret data).
    for v in private volatile; do
        p=$(vol_pool "$vm" "$v" || true); [ -z "$p" ] && continue
        if [ "$p" != ghost ]; then echo "LEAK: $vm:$v is in pool '$p'"; BAD=1; fi
    done
done
if [ "$BAD" = 1 ]; then
    echo "!!! Some volumes are NOT in RAM — removing the restored qubes and stopping"
    for vm in $NEWVMS; do qvm-remove -f "$vm" 2>/dev/null || true; done
    exit 1
fi
echo "all restored qubes are in RAM: $NEWVMS"

# --- 6) Close up: dismount, detach, power the vault down -----------------
echo "== 6) dismount + detach + shut vault:"
safe_detach || exit 1
qvm-shutdown --wait "$VAULT" || true
trap - EXIT INT TERM HUP
echo "DONE: qubes are in RAM. Remove the media now (air-gap). Before power-off, run ghost-teardown.sh"
