#!/bin/bash
# Proves that ghost will not call the machine safe to power off while anything
# of the session is still holding on: a qube in the RAM pool, the pool itself,
# the volume group, a loop device, a mount, the open store, or swap on a disk.
#
# Run: bash tests/sterile.sh
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
G="$HERE/scripts/ghost"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/stub" "$T/store"
. "$(dirname "$0")/lib-stubs.sh"
make_stubs "$T/stub"
export PATH="$T/stub:$PATH" GHOST_STORE="$T/store"
export GHOST_MAP="$T/no-such-mapper" GHOST_SWAPS="$T/swaps"
ok=0; bad=0
chk(){ if printf '%s' "$3" | grep -qF "$2"; then echo "  ok    $1"; ok=$((ok+1))
  else echo "  FAIL  $1"; echo "        expected: $2"; echo "        got:      $3"; bad=$((bad+1)); fi; }

# a machine where the session has been torn down properly
clean(){
  export GS_MOUNTED="" GS_VGS="" GS_LOOPS="" GS_POOLS="" GS_VOL_POOL=vm-pool GS_VMS_NEW=""
  export GHOST_MAP="$T/no-such-mapper"
  printf 'Filename\t\t\t\tType\t\tSize\tUsed\tPriority\n' > "$T/swaps"; }

echo "1. a properly torn down session"
clean
chk "called sterile" "STERILE-OK" "$($G sterile 2>&1)"

echo "2. a qube still has a volume in the RAM pool"
clean; export GS_VOL_POOL=r1
chk "refused" "STERILE-FAIL" "$($G sterile 2>&1)"
chk "names the volume" "is still in the RAM pool" "$($G sterile 2>&1)"

echo "3. the pool is still registered"
clean; export GS_POOLS=r1
chk "refused" "pool r1 is still registered" "$($G sterile 2>&1)"

echo "4. the volume group in RAM still exists"
clean; export GS_VGS=rvg
chk "refused" "volume group rvg still exists" "$($G sterile 2>&1)"

echo "5. a loop device still backs the file in RAM"
clean; export GS_LOOPS=/mnt/ram/d.img
chk "refused" "loop device still backs a file" "$($G sterile 2>&1)"

echo "6. the tmpfs is still mounted"
clean; export GS_MOUNTED=/mnt/ram
chk "refused" "/mnt/ram is still mounted" "$($G sterile 2>&1)"

echo "7. the store is still mounted"
clean; export GS_MOUNTED="$T/store"
chk "refused" "is still mounted" "$($G sterile 2>&1)"

echo "8. the store's own volume group is still there"
clean; export GS_VGS=vg1
chk "refused" "volume group vg1 is still there" "$($G sterile 2>&1)"

echo "9. the encrypted store is still open"
clean; export GHOST_MAP="$T/swaps"   # any existing path stands in for the mapper node
chk "refused" "the store is still open" "$($G sterile 2>&1)"

echo "10. swap on a disk is active"
clean
printf 'Filename\t\t\t\tType\t\tSize\tUsed\tPriority\n/dev/nvme0n1p3                  partition\t8388604\t0\t-2\n' > "$T/swaps"
chk "refused" "swap on /dev/nvme0n1p3 is active" "$($G sterile 2>&1)"

echo "11. zram swap is noted, not held against it"
clean
printf 'Filename\t\t\t\tType\t\tSize\tUsed\tPriority\n/dev/zram0                      partition\t8388604\t0\t100\n' > "$T/swaps"
chk "still sterile" "STERILE-OK" "$($G sterile 2>&1)"
chk "but says so" "zram swap is active" "$($G sterile 2>&1)"

echo "12. down ends with the same verdict"
clean
chk "clean teardown is declared safe" "DOWN-OK" "$($G down tst 2>&1)"
clean; export GS_POOLS=r1
chk "a teardown that left the pool is not" "DOWN-NOT-CLEAN" "$($G down tst 2>&1)"

echo
echo "passed=$ok failed=$bad"
[ $bad -eq 0 ]
