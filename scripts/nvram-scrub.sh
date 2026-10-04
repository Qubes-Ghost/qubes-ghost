#!/bin/bash
# nvram-scrub - remove the boot entry an installer writes into the host firmware
#
# When you install Qubes (or any distro) onto a USB drive, the installer adds an
# NVRAM boot entry on the MACHINE you installed from, pointing at the drive's GPT
# partition. That entry stays in the host's firmware after you unplug the drive.
# On someone else's computer that is a trace you did not mean to leave; on your
# own it is clutter that also breaks if the drive is ever repartitioned.
#
# You do not need the entry. Qubes already installs a removable fallback at
# \EFI\BOOT\BOOTX64.EFI on the drive's ESP, so the firmware boot menu (F12 and
# the like) boots the drive as a removable device without any NVRAM entry. This
# script checks that fallback is really there, then deletes the entry.
#
# Run it from the installer's shell (TTY2 in Anaconda, Ctrl+Alt+F2) before you
# reboot, while the target is still mounted under /mnt/sysimage. It can also run
# from any live system with the ESP mounted; point ESP= at it.
#
#   list                 show boot entries, mark the ones that match
#   scrub [--yes]        delete the matching entries (asks first without --yes)
#   install-hook         install a service in the booted system that scrubs the
#                        entry at every shutdown, so no host keeps a trace after
#                        you have used the drive there
#
# One scrub at install time is not enough on its own. The removable fallback
# does not create an entry, but some firmwares silently re-add one every time
# they boot a USB device. install-hook handles that: it runs the scrub on each
# poweroff, so whatever a host wrote during the session is gone before the drive
# leaves. It needs efibootmgr present in the booted system (on Qubes dom0:
# sudo qubes-dom0-update efibootmgr).
#
# LABEL is what to match, default "Qubes OS". ESP is where to confirm the
# fallback, default the installer's mount. Nothing else is ever touched - the
# match is on the exact label, so every other boot entry stays as it was.
set -u

LABEL=${LABEL:-Qubes OS}
ESP=${ESP:-/mnt/sysimage/boot/efi}
FALLBACK="$ESP/EFI/BOOT/BOOTX64.EFI"

have() { command -v "$1" >/dev/null 2>&1; }
have efibootmgr || { echo "efibootmgr not found - run this from the installer shell or a live system that has it"; exit 1; }
[ -d /sys/firmware/efi ] || { echo "not booted in UEFI mode - there is no NVRAM to clean"; exit 1; }

# the Boot#### ids whose name is exactly LABEL
ids() { efibootmgr | sed -n "s/^Boot\([0-9A-Fa-f]\{4\}\)\*\? *${LABEL}\$/\1/p"; }

case "${1:-list}" in
  list)
    echo "entries matching \"$LABEL\":"
    m=$(ids)
    if [ -z "$m" ]; then
      echo "  (none)"
    else
      for i in $m; do echo "  Boot$i"; done
    fi
    ;;
  scrub)
    m=$(ids)
    [ -z "$m" ] && { echo "nothing matches \"$LABEL\" - already clean"; exit 0; }
    # safety: never remove the entry unless the drive can still boot without it
    if [ ! -f "$FALLBACK" ]; then
      echo "refusing: removable fallback $FALLBACK is missing."
      echo "without it the drive would not boot after the entry is gone."
      echo "set ESP= to the drive's ESP, or copy \EFI\\qubes\\grubx64.efi there first."
      exit 1
    fi
    echo "will delete:"; for i in $m; do echo "  Boot$i ($LABEL)"; done
    if [ "${2:-}" != "--yes" ]; then
      printf "proceed? [y/N] "; read -r a; [ "$a" = y ] || { echo "aborted"; exit 1; }
    fi
    for i in $m; do efibootmgr -b "$i" -B >/dev/null && echo "deleted Boot$i"; done
    sync
    echo "--- now:"; efibootmgr
    ;;
  install-hook)
    # put the script and a shutdown service into the booted system.
    # ExecStop runs on poweroff, so the entry is removed at the end of every
    # session, on whatever host wrote it. ESP on a running system is /boot/efi.
    self=$(readlink -f "$0")
    dst=/usr/local/sbin/nvram-scrub
    install -m 0755 "$self" "$dst" || { echo "cannot write $dst (need root)"; exit 1; }
    cat > /etc/systemd/system/nvram-scrub.service <<UNIT
[Unit]
Description=Remove the installer boot entry at shutdown (leave no trace on the host)
DefaultDependencies=no
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=LABEL=${LABEL}
Environment=ESP=/boot/efi
ExecStop=$dst scrub --yes

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload && systemctl enable nvram-scrub.service
    echo "installed. the entry will be scrubbed on every shutdown."
    echo "note: this needs efibootmgr in the booted system."
    ;;
  *)
    echo "usage: LABEL='Qubes OS' ESP=/mnt/sysimage/boot/efi $0 {list|scrub [--yes]|install-hook}"; exit 1 ;;
esac
