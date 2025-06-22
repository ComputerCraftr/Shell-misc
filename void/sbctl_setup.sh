#!/bin/sh
set -eu

# CONFIGURATION
KEY_DEV="/dev/mapper/luks_keystore"
LUKS_SRC="/dev/nvme0n1p2"  # Adjust if different
MNT_BASE="/mnt/keystore"
MNT_SBCTL="/var/lib/sbctl/keys"

die() {
    echo "Error: $1" >&2
    exit 1
}

update_sbctl() {
    echo "[+] Updating sbctl..."
    xbps-install -Sy sbctl || die "Failed to update sbctl"
}

mount_keystore() {
    echo "[+] Opening LUKS and mounting keystore..."
    if [ ! -e "$KEY_DEV" ]; then
        cryptsetup open "$LUKS_SRC" luks_keystore || die "Failed to open LUKS"
    fi
    mount "$KEY_DEV" "$MNT_BASE"
    mount -o ro --bind "$MNT_BASE/secureboot" "$MNT_SBCTL"
}

unmount_keystore() {
    echo "[+] Unmounting all mounts tied to LUKS device..."
    umount -AR "$KEY_DEV" || echo "[!] Some mounts may have already been unmounted"
    cryptsetup close luks_keystore || echo "[!] luks_keystore already closed or not mapped"
}

run_sbctl_tasks() {
    echo "[+] Running sbctl tasks..."
    sbctl status
    sbctl verify
    sbctl sign-all
    echo "[✓] sbctl signing complete."
}

# MAIN ENTRY
case "${1:-}" in
    --mount)
        update_sbctl
        mount_keystore
        run_sbctl_tasks
        ;;
    --unmount)
        unmount_keystore
        ;;
    *)
        echo "Usage: $0 --mount | --unmount"
        exit 1
        ;;
esac

