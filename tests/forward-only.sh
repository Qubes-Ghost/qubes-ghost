#!/bin/bash
# Proves the forward-only rule in scripts/ghost without Qubes and without a
# hidden volume: the Qubes commands are replaced by stubs, and the store is a
# temporary directory. What is actually exercised is the sealing, the refusals
# and the pruning.
#
# Run: bash tests/forward-only.sh
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
G="$HERE/scripts/ghost"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/stub" "$T/store"

cat > "$T/stub/cryptsetup" <<'E'
#!/bin/sh
exit 0
E
cat > "$T/stub/vgchange" <<'E'
#!/bin/sh
exit 0
E
cat > "$T/stub/mountpoint" <<'E'
#!/bin/sh
exit 0
E
cat > "$T/stub/qvm-shutdown" <<'E'
#!/bin/sh
exit 0
E
cat > "$T/stub/qubes-prefs" <<'E'
#!/bin/sh
[ "$1" = default_pool ] && [ $# -eq 1 ] && echo vm-pool
exit 0
E
cat > "$T/stub/qvm-backup" <<'E'
#!/bin/sh
# With FAIL_BACKUP set, leave a partial file behind and fail, the way an
# interrupted backup would.
if [ -n "$FAIL_BACKUP" ]; then
  head -c 1000 /dev/urandom > "$GHOST_STORE/qubes-backup-PARTIAL-$$"; exit 1
fi
sleep 1   # so two archives in one run get different timestamps
head -c 200000 /dev/urandom > "$GHOST_STORE/qubes-backup-$(date -u +%Y-%m-%dT%H%M%S)"
exit 0
E
cat > "$T/stub/qvm-backup-restore" <<'E'
#!/bin/sh
exit 0
E
chmod +x "$T/stub"/*

export PATH="$T/stub:$PATH"
export GHOST_STORE="$T/store"
export FAIL_BACKUP=
ok=0; bad=0
chk(){ # chk <what> <expected substring> <output>
  if printf '%s' "$3" | grep -qF "$2"; then echo "  ok    $1"; ok=$((ok+1))
  else echo "  FAIL  $1"; echo "        expected: $2"; echo "        got:      $3"; bad=$((bad+1)); fi; }

echo "1. empty store, nothing to load"
chk "load refuses, no seal" "LOAD-REFUSE" "$($G load tst 2>&1)"

echo "2. first save"
chk "sealed as generation 1" "SAVE-OK generation=1" "$($G save phrase tst 2>&1)"

echo "3. load the sealed one"
chk "loads" "LOAD-OK" "$($G load tst 2>&1)"

echo "4. second save prunes the older archive"
chk "generation 2" "generation=2 archive=qubes-backup-" "$($G save phrase tst 2>&1)"
chk "one archive left in the store" "1" "$(ls -1 "$T"/store/qubes-backup-* | wc -l)"

echo "5. an older archive is put back and asked for by name"
A=$(sed -n 's/^arc=//p' "$T/store/ghost.state")
cp "$T/store/$A" "$T/store/qubes-backup-2020-01-01T000000"
chk "refused, not the sealed one" "LOAD-REFUSE-NOTNEWEST" "$($G load qubes-backup-2020-01-01T000000 tst 2>&1)"
chk "refused by full path too" "LOAD-REFUSE-NOTNEWEST" "$($G load "$T/store/qubes-backup-2020-01-01T000000" tst 2>&1)"
chk "the sealed one by name is allowed" "LOAD-OK" "$($G load "$A" tst 2>&1)"
rm -f "$T/store/qubes-backup-2020-01-01T000000"

echo "6. the sealed archive is modified"
printf 'tamper' >> "$T/store/$A"
chk "refused" "LOAD-REFUSE" "$($G load tst 2>&1)"
chk "and says why" "does not match the seal" "$($G load tst 2>&1)"

echo "7. the sealed archive is gone"
mv "$T/store/$A" "$T/$A.bak"
chk "refused, archive missing" "is gone from the store" "$($G load tst 2>&1)"
mv "$T/$A.bak" "$T/store/$A"

echo "8. the store is rolled back behind a generation already loaded"
sed -i 's/^seen=.*/seen=99/' "$T/store/ghost.state"
chk "refused, rollback detected" "the store was wound back" "$($G load tst 2>&1)"

echo "9. a save interrupted halfway leaves the previous seal usable"
rm -rf "$T/store"; mkdir -p "$T/store"
$G save phrase tst >/dev/null 2>&1
B4=$(cat "$T/store/ghost.state")
chk "save fails loudly" "SAVE-FAIL" "$(FAIL_BACKUP=1 $G save phrase tst 2>&1)"
if [ "$B4" = "$(cat "$T/store/ghost.state")" ]; then echo "  ok    seal untouched"; ok=$((ok+1))
else echo "  FAIL  seal was changed"; bad=$((bad+1)); fi
chk "the previous archive still loads" "LOAD-OK" "$($G load tst 2>&1)"
chk "next good save clears both the old archive and the partial" "pruned=2" "$($G save phrase tst 2>&1)"
chk "no partial left" "0" "$(ls "$T/store" | grep -c PARTIAL)"

echo "10. seal, the migration hatch for a store written before sealing existed"
rm -rf "$T/store"; mkdir -p "$T/store"
head -c 1000 /dev/urandom > "$T/store/qubes-backup-2026-01-01T000000"
chk "unsealed archive is not loadable" "LOAD-REFUSE" "$($G load tst 2>&1)"
chk "seal needs the name spelled out" "the archive name is required" "$($G seal 2>&1)"
chk "seal refuses a name that is not there" "SEAL-FAIL" "$($G seal qubes-backup-nope 2>&1)"
chk "seals it as a new generation" "SEAL-OK generation=1" "$($G seal qubes-backup-2026-01-01T000000 2>&1)"
chk "and now it loads" "LOAD-OK" "$($G load tst 2>&1)"

echo
echo "passed=$ok failed=$bad"
[ $bad -eq 0 ]
