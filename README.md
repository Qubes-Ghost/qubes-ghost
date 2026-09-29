# Qubes Ghost

**An amnesic operating mode for Qubes OS: run the session so it leaves nothing behind, load only the qubes you need from an encrypted removable volume, work with the media physically disconnected, then save them back and power off. The session is amnesic. The workload is not: it is portable, and it is only ever saved forward.**

> Status: **experimental / proof-of-concept.** The core cycle (restore from an encrypted volume -> work -> save -> teardown -> verify sterility across a reboot) has been validated end-to-end on a RAM pool. The design is now moving to an amnesic dom0 session instead of a separate RAM pool (see Roadmap and the note on prior work below), which makes several of the scripts here simpler or unnecessary. Interfaces are changing. Do not rely on it for anything you cannot afford to lose until you have tested your own workflow thoroughly.

## Why I built this

I built Qubes Ghost because it was the piece missing for *me*. I already had the individual ingredients that this community has documented so well - Qubes' compartmentalization, encrypted removable media, deniable volumes, RAM-only tricks - but I could not find a workflow that combined them the way I actually needed: a normal, updatable base system that leaves **no trace of my real work on the internal disk**, where each sensitive task is its own encrypted, portable qube that I load into RAM only when I need it and that lives, at rest, only on media I physically control. This is my attempt at that missing workflow. If it is missing for you too, maybe it helps.

## Defence in depth: staged fallback, each with its own threat model

A design goal is that there is no single "all or nothing" secret. Instead there are **several echelons of retreat**, and you choose how far you are willing (or able) to fall back - each echelon exposes strictly less and rests on its own threat model:

1. **A powered-off machine.** With Ghost, the internal disk carries no evidence of *what* you worked on: no sensitive qube, no name, no content. What it does carry is the tooling itself - the vault template, the pool registration, these scripts - so the honest answer to "what's on this computer?" is not "an ordinary install" but "a Qubes machine set up to keep its workload off the disk." **This echelon protects content, not the existence of the tooling.** *Threat model: offline forensic imaging.*
2. **The removable media, disconnected.** Your work lives only there, and it is not in the machine. Not present, nothing to image. *Threat model: search of the machine while the media is elsewhere.*
3. **The outer (decoy) volume.** If compelled to reveal *a* password, you can open an outer VeraCrypt volume with plausible, innocuous contents. *Threat model: coercion to unlock "the drive."*
4. **The hidden volume.** The real qubes live in a hidden volume whose very existence is not provable from the outer one. *Threat model: coercion where the decoy is not believed to be everything - deniability of existence.*
5. **Air-gap during work.** Even while you are actively working, the media is physically detached, so a live compromise of a running qube cannot silently read the still-attached secret store. *Threat model: in-session compromise reaching for the vault.*

