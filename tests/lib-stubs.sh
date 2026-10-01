# Shared stubs for the tests: they stand in for the Qubes and LVM commands, so
# the refusals in scripts/ghost can be exercised on an ordinary machine. Each
# stub reads environment variables at call time, which is how a test bends one
# part of the picture and leaves the rest healthy.
#
#   GS_POOL_DRIVER GS_POOL_VG GS_POOL_TP   what `qvm-pool info r1` reports
#   GS_PVS                                 lines of `pvs -o pv_name,vg_name`
#   GS_LOOP_BACK                           backing file of the loop device, empty = not a loop
#   GS_FS GS_MNT_OPTS                      filesystem and options under that file
#   GS_VMS_BEFORE GS_VMS_NEW               qubes before, and the ones a restore adds
#   GS_KLASS                               class reported for the new qubes
#   GS_VOL_POOL                            pool reported for every volume
#   GS_LEAK                                "vm:volume" reported in GS_LEAK_POOL instead
#   FAIL_BACKUP                            a backup that dies halfway
#   GS_QROOT                               directory standing in for the qube's /
#   GS_RUNNING                             whether qvm-check calls the qube running
#   GS_MOUNTED                             paths mountpoint calls mounted, unset = all
#   GS_VGS                                 volume groups vgs finds
#   GS_LOOPS                               backing files losetup lists
#   GS_POOLS                               what `qvm-pool list` prints
#   GS_VMS                                 what `qvm-ls --raw-list` prints when asked flat
make_stubs(){
  local d="$1"; mkdir -p "$d"
  : "${GS_POOL_DRIVER:=lvm_thin}" "${GS_POOL_VG:=rvg}" "${GS_POOL_TP:=rpool}"
  : "${GS_PVS:=  /dev/loop7 rvg}" "${GS_LOOP_BACK:=/mnt/ram/d.img}"
  : "${GS_FS:=tmpfs}" "${GS_MNT_OPTS:=rw,noswap,size=40G}"
  : "${GS_VMS_BEFORE:=dom0}" "${GS_VMS_NEW:=tst}" "${GS_KLASS:=StandaloneVM}"
  : "${GS_VOL_POOL:=r1}" "${GS_LEAK:=}" "${GS_LEAK_POOL:=vm-pool}"
  export GS_POOL_DRIVER GS_POOL_VG GS_POOL_TP GS_PVS GS_LOOP_BACK GS_FS \
         GS_MNT_OPTS GS_VMS_BEFORE GS_VMS_NEW GS_KLASS GS_VOL_POOL GS_LEAK GS_LEAK_POOL
  export GS_FLAG="$d/../restored"

  for c in cryptsetup vgchange qvm-shutdown; do printf '#!/bin/sh\nexit 0\n' > "$d/$c"; done
  : "${GS_VGS:=rvg vg1}" "${GS_LOOPS:=/mnt/ram/d.img}" "${GS_POOLS:=r1}"
  export GS_VGS GS_LOOPS GS_POOLS
  cat > "$d/mountpoint" <<'E'
#!/bin/sh
# unset GS_MOUNTED means "everything is a mountpoint", which is what the
# tests about loading and saving want
[ -z "${GS_MOUNTED+x}" ] && exit 0
for m in $GS_MOUNTED; do [ "$m" = "$2" ] && exit 0; done
exit 1
E
  cat > "$d/vgs" <<'E'
#!/bin/sh
for v in $GS_VGS; do [ "$v" = "$1" ] && exit 0; done
exit 1
E
  cat > "$d/qubes-prefs" <<'E'
#!/bin/sh
[ "$1" = default_pool ] && [ $# -eq 1 ] && echo vm-pool
exit 0
E
  cat > "$d/qvm-pool" <<'E'
#!/bin/sh
case "$1" in
  list) for p in $GS_POOLS; do echo "$p"; done ;;
  info) printf 'name %s\ndriver %s\nvolume_group %s\nthin_pool %s\n' \
          "$2" "$GS_POOL_DRIVER" "$GS_POOL_VG" "$GS_POOL_TP" ;;
esac
exit 0
E
  cat > "$d/pvs" <<'E'
