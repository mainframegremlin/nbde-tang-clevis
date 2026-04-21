#!/bin/bash
# Bind bastion's LUKS device to citadel tang (1-of-1).
# Run as root on bastion. Requires clevis clevis-luks clevis-initramfs to be installed.

set -euo pipefail

echo "=== bastion Clevis Bind (1-of-1 → citadel) ==="
echo

# Prompt for LUKS device
read -rp "LUKS device (e.g. /dev/sda3): " LUKS_DEV

# Validate device exists
if [ ! -b "$LUKS_DEV" ]; then
    echo "Error: $LUKS_DEV is not a block device." >&2
    exit 1
fi

# Show current LUKS info for confirmation
echo
echo "Current LUKS slots on $LUKS_DEV:"
cryptsetup luksDump "$LUKS_DEV" | grep -E "Keyslot|Key Slot" || true
echo

# Prompt for citadel thumbprint
echo "Get the citadel thumbprint by running on citadel:"
echo "  docker exec tang jose jwk thp -i /var/db/tang/*.pub"
echo
read -rp "citadel Tang thumbprint: " CITADEL_THP

CITADEL_URL="http://10.1.1.88:1234"

echo
echo "Binding $LUKS_DEV to $CITADEL_URL ..."
clevis luks bind -d "$LUKS_DEV" tang \
    "{\"url\":\"${CITADEL_URL}\",\"thp\":\"${CITADEL_THP}\"}"

echo
echo "Verifying binding ..."
clevis luks list -d "$LUKS_DEV"

# Create LUKS header backup
BACKUP_FILE="/root/luks-header-bastion-$(date +%Y%m%d).bin"
echo
echo "Creating LUKS header backup at $BACKUP_FILE ..."
cryptsetup luksHeaderBackup "$LUKS_DEV" --header-backup-file "$BACKUP_FILE"
echo "Backup created. Copy it off-machine:"
echo "  scp $BACKUP_FILE user@secure-host:/backups/luks/"

echo
echo "Rebuilding initramfs ..."
update-initramfs -u -k all

echo
echo "Done. Reboot to test auto-unlock."
echo "If citadel is unreachable, SSH to port 2222 and run: cryptroot-unlock"
