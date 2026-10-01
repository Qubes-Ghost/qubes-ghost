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
    dom0$ sudo ghost load <archive> <qubes>   restore them into RAM
    dom0$ sudo ghost air                      close the store, work with it gone
    dom0$ sudo ghost save <passphrase> <qubes>  put it back open and save
    dom0$ sudo ghost down <qubes>             remove everything, close everything

Two things it handles that bit me when I did it by hand. The thin pool in RAM
has to be deactivated and activated again before a restore, otherwise LVM
refuses with "prohibited while rpool_tmeta is active". And qvm-backup-restore
has no option for which pool to restore into, so the default pool is switched
to the RAM pool for the duration and put back afterwards.

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
