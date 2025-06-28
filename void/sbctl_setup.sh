#!/bin/sh
set -eu

# CONFIGURATION
KEY_DEV="/dev/mapper/luks_keystore"
LUKS_DEV="/dev/nvme0n1p2" # Adjust if different
MNT_BASE="/mnt/keystore"
MNT_SBCTL="/var/lib/sbctl/keys"

die() {
    echo "Error: $1" >&2
    exit 1
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "This script must be run as root."
    fi
}

update_sbctl() {
    echo "[+] Updating sbctl..."
    if command -v torsocks >/dev/null 2>&1; then
        torsocks xbps-install -Sy sbctl || die "Failed to update sbctl via torsocks"
    else
        xbps-install -Sy sbctl || die "Failed to update sbctl"
    fi
}

mount_keystore() {
    echo "[+] Opening LUKS and mounting keystore..."
    mkdir -p "$MNT_BASE" "$MNT_SBCTL"
    if [ ! -e "$KEY_DEV" ]; then
        cryptsetup open "$LUKS_DEV" luks_keystore || die "Failed to open LUKS"
    fi
    mount "$KEY_DEV" "$MNT_BASE" || die "Failed to mount keystore"
    mount -o ro --bind "$MNT_BASE/secureboot" "$MNT_SBCTL" || die "Failed to mount sbctl keys"
}

unmount_keystore() {
    echo "[+] Unmounting all mounts tied to LUKS device..."
    umount -AR "$KEY_DEV" || echo "[!] Some mounts may have already been unmounted"
    cryptsetup close luks_keystore || echo "[!] luks_keystore already closed or not mapped"
}

run_sbctl_tasks() {
    echo "[+] Running sbctl tasks..."
    sbctl status

    found=0
    for f in /boot/vmlinuz*; do
        [ -e "$f" ] || continue
        sbctl verify "$f" || die "sbctl failed on $f"
        found=1
    done

    if [ "$found" -eq 1 ]; then
        echo "[✓] sbctl verification complete."
    else
        echo "[!] No kernel images found in /boot to verify."
    fi
}

# MAIN ENTRY
require_root

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