Each layer is independent: you can stop at whichever one your situation calls for, and the weaker layers do not undermine the stronger ones. Note that echelon 1 no longer claims to hide that *a* tool is in use; if your situation requires that, echelons 3-4 are what carry deniability about the data, and layer 1 of your platform (below) is what carries deniability about the system disk. (The strength of layers 3-4 depends entirely on VeraCrypt's hidden-volume guarantees and on your own operational discipline - read their documentation on the limits.)

---

## What problem does this solve?

Full-disk encryption protects data **at rest, once the machine is off**. It does nothing against an adversary who can compel you to unlock the disk, or who images the disk while it is unlocked, or who simply observes that "a lot of encrypted, high-entropy data changed on this system between Tuesday and Thursday." A standard Qubes install accumulates forensic residue on the internal disk with every session: qube images grow, logs record qube names and operations, swap can page sensitive memory to persistent storage, thumbnails and caches survive.

Qubes Ghost aims for a stronger property: **after a session, the internal disk looks the same as it did before the session.** No qube images were written to disk, no qube names were logged, nothing sensitive touched swap. The only place your work persists is an **encrypted removable volume that you physically control and disconnect during use**. If that volume is a VeraCrypt *hidden* volume, you additionally gain plausible deniability about whether any sensitive data exists at all.

This is the "amnesic" idea familiar from Tails, brought into Qubes' compartmentalized, VM-per-task world: instead of one amnesic desktop, you get amnesic, individually-encrypted, individually-loadable **qubes**.

---

## How this differs from prior work on the Qubes forum

The Qubes community has explored RAM-resident and deniable setups before, and Ghost stands on those threads' shoulders - but it occupies a different point in the design space:

- **[Qubes OS live mode / dom0 in RAM](https://forum.qubes-os.org/t/qubes-os-live-mode-dom0-in-ram-non-persistent-boot-ram-wipe-protection-against-forensics-tails-mode-hardening-dom0-root-read-only-paranoid-security-ephemeral-encryption/38868)** by *nullnullseven* is the base this project now builds on, and it replaced a design decision I had got wrong. It makes dom0 itself amnesic: a read-only root with an ephemeral overlay, plus a RAM wipe on shutdown. An earlier version of this README argued that Ghost deliberately kept dom0 persistent and cleaned up afterwards instead. That was the weaker choice. Scrubbing logs, panel state and metadata one path at a time is an endless list, and it made several of the bugs in this repo's issue tracker possible in the first place; with a read-only root there is nothing left to scrub. What that approach does not do is keep workload state, and that turns out to matter a great deal (see "Why the workload is not amnesic" below). **[Qubes in tmpfs](https://forum.qubes-os.org/t/qubes-in-tmpfs/11127)** and **[Qubes OS 100% in RAM](https://forum.qubes-os.org/t/qubes-os-100-in-ram-tmpfs-anti-forensic-amnesic-script-dom0-allows-restoration/38913)** are earlier work in the same direction.
- **[Ephemeral DVMs in fully ephemeral thin pools](https://forum.qubes-os.org/t/ephemeral-dvms-in-fully-ephemeral-thin-pools-ephemeral-encryption-zram-disk-tmpfs/42545)** makes DisposableVMs leave no trace - pure ephemerality, nothing survives. Ghost's qubes are **persistent-but-portable**: full AppVMs whose state *does* survive between sessions - it just lives on an encrypted (optionally hidden) removable volume instead of the internal disk, under an explicit load -> air-gap -> save lifecycle with placement verification, archive manifests, and fail-closed error handling.
- **[Really disposable (RAM based) qubes](https://forum.qubes-os.org/t/really-disposable-ram-based-qubes/21532)** is the closest precedent to Ghost's RAM pool: the same core idea of a `tmpfs`-backed storage pool registered with `qvm-pool`. Its stated goal is reducing SSD writes rather than anti-forensics, and it does not cover the encrypted removable vault or the load -> air-gap -> save lifecycle - but the mechanism overlap is real and it deserves the credit. It also does two things Ghost did not: redirecting qube logs to `/dev/null` instead of scrubbing them afterwards, and trap-based cleanup that survives a forced kill. Both are being adopted.
- **[Install Qubes OS with a detached LUKS header on USB](https://forum.qubes-os.org/t/install-qubes-os-with-boot-partition-and-a-detached-luks-header-on-usb/26366)** (and the earlier [discussion](https://forum.qubes-os.org/t/qubes-os-detached-luks-header-installation/5813)) solve the *system-disk deniability* problem. In Ghost's terms that is **Layer A** - one of the boot layers Ghost is designed to compose with, not a competitor.

In one line: **prior art makes the system amnesic or the disk deniable; Ghost makes your *workload* amnesic on the machine and persistent only on removable, deniable, air-gapped media - while composing with either kind of base.**

---

## The canonical scheme

1. The machine boots a **clean, empty Qubes install** - default networking/USB qubes and minimal templates, nothing sensitive.
2. A **RAM pool** is created: a `tmpfs` mount (strictly `noswap`) registered as a Qubes storage pool. All sensitive qubes will live here and nowhere else.
3. Using Qubes' own tools, an offline **DispVM** opens an **encrypted volume on removable media** (e.g. a VeraCrypt hidden volume). The decryption passphrase is entered only inside that DispVM, never in dom0.
4. Only the **specific qubes you need** are restored from the volume **into the RAM pool** (via `qvm-backup-restore`, with the default storage pools temporarily pointed at the RAM pool, and per-volume verification that nothing leaked onto the internal disk).
5. The removable media is **physically disconnected** for the duration of your work (air-gapping the vault). Your qubes run entirely from RAM.
6. When finished, you reconnect the media and **save** the chosen qubes back to the encrypted volume (`qvm-backup`, with a content-verified, hash-manifested archive).
7. A **teardown** step removes the RAM-resident qubes, scrubs logs and journald, and asserts post-conditions (no volumes remain in the RAM pool, the vault is off, swap is inactive). Then you power off; the `tmpfs` - and everything in it - evaporates.

The internal disk is never written with qube data. Sensitive material exists only on the removable volume, only while it is attached, and the *volume* passphrase is never seen by dom0. (The backup-archive passphrase is a separate secret and does pass through dom0 during restore until paranoid mode works - see the threat model.)

---

## Architecture: two layers

Qubes Ghost deliberately separates two concerns so that the sensitive part is portable across very different platforms:

- **Layer A - "how the machine starts and opens its system disk."** This is inherently platform-specific. Examples include measured-boot platforms (where `/boot` integrity is attested and any change must be re-signed) and platforms that keep the LUKS header *detached* on removable media (so the internal disk is indistinguishable from noise without the header). These have different trust models and different failure modes and are handled per-platform.
- **Layer B - "the ghost."** The RAM pool, the encrypted-vault protocol, the load/save/teardown lifecycle. **This layer is identical everywhere** and is what this project is primarily about.

Keeping Layer B independent of Layer A means the same audited, minimal-template "ghost image" is the reusable building block regardless of how a given machine boots.

---

## Components

Four dom0 scripts, coordinated by a single lock so they never run concurrently:

| Script | Role |
| --- | --- |
| `ghost-ram-pool.sh` | Disables and masks swap, mounts a `noswap` `tmpfs`, registers it as a Qubes storage pool. Fails closed if the kernel lacks `noswap` support or if swap cannot be guaranteed off. |
| `ghost-load.sh` | Enforces the vault is an offline DispVM, attaches the media, waits for the encrypted volume to be mounted *inside the vault*, restores selected qubes into the RAM pool, verifies **each restored volume actually landed in the RAM pool** (aborts and removes them if not), then detaches the media only after a proven dismount. |
| `ghost-save.sh` | Reverse path: attach, save selected qubes to a uniquely-named directory on the volume, verify the archive, write a `sha256` manifest, mark `.done` only after verification, detach only after proven dismount. |
| `ghost-teardown.sh` | Finds every qube with any volume in the RAM pool, shuts them down and removes them, overwrites (not just unlinks) logs / journald / shell history that name the qubes, removes the RAM pool and unmounts its tmpfs, and asserts sterility post-conditions before you power off. Swap itself is kept off by `ghost-ram-pool.sh` and the separate swap-guard timer, not by teardown. |

Design principles throughout: **fail closed** (any ambiguity aborts rather than risks a leak), **prove before destroy** (media is detached only after a confirmed dismount, even on the error path), **verify placement** (every restored/created volume is checked to be in RAM, not on disk), and **the volume passphrase never enters dom0** (it is typed inside the offline vault). Note this is the *volume* passphrase; the separate *backup-archive* passphrase used by `qvm-backup-restore` is entered in dom0 today, because paranoid-mode restore does not yet work - see the threat model.

Every script is heavily commented so that each command is transparent - you should be able to read exactly what touches disk, what touches the vault, and what is asserted before anything is destroyed.

## Deployment

See **[`DEPLOYMENT.md`](DEPLOYMENT.md)** for a simple, step-by-step walkthrough: one-time preparation (minimal vault template, the networkless DisposableVM, installing the scripts, preparing the encrypted volume) and the per-session cycle (create RAM pool -> load -> work air-gapped -> save -> teardown -> power off), plus acceptance tests you should run on throwaway qubes before trusting it.

---

## Why the workload is not amnesic

Full amnesia is the obvious answer, and for the system layer it is the right one. For the
workload it is not, and this is the reason Ghost still exists as a separate thing.

Messengers built on a forward-only ratchet (SimpleX, Signal, Matrix clients) keep per-device
crypto state that both sides advance together. Under full amnesia there are no long-lived
sessions at all: every boot is a new identity, because the ratchet cannot carry across. That
is not a corner case for the workloads this project exists to carry.

The mirror-image risk is Ghost's own, so it is stated plainly. Saving a qube and restoring it
later is fine while the newest snapshot is the one restored. Restore an **older** archive, after
a crash or from a duplicated volume, and the ratchet has been moved backwards.

That is worse than losing continuity. A rollback puts the ratchet key back to its value at time
T, and a peer only ratchets forward when it sees a new public key from us. After a rollback it
never sees one, so post-compromise security never engages: whoever captured the state at T, by
compromising the networked qube during a session or through a compelled unlock, keeps reading
indefinitely until the accounts are re-handshaked by hand. A rollback does not lose history, it
pins the ratchet at the point of compromise. That sharper statement is the reviewer's, and it is
more accurate than the one this project started with.

This was tested rather than assumed. Three members in a group, one sender, one reader, one
control who is never rolled back. State directory of the reader copied, more messages sent,
second copy taken, then the first copy restored over the reader's state and the sender kept
writing. The control received the new messages. The rolled-back reader received none, having
read everything correctly up to that point. First two attempts produced a false confirmation
(nothing was being delivered at all, and the script still reported the rollback as the cause);
the control member is what caught it, which is why the harness now refuses to draw a conclusion
until delivery is proven first.

So the rule is: **workload qubes are saved forward only, and never restored from an older
archive.** Both scripts now enforce it rather than only documenting it.

`ghost-load.sh` refuses any save directory that is not the newest completed one. There is an
environment-variable override for the case where the newest save is damaged and an older one is
all you have, and it prints what it costs: re-handshake every ratcheting account afterwards, and
do not assume the sessions are safe.

`ghost-save.sh` writes to a uniquely named directory each time so a bad save cannot overwrite a
good one, and then prunes older completed saves down to a small window, two by default. Left
alone those directories accumulate, and every one of them opens with the same passphrase, which
is a stack of restorable earlier states rather than an archive. Pruning runs only after the new
save has been verified and marked complete, so nothing is removed until its replacement is proven
good, and the removed archives are overwritten before being unlinked.

Tested on SimpleX. Matrix/Megolm is a different construction and is being tested separately;
no claim is made about it by analogy.

---

## Threat model (what it does and does not do)

**In scope:**
- Forensic examination of the powered-off internal disk showing no evidence of the session's qubes.
- Preventing sensitive qube memory from being paged to persistent swap.
- Preventing dom0 logs from retaining sensitive qube names/operations - by not writing them where that is possible, and by scrubbing otherwise (see the note on storage-stack verifiability below for why the distinction matters).
- Plausible deniability about the *existence* of sensitive data, when a hidden volume is used. This is deniability about the **data on the volume**, not about the tooling on the machine.
- Air-gapping the vault while working, so a compromise during the session cannot silently read the still-attached secret store.

**Out of scope / assumptions:**
- Cold-boot / DMA attacks against RAM while the machine is running or immediately after power-off. RAM holds plaintext during a session by design.
- A compromised dom0 or a malicious template. Qubes Ghost trusts the base install; it does not defend a base that is already backdoored.
- **The vault contents are trusted input.** The raw USB device is never attached to dom0 - it stays behind the usual USB qube and only the block device is passed to the offline vault, where the volume is opened. However, the backup *archive stream* is currently parsed by `qvm-backup-restore` running **in dom0**: Qubes' "paranoid mode" (restore inside a DisposableVM) does not yet work for this flow (the DispVM's volume import is refused by the default qrexec policy - see Known limitations). The archive format is authenticated with the backup passphrase, but dom0's parser does see the archive before full verification. If an adversary can both tamper with your media *and* knows your backup passphrase, the restore path is attack surface. Until paranoid mode is wired up, treat the volume as trusted input.
- **Verifying what the storage stack actually did.** Between a shell command and the medium there are filesystem caches, journaling, the SSD's FTL and wear levelling, TRIM behaviour and firmware bugs. When something is written and later deleted, an outside observer cannot establish which of three things happened: the data persisted despite the delete, it was genuinely discarded after a TRIM, or it never left a volatile cache at all. No userspace tool closes that gap, and a qualified examiner will look at every one of those layers. This is why the log scrubbing in `ghost-teardown.sh` is defence in depth against third-party leftovers and **not** the mechanism this design rests on. The mechanism is that the sensitive qubes live in a `tmpfs` pool and on removable media, so for them the write is never issued in the first place; and where the internal disk is encrypted, whatever the FTL may still retain is ciphertext, useless against the powered-off threat model. Credit to *qubist* on the Qubes forum for pressing this point.
- **Hiding that the tooling is in use.** An earlier version of this README said a powered-off machine answers "what's on this computer?" with "an ordinary minimal Qubes install". That is withdrawn. It is a claim about matching a population, the comparison class is chosen by whoever examines the machine and it moves over time, and the base has to carry the vault template, the pool registration and these scripts anyway. The comparison class is therefore "Qubes plus this tooling", and the guarantee is about content, not about existence. Credit to the reviewers who pushed on this.
- Coercion where revealing the *outer* volume is insufficient. Deniability is only as strong as your operational discipline and your platform's Layer A.
- Anything the underlying platform's boot layer cannot guarantee (see Layer A).

Please read Qubes' own security guidance and the VeraCrypt documentation on the limits of hidden volumes before relying on any of this.

---

## Known limitations

- **Paranoid-mode restore does not work (investigated, cause identified).** `qvm-backup-restore --paranoid-mode` spawns the DisposableVM, decrypts and verifies the archive and creates the qubes, then aborts with `Service call error: Request refused`, leaving them empty. Contrary to the obvious guess, this is *not* the volume import being blocked - the shipped `/etc/qubes/policy.d/85-admin-backup-restore.policy` does grant `admin.vm.volume.Import` and `ImportWithSize` to the restore tags. Reproduced on a clean Qubes 4.3.1 install, the actual failure is on the `created-by-dom0` tag, on two layers: `admin.vm.tag.Set+created-by-dom0` is permitted by qrexec policy but rejected by qubesd itself at the Admin API layer, and `admin.vm.tag.Get+created-by-dom0` has no matching policy rule at all. Until this is resolved upstream the scripts restore in dom0, which is why the vault contents must be treated as trusted input (see threat model). Reported for discussion; help welcome.
- An AppVM's `root` volume legitimately resides in its template's pool (templates are persistent by design in this scheme); the placement checks therefore cover `private` and `volatile`, where the qube's own data lives. Writes to root go to `volatile`, which *is* checked.
- `tmpfs noswap` requires a reasonably recent kernel; the pool script fails closed on kernels without it.

---

## Roadmap

**1. Amnesic dom0 session.** Raise `dom0_mem`, re-sign `/boot` where the platform measures it,
install the live-mode modes linked above. The disk-backed encrypted overlay is the variant that
fits here: it is bounded by disk rather than RAM. First thing to check, and the main risk of the
whole redesign: whether `qvm-backup-restore` survives a read-only root. There is a sqlite
database, libvirt state and permissions involved, and if it does not survive, the qubes have to
reach the session some other way. Better to learn that before rewriting anything else.

**2. Full cycle on top of the amnesic session.** The same load, work, save, teardown, reboot
cycle that is already proven, but with no pool of our own: qubes are restored into the default
pool, which is itself ephemeral. Verify sterility across a reboot.

**3. Simplify the scripts.** `ghost-ram-pool.sh` goes away. `ghost-load.sh` loses the pool
handling. `ghost-teardown.sh` shrinks to post-condition checks. This is not cosmetic: less code
is fewer failure paths, and seven of them were just closed.

**4. Reproducible base install.** A generic kickstart for the Qubes installer and a Salt formula
that converges an existing install, as before, except the base they build now includes the
amnesic modes rather than a pool of our own. No secrets in either. This also folds in
conservative dom0 slimming, following the community's
[minimize-dom0 work](https://forum.qubes-os.org/t/how-to-minimize-dom0/20945).

**5. Crypto stack.** A chain node and its indexer do not fit an amnesic session, and should not
be forced into one: they run for days, and the media cannot be detached while they do. The node
lives on its own encrypted volume and holds no keys, only a copy of the public chain. The wallet
stays in the amnesic session and reaches the node over qrexec, so the wallet qube needs no
network at all. What is secret is the keys and which addresses are yours, not the blockchain.

**6. Second boot layer: detached LUKS header.** Still the next frontier, and still deliberately
unshipped: that base is proven in emulation but has not run the full cycle on real hardware, and
we do not publish claims we have not validated. Only the workload layer is shared between the
two boot layers; this is genuinely separate work.

**7. Network-delivered headers.** Fetch the material that opens the system over the network
instead of from physical media.

**8. Fully modular sources.** The two independent ingredients, the headers that open the system
and the encrypted volume holding your qubes, should each be loadable either from physical media
or over the network, in any combination.

Steps 1 and 2 come before step 3 on purpose. Deleting working code for a design that has not run
yet would be the wrong order.

---

## Prior art and acknowledgements

Qubes Ghost is glue and discipline on top of excellent existing work. It would not exist without:

- **[Qubes OS](https://www.qubes-os.org/)** - the entire foundation: storage pools (`qvm-pool`), the backup/restore system (`qvm-backup`, `qvm-backup-restore`), DisposableVMs, the qrexec policy system, and `qubes-core-admin-client`. The RAM-pool trick is simply a Qubes `file`-driver pool backed by `tmpfs`.
- **[Tails](https://tails.net/)** - for popularizing and proving the amnesic-OS model that this project brings into Qubes' per-qube world.
- **[VeraCrypt](https://veracrypt.io/)** - hidden volumes and the plausible-deniability model for the vault.
- **[Whonix](https://www.whonix.org/) and [Kicksecure](https://www.kicksecure.com/)** - minimal, hardened templates and the anonymity/hardening posture the ghost qubes build on.
- **[qusal](https://github.com/ben-grande/qusal)** by Ben Grande - Salt formulas for reproducible, minimal Qubes provisioning, which informed the minimal-template approach (and warned us about `sys-usb`/grub regeneration pitfalls).
- The community's [dom0 minimization thread](https://forum.qubes-os.org/t/how-to-minimize-dom0/20945) - complementary hardening we lean on for the reproducible-base step.
- The Qubes forum threads that mapped this territory first: [Qubes in tmpfs](https://forum.qubes-os.org/t/qubes-in-tmpfs/11127), [Really disposable (RAM based) qubes](https://forum.qubes-os.org/t/really-disposable-ram-based-qubes/21532), [Ephemeral DVMs in fully ephemeral thin pools](https://forum.qubes-os.org/t/ephemeral-dvms-in-fully-ephemeral-thin-pools-ephemeral-encryption-zram-disk-tmpfs/42545), [Qubes OS live mode / dom0 in RAM](https://forum.qubes-os.org/t/qubes-os-live-mode-dom0-in-ram-non-persistent-boot-ram-wipe-protection-against-forensics-tails-mode-hardening-dom0-root-read-only-paranoid-security-ephemeral-encryption/38868), [Qubes OS 100% in RAM](https://forum.qubes-os.org/t/qubes-os-100-in-ram-tmpfs-anti-forensic-amnesic-script-dom0-allows-restoration/38913), and [detached LUKS header installation](https://forum.qubes-os.org/t/install-qubes-os-with-boot-partition-and-a-detached-luks-header-on-usb/26366) - see "How this differs" above.
- The wider Qubes community's writing on **anti-forensics, plausible deniability, and DispVM-mediated device handling**, which shaped the threat model.

Any mistakes in applying these are ours, not theirs.

---

## Contributing & feedback

This is early. The most useful contributions right now are **adversarial review of the threat model** and **reports of leaks** - any path by which qube data reaches the internal disk, any log that records a sensitive name, any way the passphrase could reach dom0. If you find one, please open an issue describing the exact steps.

## License

Released under the MIT License. See `LICENSE`.

*Qubes Ghost is an independent community project and is not affiliated with or endorsed by the Qubes OS Project.*
