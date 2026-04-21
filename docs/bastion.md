# bastion — Tang Server + LUKS Client

bastion (Debian 13, `10.0.0.20`) plays two roles:

1. **Tang server** — it serves key material to rampart for its 2-of-2 SSS unlock
2. **LUKS client** — its own root disk is encrypted and auto-unlocks via citadel's Tang

Because a machine can't depend on itself to boot, bastion binds to citadel Tang only (1-of-1).
If citadel is unreachable, bastion falls back to Dropbear: a minimal SSH server that runs inside
initramfs, letting you SSH in and type the LUKS passphrase manually before the OS starts.

---

## Part 1 — Tang Server Setup

### Install Tang

```bash
sudo apt install tang jose
```

### Configure the systemd socket

By default, Tang listens only on localhost. To expose it on the LAN on port 80:

```bash
sudo mkdir -p /etc/systemd/system/tangd.socket.d
sudo tee /etc/systemd/system/tangd.socket.d/port.conf <<'EOF'
[Socket]
ListenStream=
ListenStream=80
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now tangd.socket
```

### Retrieve the thumbprint

```bash
sudo jose jwk thp -i /var/db/tang/*.pub
```

Record this value — rampart needs it when binding. Verify the server is reachable:

```bash
curl http://10.0.0.20/adv
```

### Firewall

Allow inbound port 80 TCP from rampart's IP:

```bash
sudo ufw allow from <rampart-ip> to any port 80 proto tcp
sudo ufw reload
```

---

## Part 2 — LUKS Client Setup (Clevis)

### Install packages

```bash
sudo apt update
sudo apt install clevis clevis-luks clevis-initramfs
```

### Identify your LUKS device

```bash
lsblk -f
```

Look for the partition with `crypto_LUKS` type — commonly `/dev/sda3` or `/dev/nvme0n1p3`.

### Get the citadel thumbprint

On citadel:

```bash
docker exec tang jose jwk thp -i /var/db/tang/*.pub
```

### Bind with the script

```bash
sudo bash scripts/bastion-clevis-bind.sh
```

The script prompts for the LUKS device path and the citadel Tang thumbprint, performs the
binding, rebuilds initramfs, and creates a LUKS header backup.

### Manual binding (equivalent)

```bash
sudo clevis luks bind -d /dev/sda3 tang \
  '{"url":"http://10.0.0.10:1234","thp":"<citadel-thumbprint>"}'
```

You will be prompted for the existing LUKS passphrase once to add the new key slot.

### Verify the binding

```bash
sudo clevis luks list -d /dev/sda3
sudo cryptsetup luksDump /dev/sda3 | grep -E "Keyslot|Key Slot"
```

You should see both a passphrase slot and a clevis slot active.

### Rebuild initramfs

```bash
sudo update-initramfs -u -k all
```

---

## Part 3 — Dropbear SSH Fallback

Dropbear is a lightweight SSH server that can run inside initramfs — the minimal Linux
environment active before the root filesystem is mounted. If citadel is unreachable and clevis
can't auto-unlock, bastion halts at the LUKS prompt. Dropbear lets you SSH in on port 2222,
type the passphrase, and finish the boot.

### Install

```bash
sudo apt install dropbear-initramfs
```

### Add your SSH public key

```bash
sudo vim /etc/dropbear/initramfs/authorized_keys
```

Paste the public key from your management workstation (e.g. `~/.ssh/id_ed25519.pub`).

### Configure Dropbear options

```bash
sudo vim /etc/dropbear/initramfs/dropbear.conf
```

Set:

```
DROPBEAR_OPTIONS="-I 300 -j -k -p 2222 -s"
```

| Flag | Meaning |
|---|---|
| `-I 300` | Idle timeout: disconnect after 300s of inactivity (reconnect any time, server still waits) |
| `-j` | Disable local port forwarding |
| `-k` | Disable remote port forwarding |
| `-p 2222` | Listen on port 2222 |
| `-s` | Disable password auth (key-only) |

### Set the network interface

```bash
sudo vim /etc/initramfs-tools/initramfs.conf
```

Add or ensure this line is present:

```
DEVICE=eno1
```

No `IP=` line is needed — UniFi DHCP provides a static lease for bastion's MAC address, so the
initramfs gets the correct IP automatically.

### Rebuild initramfs

```bash
sudo update-initramfs -u
```

---

## Unlocking Manually via Dropbear

After a reboot where citadel is unreachable, bastion waits at the initramfs LUKS prompt.
SSH in from another machine:

```bash
ssh root@10.0.0.20 -p 2222
```

Then unlock:

```bash
cryptroot-unlock
```

Enter the LUKS passphrase. Bastion finishes booting and Dropbear exits — normal sshd on port 22
takes over.

### Recommended SSH client config

Add this to `~/.ssh/config` on your management workstation to avoid host-key conflicts between
the initramfs Dropbear host key and the normal sshd host key:

```
Host bastion-unlock
    HostName 10.0.0.20
    User root
    Port 2222
    IdentityFile ~/.ssh/id_ed25519
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
```

Then unlock with:

```bash
ssh bastion-unlock
cryptroot-unlock
```

> **Note:** `StrictHostKeyChecking no` / `UserKnownHostsFile /dev/null` are safe here because
> this alias is specifically scoped to port 2222, which only exists during early boot. The
> normal `bastion` alias at port 22 should keep strict checking enabled.

---

## Verification Checklist

```bash
# Tang server responding
curl http://10.0.0.20/adv

# Clevis binding present
sudo clevis luks list -d /dev/sda3

# Both key slots active (passphrase + clevis)
sudo cryptsetup luksDump /dev/sda3 | grep -E "Keyslot|Key Slot"

# Full boot test: reboot with citadel running → should auto-unlock
sudo systemctl reboot

# Fallback test: stop citadel tang, reboot → should expose Dropbear on :2222
```

---

## Quick Reference

| Task | Command |
|---|---|
| Check citadel Tang health | `curl http://10.0.0.10:1234/adv` |
| Check bastion Tang health | `curl http://10.0.0.20/adv` |
| List clevis bindings | `sudo clevis luks list -d /dev/sda3` |
| Rebuild initramfs | `sudo update-initramfs -u -k all` |
| Get Tang thumbprint | `sudo jose jwk thp -i /var/db/tang/*.pub` |
| View Tang logs | `journalctl -u tangd.socket -u 'tangd@*' -f` |
| SSH unlock (fallback) | `ssh root@10.0.0.20 -p 2222` then `cryptroot-unlock` |
