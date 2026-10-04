# Installing to a USB drive without leaving a boot entry on the host

A small, self-contained note. It stands on its own and does not need the rest of
this repo.

## The problem

When you install Qubes onto a USB drive, the installer adds a boot entry to the
firmware of the **machine you installed from** - an entry named "Qubes OS" that
points at a partition on the drive. That entry stays in the host's NVRAM after
you unplug the drive. On a computer that is not yours, it is a trace you did not
mean to leave. On your own, it is clutter that also breaks the day the drive is
repartitioned.

## Why the entry is not needed

Qubes already installs a removable fallback loader at `\EFI\BOOT\BOOTX64.EFI` on
the drive's ESP. The firmware boot menu (F12 and the like) boots the drive as a
removable device through that path, with no NVRAM entry involved. So the entry
the installer wrote can simply be removed.

## One removal is not enough

The fallback itself never creates an entry. But some firmwares silently re-add
one **every time they boot a USB device**. So a single cleanup right after the
install does not keep the drive clean across later use on other machines.

The script below covers both:

- `list` - show the boot entries whose name matches, and nothing else.
- `scrub` - remove them now. Run it from the installer's shell (in Anaconda,
  `Ctrl+Alt+F2`) before the first reboot, while the target is mounted under
  `/mnt/sysimage`.
- `install-hook` - install a small service inside the booted system that runs
  the scrub on **every shutdown**. Whatever a host added during the session is
  gone before the drive leaves it. This needs `efibootmgr` in the booted system;
  on Qubes dom0, `sudo qubes-dom0-update efibootmgr`.

## Safety

It matches on the **exact** entry name (default `Qubes OS`), so every other boot
entry is left exactly as it was. Before removing anything, `scrub` checks that
the removable fallback is actually present - if it is missing it refuses, rather
than leave a drive that will not boot. Change `LABEL=` if you installed something
with a different name, and `ESP=` if the drive's ESP is mounted elsewhere.

The script is in `scripts/nvram-scrub.sh`.
