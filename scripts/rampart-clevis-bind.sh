#!/bin/bash
# Bind rampart's LUKS device to citadel + bastion tang using 2-of-2 SSS.
# Run as root on rampart. Requires clevis clevis-luks clevis-initramfs to be installed.

set -euo pipefail

echo "=== rampart Clevis Bind (2-of-2 SSS → citadel + bastion) ==="
echo

# Prompt for LUKS device
read -rp "LUKS device (e.g. /dev/nvme0n1p3): " LUKS_DEV

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

# Thumbprint instructions
echo "You need thumbprints from both Tang servers."
echo
echo "  citadel: run on citadel:"
echo "    docker exec tang jose jwk thp -i /var/db/tang/*.pub"
echo
echo "  bastion: run on bastion:"
echo "    sudo jose jwk thp -i /var/db/tang/*.pub"
echo

read -rp "citadel Tang thumbprint (10.0.0.10:1234): " CITADEL_THP
read -rp "bastion Tang thumbprint (10.0.0.20):    " BASTION_THP

CITADEL_URL="http://10.0.0.10:1234"
BASTION_URL="http://10.0.0.20"

SSS_CONFIG=$(cat <<EOF
{
  "t": 2,
  "pins": {
    "tang": [
      {"url": "${CITADEL_URL}", "thp": "${CITADEL_THP}"},
      {"url": "${BASTION_URL}", "thp": "${BASTION_THP}"}
    ]
  }
}
EOF
)

echo
echo "Binding $LUKS_DEV with 2-of-2 SSS ..."
clevis luks bind -d "$LUKS_DEV" sss "$SSS_CONFIG"

echo
echo "Verifying binding ..."
clevis luks list -d "$LUKS_DEV"

# Create LUKS header backup
BACKUP_FILE="/root/luks-header-rampart-$(date +%Y%m%d).bin"
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
echo "Both Tang servers must be reachable at boot for automatic unlock."
echo "If either is unreachable, the LUKS passphrase prompt will appear at boot."