#!/bin/sh
printf '%s\n' "$GS_PVS"
E
  cat > "$d/losetup" <<'E'
#!/bin/sh
# "-l -O BACK-FILE" lists what is still attached, "-n -O BACK-FILE <dev>"
# asks about one device
case " $* " in
  *" -l "*) echo "BACK-FILE"; for f in $GS_LOOPS; do echo "$f"; done ;;
  *" -n "*) [ -n "$GS_LOOP_BACK" ] && echo "$GS_LOOP_BACK" ;;
esac
exit 0
E
  cat > "$d/findmnt" <<'E'
#!/bin/sh
for a in "$@"; do case "$a" in FSTYPE) w=fs ;; OPTIONS) w=opts ;; esac; done
[ "$w" = fs ] && echo "$GS_FS"
[ "$w" = opts ] && echo "$GS_MNT_OPTS"
exit 0
E
  cat > "$d/qvm-ls" <<'E'
#!/bin/sh
for v in $GS_VMS_BEFORE; do echo "$v"; done
[ -f "$GS_FLAG" ] && for v in $GS_VMS_NEW; do echo "$v"; done
exit 0
E
  cat > "$d/qvm-prefs" <<'E'
#!/bin/sh
[ "$2" = klass ] && echo "$GS_KLASS"
exit 0
E
  cat > "$d/qvm-volume" <<'E'
#!/bin/sh
if [ "$2" = "$GS_LEAK" ]; then echo "pool $GS_LEAK_POOL"; else echo "pool $GS_VOL_POOL"; fi
exit 0
E
  cat > "$d/qvm-remove" <<'E'
#!/bin/sh
shift; echo "$@" >> "$GS_FLAG.removed"
exit 0
E
  : "${GS_QROOT:=$d/../qube}" "${GS_RUNNING:=1}"
  mkdir -p "$GS_QROOT"; export GS_QROOT GS_RUNNING
  cat > "$d/qvm-check" <<'E'
#!/bin/sh
[ "$GS_RUNNING" = 1 ]
E
  # Stands in for the qube's filesystem: the command is run here, with the
  # tar target swapped from the real root to the directory that plays one.
  cat > "$d/qvm-run" <<'E'
#!/bin/sh
for a in "$@"; do cmd="$a"; done
echo "$cmd" >> "$GS_QROOT/../qvm-run.log"
# The qube's root becomes the stand-in directory, at the end of the command as
# well as in the middle. If a "/" target survives the rewrite, refuse outright:
# a stub must never be able to write to the root of the machine running the
# test. It could, once, and it wrote a test fixture into the real /home.
cmd=$(printf '%s' "$cmd" | sed "s#-C / #-C $GS_QROOT #g; s#-C /\$#-C $GS_QROOT#")
case "$cmd" in *"-C /") bad=1 ;; *"-C / "*) bad=1 ;; *) bad=0 ;; esac
[ "$bad" = 1 ] && { echo "stub refuses to run against the real root: $cmd" >&2; exit 1; }
# A command meant for the inside of a qube must never reach the host's process
# table or services. The log above is enough for the test to assert on; running
# it is not. It did once: the `stop:` line of a messenger list was pkill, and on
# the host it killed the real daemon of the same name and took a live channel
# down for a quarter of an hour.
case "$cmd" in
  pkill*|*" pkill "*|kill\ *|killall*|systemctl*|reboot*|shutdown*|poweroff*)
    exit 0 ;;
esac
exec /bin/sh -c "$cmd"
E
  cat > "$d/qvm-backup" <<'E'
#!/bin/sh
if [ -n "$FAIL_BACKUP" ]; then
  head -c 1000 /dev/urandom > "$GHOST_STORE/qubes-backup-PARTIAL-$$"; exit 1
fi
sleep 1   # so two archives in one run get different timestamps
head -c 200000 /dev/urandom > "$GHOST_STORE/qubes-backup-$(date -u +%Y-%m-%dT%H%M%S)"
exit 0
E
  cat > "$d/qvm-backup-restore" <<'E'
#!/bin/sh
touch "$GS_FLAG"
exit 0
E
  chmod +x "$d"/*
}
