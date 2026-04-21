# rampart — LUKS Client (WiFi Initramfs + 2-of-2 SSS)

rampart is an MX Linux laptop with full-disk encryption. It binds to **both** Tang servers
(citadel and bastion) using a 2-of-2 Shamir's Secret Sharing configuration: at boot, it must
reach both servers to reconstruct the LUKS key and auto-unlock.

The challenge is that rampart connects over WiFi, and `initramfs-tools` has no built-in WiFi
support. The kernel, firmware, wpa_supplicant, and a DHCP client all need to be bundled into
the initramfs image and brought up before Clevis runs. This guide walks through each piece.

**Prereqs:** citadel and bastion Tang servers must be set up and reachable before binding.

---

## Packages

```bash
sudo apt update
sudo apt install clevis clevis-luks clevis-initramfs wpasupplicant
```

---

## Identify the LUKS Device

```bash
lsblk -f
```

Look for the `crypto_LUKS` partition — on rampart this is `/dev/nvme0n1p3`.

---

## Get Tang Thumbprints

You need the public key thumbprints from both Tang servers before binding.

**citadel** (run on citadel):

```bash
docker exec tang jose jwk thp -i /var/db/tang/*.pub
```

**bastion** (run on bastion):

```bash
sudo jose jwk thp -i /var/db/tang/*.pub
```

---

## Clevis Binding (2-of-2 SSS)

Run the binding script:

```bash
sudo bash scripts/rampart-clevis-bind.sh
```

The script prompts for the LUKS device, both Tang thumbprints, performs the 2-of-2 SSS binding,
rebuilds initramfs, and creates a LUKS header backup.

### Manual binding (equivalent)

```bash
sudo clevis luks bind -d /dev/nvme0n1p3 sss '{
  "t": 2,
  "pins": {
    "tang": [
      {"url": "http://10.1.1.88:1234", "thp": "<citadel-thumbprint>"},
      {"url": "http://10.1.20.114",    "thp": "<bastion-thumbprint>"}
    ]
  }
}'
```

`"t": 2` means both pins are required — either server being unreachable causes auto-unlock to
fail and fall back to passphrase prompt.

### Verify

```bash
sudo clevis luks list -d /dev/nvme0n1p3
```

---

## WiFi initramfs Configuration

The initramfs environment has no knowledge of your WiFi network. Four things must be set up and
then baked into the initramfs image. Make all four changes before running `update-initramfs`.

### 1. wpa_supplicant credentials

Create `/etc/initramfs-tools/wpa_supplicant.conf` with mode `600` (readable only by root —
this file contains your WiFi password in plaintext):

```bash
sudo tee /etc/initramfs-tools/wpa_supplicant.conf <<'EOF'
ctrl_interface=/run/wpa_supplicant
update_config=1

network={
    ssid="YourSSID"
    psk="YourPassword"
}
EOF
sudo chmod 600 /etc/initramfs-tools/wpa_supplicant.conf
```

Replace `YourSSID` and `YourPassword` with your actual WiFi credentials.

### 2. Kernel modules

The Intel AX201 WiFi adapter requires `iwlwifi` and `iwlmvm`. These are not included in the
default `MODULES=most` set — they must be listed explicitly or the interface never appears.

Append to `/etc/initramfs-tools/modules`:

```
cfg80211
mac80211
iwlwifi
iwlmvm
```

### 3. initramfs WiFi hook

The hook script runs at `update-initramfs` time. It copies the WiFi userspace tools
(wpa_supplicant, dhclient), the config file, and the iwlwifi firmware blobs into the initramfs
image.

Copy [`scripts/wifi-hook`](../scripts/wifi-hook) to `/etc/initramfs-tools/hooks/wifi` and make
it executable:

```bash
sudo cp scripts/wifi-hook /etc/initramfs-tools/hooks/wifi
sudo chmod +x /etc/initramfs-tools/hooks/wifi
```

Contents:

```bash
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in prereqs) prereqs; exit 0;; esac

. /usr/share/initramfs-tools/hook-functions

copy_exec /sbin/wpa_supplicant
copy_exec /sbin/wpa_cli
copy_exec /sbin/dhclient

mkdir -p "${DESTDIR}/etc/initramfs-tools"
cp /etc/initramfs-tools/wpa_supplicant.conf "${DESTDIR}/etc/initramfs-tools/"

cp /lib/firmware/iwlwifi-*.ucode "${DESTDIR}/lib/firmware/" 2>/dev/null || true
cp /lib/firmware/regulatory.db   "${DESTDIR}/lib/firmware/" 2>/dev/null || true
```

