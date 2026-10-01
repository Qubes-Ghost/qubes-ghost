#!/bin/bash
# Proves that scripts/ghost refuses to restore unless the pool it restores into
# really is backed by RAM, and that it tears the restore down if a volume lands
# anywhere else. Runs on an ordinary machine: the Qubes and LVM commands are
# stubs, and each case bends one link of the chain while the rest stays healthy.
#
# Run: bash tests/ram-placement.sh
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
G="$HERE/scripts/ghost"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/stub" "$T/store"
. "$(dirname "$0")/lib-stubs.sh"
make_stubs "$T/stub"
export PATH="$T/stub:$PATH" GHOST_STORE="$T/store" FAIL_BACKUP=
ok=0; bad=0
chk(){ if printf '%s' "$3" | grep -qF "$2"; then echo "  ok    $1"; ok=$((ok+1))
  else echo "  FAIL  $1"; echo "        expected: $2"; echo "        got:      $3"; bad=$((bad+1)); fi; }
L(){ rm -f "$GS_FLAG"; $G load tst 2>&1; }   # each load starts from a clean slate
no(){ if printf '%s' "$3" | grep -qF "$2"; then echo "  FAIL  $1 (saw '$2')"; bad=$((bad+1))
  else echo "  ok    $1"; ok=$((ok+1)); fi; }
reset(){ rm -f "$GS_FLAG" "$GS_FLAG.removed"
  GS_POOL_DRIVER=lvm_thin GS_POOL_VG=rvg GS_POOL_TP=rpool
  GS_PVS="  /dev/loop7 rvg" GS_LOOP_BACK=/mnt/ram/d.img
  GS_FS=tmpfs GS_MNT_OPTS=rw,noswap,size=40G
  GS_KLASS=StandaloneVM GS_VOL_POOL=r1 GS_LEAK=
  export GS_POOL_DRIVER GS_POOL_VG GS_POOL_TP GS_PVS GS_LOOP_BACK GS_FS GS_MNT_OPTS GS_KLASS GS_VOL_POOL GS_LEAK; }

# one sealed archive to load, made once
reset; $G save phrase tst >/dev/null 2>&1

echo "1. everything healthy"
reset
chk "ram says it is RAM" "RAM-OK" "$($G ram 2>&1)"
chk "load goes through" "LOAD-OK" "$(L)"
chk "and counts what it put in RAM" "in-ram=1" "$(L)"

echo "2. the pool is not a thin LVM pool at all"
reset; export GS_POOL_DRIVER=file-reflink
chk "refused" "LOAD-REFUSE-NOTRAM" "$(L)"
chk "and says what it found" "driver 'file-reflink'" "$(L)"
no "nothing was restored" "restored" "$(ls "$T" 2>/dev/null)"

echo "3. a pool named r1 that points at another volume group"
reset; export GS_POOL_VG=qubes_dom0
chk "refused" "LOAD-REFUSE-NOTRAM" "$(L)"
chk "names the group" "volume group 'qubes_dom0'" "$(L)"

echo "4. the group has a second physical volume, one of them on disk"
reset; export GS_PVS="  /dev/loop7 rvg
  /dev/sda3 rvg"
chk "refused" "LOAD-REFUSE-NOTRAM" "$(L)"
chk "counts them" "has 2 physical volumes" "$(L)"

echo "5. the physical volume is not a loop device"
reset; export GS_LOOP_BACK=
chk "refused" "LOAD-REFUSE-NOTRAM" "$(L)"
chk "says why" "not a loop device" "$(L)"

echo "6. the loop file lives on disk, not on tmpfs"
reset; export GS_FS=ext4
chk "refused" "LOAD-REFUSE-NOTRAM" "$(L)"
chk "calls it what it is" "that is disk" "$(L)"

echo "7. tmpfs without noswap: warn, but do not block"
reset; export GS_MNT_OPTS=rw,size=40G
chk "warns about swap" "without noswap" "$($G ram 2>&1)"
chk "still loads" "LOAD-OK" "$(L)"

echo "8. a restored volume lands outside the RAM pool"
reset; export GS_LEAK=tst:private GS_LEAK_POOL=vm-pool
chk "the restore is not accepted" "LOAD-FAIL-NOTINRAM" "$(L)"
chk "names the volume" "LEAK: tst:private is in pool 'vm-pool'" "$(L)"
chk "and the qube is removed again" "tst" "$(cat "$GS_FLAG.removed" 2>/dev/null)"

echo "9. an AppVM's root is allowed to be in its template's pool"
reset; export GS_KLASS=AppVM GS_LEAK=tst:root GS_LEAK_POOL=vm-pool
chk "not treated as a leak" "LOAD-OK" "$(L)"

echo "10. the same volume on a standalone IS a leak"
reset; export GS_KLASS=StandaloneVM GS_LEAK=tst:root GS_LEAK_POOL=vm-pool
chk "refused" "LOAD-FAIL-NOTINRAM" "$(L)"

echo
echo "passed=$ok failed=$bad"
[ $bad -eq 0 ]
