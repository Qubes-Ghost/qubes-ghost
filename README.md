# Qubes Ghost

This is not an amnesic mode.

For the amnesic session use linuxuser1's live mode work:
https://forum.qubes-os.org/t/qubes-os-live-mode-dom0-in-ram-non-persistent-boot-ram-wipe-protection-against-forensics-tails-mode-hardening-dom0-root-read-only-paranoid-security-ephemeral-encryption/38868

This repo is the layer on top of it. Workload qubes that live on encrypted
removable media, get loaded into the session, stay physically detached while you
work, and are only ever saved forward.

## Status

Experimental, and the concept changed at the end of September 2026.

This project used to build its own RAM pool and clean dom0 afterwards. That was
the wrong call. A read-only root with an ephemeral overlay removes the problem
instead of patching it, and linuxuser1's thread already does that properly. The
separate pool is gone. The scripts here are being reworked to run inside that
session. Interfaces will change. Do not put anything you cannot lose on it yet.

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

## The two rules

Forward only. The newest save is the only valid one. Restoring an older archive
is treated as an error, not as a recovery option. `ghost-save.sh` refuses to
write an archive older than the one on the volume.

Air gap during work. The media is attached for the load, then physically
removed. You work with it out of the machine. It goes back in for the save. A
compromise inside a running qube has nothing to reach for.

## What is here

    scripts/ghost-load.sh      restore qubes from the volume into the session
    scripts/ghost-save.sh      save them back, forward only, with a manifest
    scripts/ghost-teardown.sh  remove the qubes and the pool, verify nothing left
    scripts/ghost-ram-pool.sh  the old separate pool, kept until the rework lands
    swap-guard/                refuse to run if swap is enabled, and say so loudly

The scripts do not care how your encrypted volume is opened. Open it however you
normally do, in a networkless qube, and point them at the mount. Nothing about
the encryption belongs in here.

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
