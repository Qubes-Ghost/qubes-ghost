# Add-on to live mode: qubes in RAM, store detached during the session

Read this first. This is a small addition on top of someone else's work, not a
project of its own. The amnesic session it runs in is linuxuser1's live mode,
start there:

https://forum.qubes-os.org/t/qubes-os-live-mode-dom0-in-ram-non-persistent-boot-ram-wipe-protection-against-forensics-tails-mode-hardening-dom0-root-read-only-paranoid-security-ephemeral-encryption/38868

What is mine is only the layer that carries the workload: qubes kept in an
encrypted store, loaded into RAM, worked on with the store closed, saved back.

## Status

Experimental, and the concept changed at the end of September 2026.

This project used to clean dom0 by hand. That was the wrong call. A read-only
root with an ephemeral overlay removes the problem instead of patching it, and
linuxuser1's thread already does that properly, so the session layer is his.

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

## Three ways to run a qube

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
is treated as an error, not as a recovery option. `ghost-save.sh` refuses to
write an archive older than the one on the volume.

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
    swap-guard/                refuse to run if swap is enabled, and say so loudly

The scripts take an already opened volume. Open it in the vault and point them
at the mount.

## Deployment

See DEPLOYMENT.md. Read it before running anything, the teardown step removes
qubes.

## Known limits

The rework is not finished, and the docs describe where it is going as much as
where it is.

A compromised dom0 defeats all of this. So does a compromised session before you
detach the media.

The placement checks trust what the storage stack reports. If a pool lies about
where a volume lives, the check passes and the guarantee is gone.

Only I have run this, on one laptop. Treat results accordingly.

## Prior art

linuxuser1's live mode thread is the base this now sits on, linked at the top.

Related threads worth reading: Qubes in tmpfs (11127), Qubes OS 100% in RAM
(38913), ephemeral DVMs in fully ephemeral thin pools (42545).

newqube pointed me at the live mode thread when I was still defending my own
worse version. Credit for the work itself is linuxuser1's.

FranklyFlawless reviewed the code and the threat model and found real problems in
both. Issues 1 to 8 came out of that review.

## Contributing

Bugs in the amnesic session belong in linuxuser1's thread, not here. Bugs in the
load, save and teardown cycle belong here.

## License

See LICENSE.
