# Deployment

Read this before running anything. The teardown step removes qubes.

The session itself is not set up here. Use linuxuser1's live mode work for that,
linked in the README. What follows assumes you are already booted into an
amnesic session, or into a normal one if you are just trying the cycle out.

## Concepts

Three things and one rule.

The vault is a networkless DisposableVM. Your encrypted media is attached to it,
you open the volume inside it, and the passphrase is typed there. It never
reaches dom0.

The volume is on the removable media. Inside it there is a directory named
`qubes` and that is where the archives go.

The pool is where restored qubes live while you work. It is in RAM.

The rule is that saves only move forward. The newest archive is the valid one.
An older archive is not a recovery option, restoring one breaks any qube whose
crypto only moves forward.

## One-time setup

### The vault template

Build a minimal template and install into it whatever you use to open your
encrypted volume. Keep it small. It does not need network after that.

### The vault qube

    dom0$ qvm-create --class DispVM --template <dvm-based-on-your-template> --label red ghost-vault
    dom0$ qvm-prefs ghost-vault netvm ''
    dom0$ qvm-prefs ghost-vault provides_network false

Check it:

    dom0$ qvm-prefs ghost-vault netvm     # prints nothing
    dom0$ qvm-prefs ghost-vault klass     # prints DispVM

### The scripts

Move them into dom0 the normal deliberate way, then:

    dom0$ sudo install -m 0755 ghost-ram-pool.sh ghost-load.sh ghost-save.sh ghost-teardown.sh /usr/local/bin/

### The volume

On the removable media, create an encrypted volume. Open it in the vault, make
an empty directory called `qubes` inside it, close it again.

    vault> mkdir -p /mnt/vault/qubes

## A session, the short way

One script does the whole cycle.

    dom0$ sudo ghost up <passphrase>          open the store, bring up the RAM pool
    dom0$ sudo ghost load <qubes>             restore the sealed archive into RAM
    dom0$ sudo ghost air                      close the store, work with it gone
    dom0$ sudo ghost save <passphrase> <qubes>  put it back open and save
    dom0$ sudo ghost down <qubes>             remove everything, close everything
    dom0$ sudo ghost state-save <passphrase> <qube>   keep just that qube's state
    dom0$ sudo ghost state-load <qube>        put it back into a running qube
    dom0$ sudo ghost ram                      check the pool really is in RAM
    dom0$ sudo ghost sterile                  check nothing is left, before power off
    dom0$ sudo ghost state                    what the store says is sealed
    dom0$ sudo ghost seal <archive>           seal an archive that has no seal yet

`load` picks the archive itself, because only one archive is ever valid: the one
sealed by the last save. You can still name it, as in
`ghost load qubes-backup-2026-10-01T1130 vault`, but the name is then checked
against the seal rather than taken as a choice, and an older one is refused.
`save` seals the new archive before deleting the older ones, so there is no
moment where the store has nothing loadable in it.

`seal` exists for two cases and is deliberately blunt about both. A store
written by an earlier version of these scripts has archives but no seal, and
without a seal nothing loads at all. And if you ever do have to go back to an
older archive, this is the way: it is a decision you type out in full, the
archive name is never guessed for you, and it is recorded as a new generation,
so the store shows that it happened.

Two things it handles that bit me when I did it by hand. The thin pool in RAM
has to be deactivated and activated again before a restore, otherwise LVM
refuses with "prohibited while rpool_tmeta is active". And qvm-backup-restore
has no option for which pool to restore into, so the default pool is switched
to the RAM pool for the duration and put back afterwards.

`load` also refuses to restore into anything that is not RAM. Before it starts
it walks the chain - the pool `r1`, the volume group `rvg`, its single physical
volume, the loop file behind that, and the filesystem the file sits on, which
has to be tmpfs - and afterwards it checks where each restored volume actually
landed. If any of them is outside the RAM pool, the restored qubes are removed
and the load fails. For an AppVM the root volume is expected to be in its
template's pool and is not counted against it; for a standalone or a template
it is, because those own their root.

For a messenger there is a lighter way than carrying a whole qube image.
Put a file in the store called `state-<qube>.list`:

    # what is worth keeping out of this qube
    stop: pkill -x simplex-chat
    /home/user/.simplex

`state-save` closes the app with the `stop:` line, tars exactly the listed
paths out of the running qube, reads the result back to be sure it is whole,
seals it and prunes the older bundles. `state-load` verifies the seal and the
hash and streams it back into a running qube. Nothing is guessed: with no list
file, `state-save` refuses rather than deciding for you what matters.

That turns the qube into something ordinary. Build it from a stock template in
RAM, pour the state in, work, pour the state out, discard the qube. The store
then holds a few megabytes of keys and database instead of an image.

`down` no longer just says it is finished. It tears the session down and then
checks: no qube with a volume in the RAM pool, no pool `r1`, no volume group
`rvg`, no loop device on the tmpfs, `/mnt/ram` and the store both unmounted,
`vg1` gone and the store closed, and no swap on a disk. If anything is still
holding on it says `DOWN-NOT-CLEAN` and names it, and the disk should not be
treated as sterile. `ghost sterile` runs the same check on its own, which is
the thing to do right before the power goes off.

Swap on a disk fails the check. zram swap only gets a note: it is in RAM and
goes with the power.

All four sets of refusals can be exercised without Qubes and without a hidden
volume: `bash tests/forward-only.sh`, `bash tests/ram-placement.sh`,
`bash tests/state-bundle.sh` and `bash tests/sterile.sh` stub out the Qubes and
LVM commands and check the sealing, the pruning, what an interrupted save
leaves behind, every link of the RAM chain in turn, that nothing but the listed
paths leaves the qube, and that a machine with something still holding on is
not called safe to power off.

## A session, step by step

### Load

    dom0$ sudo ghost-load.sh

It lists attachable block devices and asks which one is your media. Then it waits
while you open the volume inside the vault and mount it at `/mnt/vault`. Then it
lists the archives it found, restores the ones you pick into the pool, checks
that every volume actually landed there, and detaches the media.

### Work

When the load reports success the media is already detached. Take it out and put
it away. The qubes are running from RAM now.

### Save

Put the media back and run:

    dom0$ sudo ghost-save.sh

Same opening step as before. It writes an archive with a hash manifest, refuses
to write anything older than what is already on the volume, and only detaches
after the unmount is confirmed.

### Teardown

    dom0$ sudo ghost-teardown.sh

Removes the qubes and the pool, then checks that nothing is left behind. Power
off after it.

## Checking that it works

Do this before trusting it with anything.

Load a qube, put a marker file in it, save, teardown, power off. Boot again,
load, and look for the marker. It should be there.

Then check the other direction. After a teardown and reboot, with the media not
connected, the qube should be gone and nothing about it should be findable.

Then check the forward-only rule. Save, then try to restore an older archive on
purpose. The script should refuse.

## Swap

Swap defeats the point. If pages go to disk, the work you kept off the disk is
on the disk.

    dom0$ sudo install -m 0755 swap-guard.sh /usr/local/bin/
    dom0$ sudo install -m 0644 swap-guard.service swap-guard.timer /etc/systemd/system/
    dom0$ sudo systemctl enable --now swap-guard.timer

It checks that swap is off and complains if it is not. It does not turn it off
for you.

## When something goes wrong

If the load stops while waiting for the mount, the volume is not mounted where it
expects. Check inside the vault, not in dom0.

If a restore fails partway, the pool may hold half a qube. Run the teardown
before trying again.

If the media will not detach, something still has the mount open. The script
polls for it rather than forcing a detach, on purpose. Close whatever is holding
it in the vault.
