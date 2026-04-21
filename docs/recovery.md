# Key Rotation, Header Backup & Recovery

---

## LUKS Header Backup

The LUKS header contains the key slots — including all Clevis bindings. If the header is
corrupted, the disk is unrecoverable even with the correct passphrase. Back it up immediately
after setup and after every re-binding.

### Create a backup

```bash
# Replace /dev/sda3 with your LUKS device and choose a meaningful filename
sudo cryptsetup luksHeaderBackup /dev/sda3 \
    --header-backup-file luks-header-$(hostname)-$(date +%Y%m%d).bin
```

### Store it securely

The header backup alone does not unlock your disk (the passphrase or a Clevis slot is still
needed), but it should still be stored somewhere other than the encrypted machine itself — it
won't help you if it's on the disk you can't mount.

```bash
scp luks-header-*.bin user@secure-host:/backups/luks/
```

Good options: a separate encrypted backup server, an offline USB drive stored physically secure,
a password manager that accepts attachments.

---

## Manual Unlock (Tang Unreachable)

If Tang servers are unreachable and the machine is rebooting, Clevis will fail silently and the
system will fall back to a LUKS passphrase prompt.

- **bastion:** Dropbear starts on port 2222. SSH in with `ssh root@10.0.0.20 -p 2222`, then
  run `cryptroot-unlock` and enter the passphrase.
- **rampart:** A passphrase prompt appears at boot (ensure Plymouth is disabled — see
  [rampart.md](rampart.md)). Type the LUKS passphrase to continue.

The LUKS passphrase set during installation remains valid permanently alongside the Clevis slot.
Clevis adds a key slot; it does not replace the passphrase slot.

---

## Tang Key Rotation

Tang keys should be rotated if you suspect compromise, or on a regular schedule (annually is
reasonable). After rotation, all Clevis bindings on all clients must be regenerated — the old
binding will no longer work because it references the old public key.

### On the Tang server (citadel via Docker)

```bash
# Generate a new key pair alongside the existing one
docker exec tang tangd-keygen /var/db/tang

# Reload Tang so it advertises both keys during the transition window
docker restart tang
```

For bastion's native Tang:

```bash
sudo tangd-keygen /var/db/tang
sudo systemctl reload tangd.socket
```

### On each LUKS client

Find the Clevis slot number:

```bash
sudo clevis luks list -d /dev/sda3
```

Regenerate the binding (this adds a new slot using the new Tang key):

```bash
sudo clevis luks regen -d /dev/sda3 -s <slot-number>
```

Verify the new binding works:

```bash
sudo clevis luks unlock -d /dev/sda3 -n test_unlock
sudo cryptsetup close test_unlock
```

Rebuild initramfs to pick up any updated metadata:

```bash
sudo update-initramfs -u -k all
```

### Remove the old Tang key (after all clients are rebound)

```bash
# On citadel:
docker exec tang ls /var/db/tang/
# Identify the old key by its older modification time
docker exec tang rm /var/db/tang/<old-key-id>.jwk /var/db/tang/<old-key-id>.jwk.pub
docker restart tang

# On bastion:
sudo ls -lt /var/db/tang/
sudo rm /var/db/tang/<old-key-id>.jwk /var/db/tang/<old-key-id>.jwk.pub
sudo systemctl reload tangd.socket
```

> Do not remove the old Tang key until every client has been successfully rebound and tested.
> If you remove it first and a client hasn't been rebound, that client's old Clevis slot becomes
> permanently invalid — you'd need to fall back to the passphrase slot to re-bind.

---

## LUKS Header Restore

If the LUKS header on a device becomes corrupted but you have a backup:

```bash
sudo cryptsetup luksHeaderRestore /dev/sda3 \
    --header-backup-file luks-header-<hostname>-<date>.bin
```

This restores the header to the state at the time of the backup, including all key slots active
at that time. If Clevis bindings were added after the backup was made, they will not be present
in the restored header — you will need to rebind.

---

## Worst Case: No Backup, No Passphrase

If the LUKS header is destroyed, the passphrase is lost, and all Clevis slots are gone:

**The data is irrecoverable.** There is no backdoor. This is the intended property of LUKS.

Mitigation:
- Take a header backup immediately after every binding operation
- Store the LUKS passphrase in a password manager (not on the encrypted machine)
- Test recovery from backup at least once after setup
