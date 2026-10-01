# Add-on to live mode: qubes in RAM, store detached during the session

Read this first. This is a small addition on top of someone else's work, not a
project of its own. The amnesic session it runs in is [linuxuser1](https://forum.qubes-os.org/u/linuxuser1)'s live mode,
start there:

https://forum.qubes-os.org/t/qubes-os-live-mode-dom0-in-ram-non-persistent-boot-ram-wipe-protection-against-forensics-tails-mode-hardening-dom0-root-read-only-paranoid-security-ephemeral-encryption/38868

What is mine is only the layer that carries the workload: qubes kept in an
encrypted store, loaded into RAM, worked on with the store closed, saved back.

## Status

Experimental, and the concept changed at the end of September 2026.

This project used to clean dom0 by hand. That was the wrong call. A read-only
root with an ephemeral overlay removes the problem instead of patching it, and
[linuxuser1](https://forum.qubes-os.org/u/linuxuser1)'s thread already does that properly, so the session layer is his.

I also said the RAM pool was gone. That was too broad and I am correcting it.
It was only redundant as a way to make dom0 amnesic. As the place the workload
runs it is the point of this repo, and it is back.

## Why a layer on top is needed at all

An amnesic session loses workload state at shutdown. For most things that is the
point. For some it breaks them.

Messengers with forward-only crypto are the clear case. Their state must only
move forward. If every boot starts from nothing you get a new identity every
time and no conversation survives. If you restore an older copy you roll the
state backwards and the sessions break.

I tested that rather than assumed it. Three SimpleX profiles in one group, one of
them rolled back to an earlier snapshot, a third kept untouched as a control. The
rolled back one stopped receiving. The control received everything. Write-up:
https://forum.qubes-os.org/t/qubes-ghost-amnesic-session-portable-qubes-on-encrypted-removable-media-saved-forward-only/43459/21

So the workload needs to persist somewhere that is not the internal disk.

## Four ways to run a qube

Pick by what the qube is.

Whole thing in RAM. The qube is standalone, it goes into memory and the store
closes behind it and is gone from the system. This is the only one with a real
air gap. Small and secret things go here: the vault with keys, a wallet, a
messenger. Gigabytes, not more.

Template in the store, only the qube's own data in RAM. The store stays open so
there is no air gap, but memory costs little and one template is shared by
several qubes. Use it when the system is heavy and the data is light: a build
environment, a browser qube on a large template.

Whole thing stays in the store. A chain node, an indexer. Hundreds of gigabytes,
they will never fit in memory, and that is not a defeat: there are no secrets
there, a public chain is public by definition. The strong protection goes to
what deserves it instead of to everything.

What I run: keys and wallet the first way, node and indexer the third. The
second is for qubes that are a bit large for memory but hold little data.

## The two rules

Forward only. The newest save is the only valid one. Restoring an older archive
is an error, not a recovery option. `ghost` now enforces this: a save seals the
new archive (generation number, name, SHA-256) and only then deletes the older
ones, and a load accepts nothing but the sealed archive, verifies its hash
first, and refuses if the store has been wound back behind a generation that
was already loaded. What this stops is an accident and a swapped or modified
archive. It does not stop someone who controls the whole volume, because the
seal lives in the store and rolls back with it. Catching that needs a counter
somewhere the store cannot reach, in a TPM or in Heads, and that is not built.
Going back is still possible on purpose, with `ghost seal <archive>`, which
takes the archive name in full and records the step as a new generation.

Work in RAM with the store detached. The qubes are restored from the store into
a pool that lives in RAM, then the store is closed and removed from the system.
You work with it gone. It comes back only for the save. During the session the
disk sees nothing and a compromise inside a running qube has nothing to reach
for.

This costs one constraint. Qubes that work this way must be standalone, or their
template has to be in RAM too. If the template stays in the store you cannot
close the store, because the qube loses its root. Anything too large for RAM, a
chain node for instance, runs the other way, with the store open. That is a fair
split: the large things here hold public data, the secrets are small.

## What is here

    scripts/ghost              the cycle in one script, see below
    scripts/ghost-load.sh      older separate restore step
    scripts/ghost-save.sh      older separate save step
    scripts/ghost-teardown.sh  older separate teardown step
    scripts/ghost-ram-pool.sh  older separate RAM pool setup
    swap-guard/                detect swap, reset zram if it finds it, warn loudly
    tests/forward-only.sh      proves the forward-only refusals, no Qubes needed
    tests/ram-placement.sh     proves it refuses to restore anywhere but RAM
    tests/state-bundle.sh      proves only the named paths leave the qube
    tests/sterile.sh           proves it will not call a dirty machine safe
    tests/lib-stubs.sh         the stubs the tests share

`ghost` opens the store itself, you give it the passphrase. The four older
scripts expect it already open and mounted.

## Deployment

See DEPLOYMENT.md. Read it before running anything, the teardown step removes
qubes.

## Roadmap

The cycle itself, done. Qubes restored into RAM, store closed while working,
changes saved back, proven on real hardware.

One script for the whole cycle, done.

Refuse to load anything but the newest archive, and prune old ones on save.
Done. `tests/forward-only.sh` covers the refusals, including an interrupted
save: the previous seal survives it and stays loadable.

Check that restored volumes really landed in RAM and fail closed if not. Done.
`ghost` now follows the whole chain before it restores anything - pool, volume
group, physical volume, loop file, filesystem - and after the restore it checks
where each volume actually went, removing the restored qubes if any of them is
outside RAM. `tests/ram-placement.sh` covers it.

Hash the archive and mark it complete only after verifying. Done, it came with
the forward-only work: the seal is written after the hash is taken, and the
hash is checked again before every load.

Keep only the crypto state of a messenger instead of a whole qube image. Done
as `state-save` and `state-load`. A file in the store names the paths worth
keeping, and optionally a command that closes the app first so its database is
not copied mid-write. What leaves the qube is those paths and nothing else, a
few megabytes instead of an image, sealed under the same forward-only rule.
The qube itself can then be an ordinary one, built from a stock template in RAM
and discarded at the end. Proven against a stand-in filesystem in
`tests/state-bundle.sh`, not yet against a real messenger.

Matrix: whether the session really rotates, and whether a key re-request heals
the rollback. Answered by testing, and it corrects what I reported earlier. The
session does rotate: adding a member changed the Megolm session id, and the
message sent after the rollback used the new session. A client rolled back to a
snapshot taken before that key reached it could not read that message, while an
untouched client in the same room read it fine. Run without the rotation, the
same rollback costs nothing. So Matrix survives a rollback only for as long as
the session does not change; across a rotation it loses messages too. The
second half is still open: no key re-request went out on its own, and a single
device with no key backup has nothing to request from, so a real client with
key backup enabled may well heal where this one did not.

Sterility checks before power off. Done. `down` now ends with a verdict
instead of a cheerful word: it checks that no qube still has a volume in the
RAM pool, that the pool, the volume group, the loop device, both mounts and the
open store are all gone, and that swap on a disk is not active. zram swap is
noted rather than held against it, because it lives in RAM and goes with the
power. The same check is available on its own as `ghost sterile`. There is no
log scrubbing: the amnesic session makes dom0's root ephemeral, so there is
nothing to scrub. `tests/sterile.sh` covers it.

## Open questions, and where they stand

Other on-disk writes during a restore into a non-default pool. *Still open.* I
have not audited it.

Whether repointing the default pool is the right way to force restore
placement. *Answered by trying.* There is no option for the target pool, so
switching the default pool for the duration is what works.

dom0 logs recording qube names. *Gone, and not because I solved it.* The amnesic
session makes dom0's root ephemeral, so there is nothing left to scrub. That
whole class went away with the design change.

Whether `noswap` `tmpfs` is enough against paging. *Still open.* The swap here is
zram and stays in memory, but I have not proven the general case.

Paranoid-mode restore. *Dropped.* The default policy refuses the volume import
and I am not using it. Allowing it needs a policy for that call, which I have
not written.

## Known limits

The rework is not finished, and the docs describe where it is going as much as
where it is.

A compromised dom0 defeats all of this. So does a compromised session before you
detach the media.

The forward-only seal lives in the store, so it is a guard against mistakes and
against a tampered archive, not against an adversary who can restore an old copy
of the whole volume.

The placement checks trust what the storage stack reports. The chain from the
pool down to the tmpfs is followed rather than assumed, so a pool named `r1`
that quietly points at disk is caught, but if LVM or the loop layer itself
misreports, the check passes and the guarantee is gone.

`noswap` is requested when the tmpfs is mounted and its absence is only a
warning, because kernels before 6.4 have no such option. On those, the
swap-guard scripts are what stands between the pool and swap.

Only I have run this, on one laptop. Treat results accordingly.

## Prior art

[linuxuser1](https://forum.qubes-os.org/u/linuxuser1)'s live mode thread is the base this now sits on, linked at the top.

## Contributing

Bugs in the amnesic session belong in [linuxuser1](https://forum.qubes-os.org/u/linuxuser1)'s thread, not here. Bugs in the
load, save and teardown cycle belong here.

## License

See LICENSE.