### 4. initramfs premount script

The premount script runs during early boot inside initramfs, just before Clevis attempts to
contact Tang. It loads the WiFi driver stack, waits for the interface to appear (module load is
asynchronous), associates with the access point, and gets a DHCP lease.

Copy [`scripts/wifi-premount`](../scripts/wifi-premount) to
`/etc/initramfs-tools/scripts/init-premount/wifi` and make it executable:

```bash
sudo cp scripts/wifi-premount /etc/initramfs-tools/scripts/init-premount/wifi
sudo chmod +x /etc/initramfs-tools/scripts/init-premount/wifi
```

Contents:

```bash
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in prereqs) prereqs; exit 0;; esac

modprobe cfg80211
modprobe mac80211
modprobe iwlwifi
modprobe iwlmvm

# Wait up to 20s for wlan0 to appear (iwlwifi init is async)
i=0
while ! ip link show wlan0 > /dev/null 2>&1; do
    sleep 1
    i=$((i+1))
    [ $i -ge 20 ] && break
done

ip link set wlan0 up
sleep 2
wpa_supplicant -B -i wlan0 -c /etc/initramfs-tools/wpa_supplicant.conf -D nl80211
sleep 5
dhclient wlan0
```

### Rebuild initramfs

After all four changes are in place:

```bash
sudo update-initramfs -u -k all
```

---

## GRUB Configuration

Disable the Plymouth splash screen. If WiFi fails silently in initramfs, Plymouth can swallow
the fallback passphrase prompt, leaving you with a blank screen and no way to type.

Edit `/etc/default/grub`:

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
```

Then:

```bash
sudo update-grub
```

---

## Post-Boot NetworkManager Fix

When the initramfs pivots to the real root filesystem, the `wpa_supplicant` process started in
early boot **stays alive**. It holds the `wlan0` interface, which prevents NetworkManager from
associating with any network. This means WiFi appears to work at the OS level (interface exists)
but no connection is established.

The fix is to kill the initramfs `wpa_supplicant` and restart NetworkManager once you log in.
This is automated via a KDE Plasma autostart script.

### Autostart script

Create `~/.config/autostart-scripts/fix-wpa.sh`:

```bash
#!/bin/sh
sudo killall wpa_supplicant
sudo systemctl restart NetworkManager
```

### Passwordless sudoers rule

The autostart script needs root. Add a rule so it can run without a password prompt:

```bash
sudo tee /etc/sudoers.d/fix-wpa <<'EOF'
<your-username> ALL=(ALL) NOPASSWD: /usr/bin/killall wpa_supplicant, /usr/bin/systemctl restart NetworkManager
EOF
```

Replace `<your-username>` with your actual login name.

KDE Plasma will run the autostart script at login. After it executes, NetworkManager takes
control of `wlan0` and connects normally.

> **Non-KDE environments:** place the same commands in any session startup hook (e.g.
> `~/.xprofile`, a systemd user unit with `After=graphical-session.target`), or trigger it with
> a udev rule on `wlan0` coming up.

---

## Verification

```bash
# Tang servers reachable
curl http://10.1.1.88:1234/adv
curl http://10.1.20.114/adv

# Clevis binding present with SSS config
sudo clevis luks list -d /dev/nvme0n1p3

# Both key slots active
sudo cryptsetup luksDump /dev/nvme0n1p3 | grep -E "Keyslot|Key Slot"

# Full boot test (both Tang servers running): reboot → auto-unlocks
sudo systemctl reboot

# Resilience test: stop one Tang server → rampart should prompt for passphrase
```

---

## Quick Reference

| Task | Command |
|---|---|
| Check citadel Tang | `curl http://10.1.1.88:1234/adv` |
| Check bastion Tang | `curl http://10.1.20.114/adv` |
| List clevis bindings | `sudo clevis luks list -d /dev/nvme0n1p3` |
| Rebuild initramfs | `sudo update-initramfs -u -k all` |
| Manual NM fix | `sudo killall wpa_supplicant && sudo systemctl restart NetworkManager` |
| Get Tang thumbprint | `sudo jose jwk thp -i /var/db/tang/*.pub` |
