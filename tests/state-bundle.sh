#!/bin/bash
# Proves the state-save / state-load pair: only what the list names leaves the
# qube, the bundle is sealed and read back before it counts, and the same
# forward-only rule applies to it as to a whole-qube archive. A directory
# stands in for the qube's filesystem.
#
# Run: bash tests/state-bundle.sh
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
G="$HERE/scripts/ghost"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/stub" "$T/store"
. "$(dirname "$0")/lib-stubs.sh"
make_stubs "$T/stub"
export PATH="$T/stub:$PATH" GHOST_STORE="$T/store" FAIL_BACKUP=
Q=chat
ok=0; bad=0
chk(){ if printf '%s' "$3" | grep -qF "$2"; then echo "  ok    $1"; ok=$((ok+1))
  else echo "  FAIL  $1"; echo "        expected: $2"; echo "        got:      $3"; bad=$((bad+1)); fi; }
no(){ if printf '%s' "$3" | grep -qF "$2"; then echo "  FAIL  $1 (saw '$2')"; bad=$((bad+1))
  else echo "  ok    $1"; ok=$((ok+1)); fi; }

# a qube with a messenger's state in it, and a big worthless file beside it
mkdir -p "$GS_QROOT/home/user/.simplex" "$GS_QROOT/home/user/Downloads"
echo "identity-key-v1" > "$GS_QROOT/home/user/.simplex/keys"
echo "messages-v1"     > "$GS_QROOT/home/user/.simplex/chat.db"
head -c 300000 /dev/urandom > "$GS_QROOT/home/user/Downloads/film.mkv"

echo "1. no list, so nothing is guessed"
chk "refused" "nothing says what is worth keeping" "$($G state-save phrase $Q 2>&1)"

cat > "$T/store/state-$Q.list" <<'L'
# what is worth keeping out of this qube
stop: pkill -x ghost-fixture-app
/home/user/.simplex
L

echo "2. the qube is not running"
GS_RUNNING=0 chk "refused" "is not running" "$(GS_RUNNING=0 $G state-save phrase $Q 2>&1)"

echo "3. saving keeps only what the list names"
OUT=$($G state-save phrase $Q 2>&1)
chk "sealed as generation 1" "STATE-SAVE-OK generation=1" "$OUT"
chk "the app was closed first" "pkill -x ghost-fixture-app" "$(head -1 "$GS_QROOT/../qvm-run.log")"
chk "and the tar came after it" "tar czf" "$(sed -n 2p "$GS_QROOT/../qvm-run.log")"
B=$(sed -n 's/^arc=//p' "$T/store/state-$Q.seal")
chk "the messenger's keys are in the bundle" "home/user/.simplex/keys" "$(tar tzf "$T/store/$B")"
no "the unrelated file is not" "film.mkv" "$(tar tzf "$T/store/$B")"
chk "the bundle is small" "ok" "$([ "$(stat -c%s "$T/store/$B")" -lt 10000 ] && echo ok)"

echo "4. the state comes back into a fresh qube"
rm -rf "$GS_QROOT/home/user/.simplex"
chk "loaded" "STATE-LOAD-OK" "$($G state-load $Q 2>&1)"
chk "the keys are back" "identity-key-v1" "$(cat "$GS_QROOT/home/user/.simplex/keys" 2>/dev/null)"

echo "5. a second save supersedes the first"
echo "messages-v2" > "$GS_QROOT/home/user/.simplex/chat.db"
chk "generation 2, the older bundle pruned" "generation=2" "$($G state-save phrase $Q 2>&1)"
chk "one bundle left" "1" "$(ls -1 "$T"/store/state-$Q-* | wc -l)"
rm -rf "$GS_QROOT/home/user/.simplex"
$G state-load $Q >/dev/null 2>&1
chk "and it is the newer one" "messages-v2" "$(cat "$GS_QROOT/home/user/.simplex/chat.db" 2>/dev/null)"

echo "6. forward-only applies to bundles too"
B=$(sed -n 's/^arc=//p' "$T/store/state-$Q.seal")
printf 'tamper' >> "$T/store/$B"
chk "a modified bundle is refused" "STATE-LOAD-REFUSE" "$($G state-load $Q 2>&1)"
chk "and says why" "does not match the seal" "$($G state-load $Q 2>&1)"
sed -i 's/^seen=.*/seen=99/' "$T/store/state-$Q.seal"
chk "a wound-back seal is refused" "the store was wound back" "$($G state-load $Q 2>&1)"

echo "7. state shows up alongside the archives"
chk "listed" "state of $Q" "$($G state 2>&1)"

echo
echo "passed=$ok failed=$bad"
[ $bad -eq 0 ]
