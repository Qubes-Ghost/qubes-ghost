# Qubes Ghost - deployment guide

A simple, step-by-step walkthrough. It assumes a working Qubes OS install and basic comfort with a dom0 terminal. Nothing here depends on any particular hardware.

Throughout, `dom0$` means a command typed in a **dom0** terminal, and `vault>` means a command run **inside the vault qube's** terminal.

---

## 0. Concepts (read once)

- **RAM pool** - a Qubes storage pool backed by `tmpfs` (RAM). Anything placed here disappears on power-off and is never written to the internal disk.
- **vault** - a networkless DisposableVM used only to open the encrypted removable volume. The decryption passphrase is typed *here*, never in dom0.
- **the volume** - an encrypted (ideally VeraCrypt hidden) volume on removable media that holds your qubes at rest.
- **cycle** - one working session: `ram-pool -> load -> (disconnect) work (reconnect) -> save -> teardown -> power off`.

---

## 1. One-time preparation

### 1.1 Minimal template for the vault

Use a minimal template so the vault's trusted surface is small. Install VeraCrypt into it from the official source and **verify the signature** before use:

```
dom0$ qvm-clone <your-minimal-template> tpl-vault
# then, inside tpl-vault, download VeraCrypt from veracrypt.io, verify its PGP
# signature, install it, and shut the template down.
```

### 1.2 The vault qube (networkless DisposableVM)

```
dom0$ qvm-create --class DispVM --template <dvm-based-on-tpl-vault> --label red ghost-vault
dom0$ qvm-prefs ghost-vault netvm ''          # vault is ALWAYS offline
dom0$ qvm-prefs ghost-vault provides_network false
```

Confirm it is offline and templated correctly:

```
dom0$ qvm-prefs ghost-vault netvm     # must print nothing
dom0$ qvm-prefs ghost-vault klass     # must print: DispVM
```

### 1.3 Install the scripts into dom0

Copy the four scripts into dom0 (use the standard, deliberate Qubes method for moving a file into dom0 - e.g. `qvm-run --pass-io`), then:

```
dom0$ sudo install -m 0755 ghost-ram-pool.sh ghost-load.sh ghost-save.sh ghost-teardown.sh /usr/local/bin/
```

### 1.4 Prepare the encrypted volume (first time only)

On the removable media, create your encrypted volume with VeraCrypt (a **hidden** volume if you want deniability of existence). Inside it, create an empty directory named `qubes` - this is where backups will live:

```
vault> veracrypt --text --mount /dev/<device> /mnt/vera   # enter passphrase
vault> mkdir -p /mnt/vera/qubes
vault> veracrypt --text --dismount /mnt/vera
```

---

## 2. A working session

### 2.1 Create the RAM pool

Pick a size that fits comfortably in dom0's memory (leave headroom - the scripts refuse a size that would starve dom0):

```
dom0$ sudo ghost-ram-pool.sh 20G
```

This disables/masks swap, mounts a `noswap` tmpfs, and registers it as the pool `ghost`. Verify:

```
dom0$ qvm-pool | grep ghost
dom0$ df -h /var/lib/qubes/ghost-pool
```

### 2.2 Load your qubes into RAM

```
dom0$ sudo ghost-load.sh
```

The script will:
1. list attachable block devices - enter the one for your media (e.g. `sys-usb:sdb`);
2. wait for you to open the volume **inside the vault**:
   ```
   vault> veracrypt --text --mount /dev/<device> /mnt/vera   # enter passphrase HERE
   ```
3. list the backups it finds - enter the directory/archive to restore;
4. restore the selected qubes **into the RAM pool**, verify every volume actually landed in RAM, then dismount and detach the media.

### 2.3 Disconnect and work

Once `ghost-load.sh` reports success, the media is already detached - **physically remove it and put it away.** Your qubes now run entirely from RAM. Work normally.

### 2.4 Save back

When you are done, reconnect the media and:

```
dom0$ sudo ghost-save.sh
```

Enter the qubes to save, the device, open the volume in the vault as before; the script writes a verified, hash-manifested backup and detaches the media only after a proven dismount.

### 2.5 Teardown and power off

```
dom0$ sudo ghost-teardown.sh
```

It removes the RAM-resident qubes, scrubs logs/journald/history of their names, and asserts sterility post-conditions. If it prints that post-conditions are clean, power off:

```
dom0$ sudo poweroff
```

The tmpfs - and everything in it - is gone.

---

## 3. Verifying it actually works (acceptance tests)

Do these once, on **throwaway** test qubes, before trusting the workflow:

- [ ] After `ghost-ram-pool.sh`: create a test qube in pool `ghost`, write a marker file, confirm internal-disk usage (`sudo lvs`, `df`) does **not** grow.
- [ ] After `ghost-load.sh`: physically pull the media - the qubes keep running from RAM.
- [ ] After `ghost-save.sh`: mount the volume on a *second* machine/qube and confirm the archive + `manifest.sha256` + `.done` are present and the hash matches.
- [ ] Reboot, then re-run `ghost-load.sh` on the same backup - your marker file is intact.
- [ ] After `ghost-teardown.sh` + reboot: the pool is empty, the test qubes are gone (`qvm-ls`), and there is no residue under `/var/lib/qubes` or in `sudo lvs`.
- [ ] Confirm the passphrase was only ever typed inside `ghost-vault`, never in dom0.

---

## 4. Optional: guard against swap coming back

Swap can silently reappear (a package update, an edited `fstab`). If you have removed swap for amnesic reasons, install a small guard (a `systemd` timer with a randomized interval) that detects any active/backing swap, disables and wipes it, and raises a visible desktop notification plus a log line. See `swap-guard/` for the unit and script.

---

## 5. Troubleshooting

- **Pool creation refuses with a memory error** - the requested tmpfs size plus dom0's reserve exceeds available memory. Choose a smaller size, or increase dom0's memory allotment (this is a boot-layer change and, on measured-boot platforms, requires re-attesting `/boot`).
- **`ghost-load.sh` says the volume isn't mounted** - you must open it *inside the vault* within the wait window; re-run and open it promptly.
- **Restore aborts on a name conflict** - a qube of that name already exists; remove it (`qvm-shutdown --wait` then `qvm-remove`) or restore under a renamed name.
- **A restored volume landed outside the pool** - the script aborts and removes the restored qubes by design; check that `default_pool*` handling succeeded and retry. Report it - that is exactly the kind of leak this project wants to hear about.
