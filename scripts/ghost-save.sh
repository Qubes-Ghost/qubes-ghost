#!/bin/bash
# ghost-save.sh - save selected RAM-resident qubes back onto the encrypted volume.
#
# FLOW (mirror of ghost-load):
#   attach media -> open the volume INSIDE the vault -> back up chosen qubes to a
#   uniquely-named directory -> verify the archive -> write a sha256 manifest ->
#   mark ".done" only after verification -> dismount + detach.
#
# SAFETY:
#   * unique per-save directory (timestamp + random) so a save never overwrites another;
#   * the archive is verified and hashed; ".done" appears ONLY after that succeeds,
#     so an interrupted save is recognisable as incomplete;
#   * media is detached only after a proven dismount.

set -euo pipefail
set +o history 2>/dev/null || true
exec 9>/run/lock/qubes-ghost.lock
flock -n 9 || { echo "another ghost script is already running"; exit 1; }

VAULT=ghost-vault
VMNT=/mnt/vera                          # volume mount point inside the vault
BACKDIR="$VMNT/qubes"
POOLMNT=/var/lib/qubes/ghost-pool
export TMPDIR="$POOLMNT/tmp"            # keep any staging in RAM
# small helper: run a command as root inside the vault and stream its output
vrun(){ qvm-run --user root --pass-io "$VAULT" "$1"; }

# --- Which qubes to save --------------------------------------------------
read -rp "Qubes to save (space-separated): " -a VMS
[ ${#VMS[@]} -gt 0 ] || { echo "nothing selected"; exit 1; }

# A running qube would be backed up as of its start-time state; offer to stop it.
RUN=$(qvm-ls --running --raw-list 2>/dev/null | grep -xF -f <(printf '%s\n' "${VMS[@]}") || true)
if [ -n "$RUN" ]; then
    echo "RUNNING (backup would capture their start-time state):"; echo "$RUN"
    read -rp "Shut them down now? [y/N] " a; [ "$a" = y ] || exit 1
    for v in $RUN; do qvm-shutdown --wait "$v"; done
fi

DEV=""; MOUNTED=0
safe_detach(){                          # identical guarantee as in ghost-load.sh
    if [ "$MOUNTED" = 1 ]; then
        vrun "sync; veracrypt --text --dismount $VMNT" >/dev/null 2>&1 || true
        for i in 1 2 3 4 5 6; do
            qvm-run --user root --pass-io -q "$VAULT" "! mountpoint -q $VMNT" 2>/dev/null && { MOUNTED=0; break; }; sleep 3
        done
    fi
    [ "$MOUNTED" = 1 ] && { echo "!!! VOLUME DID NOT DISMOUNT - media left attached, do NOT pull it"; return 1; }
    [ -n "$DEV" ] && qvm-block detach "$VAULT" "$DEV" >/dev/null 2>&1 && DEV=""
    return 0
}
trap 'safe_detach || true' EXIT
trap 'echo interrupted; safe_detach || true; exit 130' INT TERM HUP

# --- 1) Attach media ------------------------------------------------------
echo "== 1) media:"; qvm-block list
read -rp "Device (e.g. sys-usb:sdb): " DEV
qvm-start --skip-if-running "$VAULT"
qvm-block attach "$VAULT" "$DEV"

# --- 2) Open the volume inside the vault ----------------------------------
echo "== 2) open the volume in $VAULT ($VMNT):  veracrypt --text --mount /dev/<dev> $VMNT"
for i in $(seq 1 60); do
    qvm-run --user root --pass-io -q "$VAULT" "mountpoint -q $VMNT" 2>/dev/null && { MOUNTED=1; echo ok; break; }
    [ "$i" = 60 ] && exit 1; sleep 5
done

# Point out any leftover incomplete saves (dirs lacking the .done marker).
echo "== leftover incomplete saves (no .done):"
vrun "for d in $BACKDIR/*/; do [ -e \"\$d/.done\" ] || echo \"  incomplete: \$d\"; done" || true

# --- Unique destination directory ----------------------------------------
# timestamp + 3 random bytes; refuse if it somehow already exists.
STAMP="$(date +%Y%m%d-%H%M%S)-$(head -c3 /dev/urandom|od -An -tx1|tr -d ' \n')"
DEST="$BACKDIR/$STAMP"
# mkdir runs as root inside the vault, but qubes' backup writes as the vault's
# user - so chown the new dir to the user, or the write fails with EACCES.
vrun "[ ! -e $DEST ] && mkdir $DEST && chown user:user $DEST" || { echo "destination busy?!"; exit 1; }

# --- 3) Back up -----------------------------------------------------------
echo "== 3) backup:"
qvm-backup -d "$VAULT" --compress "$DEST" "${VMS[@]}"    # asks for a passphrase (twice)

# --- 4) Verify + write manifest ------------------------------------------
echo "== 4) verify + manifest:"
ARC=$(vrun "ls -A $DEST" | grep -v '^\.' | head -1)      # the archive filename
[ -n "$ARC" ] || { echo "archive not found"; exit 1; }
qvm-backup-restore --verify-only -d "$VAULT" "$DEST/$ARC"   # cryptographically verify it
# record size + sha256 so integrity can be re-checked later, then fsync.
vrun "cd $DEST && sha256sum '$ARC' > manifest.sha256 && stat -c '%s %n' '$ARC' >> manifest.sha256 && sync"
vrun "touch $DEST/.done && sync"                          # mark complete ONLY now
echo "verified: $ARC (+manifest)"

# --- 4b) Prune older saves ------------------------------------------------
# Unique per-save directories stop a bad save overwriting a good one, but left
# alone they pile up, and every one of them opens with the same passphrase. That
# is a rollback buffet: a stack of restorable earlier states, each of which would
# pin a forward-only ratchet at its own point in time (see ghost-load.sh). Keep a
# small window instead. Pruning happens ONLY after the new save is verified and
# marked .done, so nothing is destroyed until the replacement is proven good.
KEEP="${GHOST_KEEP_SAVES:-2}"
case "$KEEP" in ''|*[!0-9]*) echo "GHOST_KEEP_SAVES must be a number"; exit 1 ;; esac
[ "$KEEP" -ge 1 ] || { echo "GHOST_KEEP_SAVES must be at least 1"; exit 1; }
echo "== 4b) pruning old saves (keeping newest $KEEP):"
OLD=$(vrun "for d in $BACKDIR/*/; do [ -e \"\$d/.done\" ] && basename \"\$d\"; done | sort | head -n -$KEEP" 2>/dev/null || true)
if [ -n "${OLD// /}" ]; then
    for d in $OLD; do
        # Overwrite the archive before unlinking: the volume is encrypted, but a
        # removed file can still sit in free space inside it until reused.
        if vrun "cd $BACKDIR/$d 2>/dev/null && { command -v shred >/dev/null && shred -n1 -u ./* 2>/dev/null || rm -f ./*; } ; cd / && rm -rf $BACKDIR/$d && sync"; then
            echo "  removed: $d"
        else
            echo "  !! could not remove: $d"
        fi
    done
else
    echo "  nothing to prune"
fi

# --- 5) Close up ----------------------------------------------------------
echo "== 5) dismount + detach + shut vault:"
safe_detach || exit 1
qvm-shutdown --wait "$VAULT" || true
trap - EXIT INT TERM HUP
echo "SAVED ($STAMP). Only after this success should you sync it to a twin volume."
