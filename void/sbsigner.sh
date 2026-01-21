#!/bin/sh
set -eu

# CONFIGURATION
: "${KEY_DEV:=/dev/mapper/luks_keystore}"
: "${LUKS_DEV:=/dev/nvme1n1p2}" # Adjust if different
: "${MNT_BASE:=/mnt/keystore}"
: "${MNT_SBCTL:=/var/lib/sbctl/keys}"

die() {
    echo "Error: $1" >&2
    exit 1
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "This script must be run as root."
    fi
}

is_mounted() {
    path="$1"
    if command -v mountpoint >/dev/null 2>&1; then
        mountpoint -q "$path"
        return $?
    fi
    if [ -r /proc/self/mounts ]; then
        awk -v p="$path" '$2 == p {found=1} END{exit found?0:1}' /proc/self/mounts
        return $?
    fi
    mount | awk -v p="$path" '$3 == p {found=1} END{exit found?0:1}'
}

update_sbsigntool() {
    echo "[+] Updating sbsigntool..."

    # Check connectivity with ping
    if ping -c 1 -W 1 -q "google.com" >/dev/null 2>&1; then
        if command -v torsocks >/dev/null 2>&1; then
            torsocks xbps-install -Syu sbsigntool || die "Failed to update sbsigntool via torsocks"
        else
            xbps-install -Syu sbsigntool || die "Failed to update sbsigntool"
        fi
    else
        echo "[!] No internet connection. Please check your network."
    fi
}

mount_keystore() {
    echo "[+] Opening LUKS and mounting keystore..."
    mkdir -p "$MNT_BASE" "$MNT_SBCTL"

    if [ ! -e "$KEY_DEV" ]; then
        cryptsetup open "$LUKS_DEV" luks_keystore || die "Failed to open LUKS"
    fi

    if ! is_mounted "$MNT_BASE"; then
        mount "$KEY_DEV" "$MNT_BASE" || die "Failed to mount keystore"
    fi

    if ! is_mounted "$MNT_SBCTL"; then
        mkdir -p "$MNT_BASE/secureboot"
        mount -o ro --bind "$MNT_BASE/secureboot" "$MNT_SBCTL" || die "Failed to mount sbctl keys"
    fi
}

unmount_keystore() {
    echo "[+] Unmounting keystore and bind mounts..."
    if is_mounted "$MNT_SBCTL"; then
        umount "$MNT_SBCTL" || echo "[!] Failed to unmount $MNT_SBCTL"
    fi
    if is_mounted "$MNT_BASE"; then
        umount "$MNT_BASE" || echo "[!] Failed to unmount $MNT_BASE"
    fi
    if [ -e "$KEY_DEV" ]; then
        cryptsetup close luks_keystore || echo "[!] luks_keystore already closed or not mapped"
    fi
}

find_sb_keys() {
    : "${KEY_FILE:=${MNT_SBCTL}/db/db.key}"
    : "${CERT_FILE:=${MNT_SBCTL}/db/db.pem}"

    [ -f "$KEY_FILE" ] || die "Missing signing key: $KEY_FILE"
    [ -f "$CERT_FILE" ] || die "Missing signing cert: $CERT_FILE"
}

sign_with_sbsigntool() {
    echo "[+] Verifying and signing kernels with sbsigntool..."

    found=0
    for f in /boot/vmlinuz*; do
        [ -e "$f" ] || continue
        if sbverify --list "$f" 2>&1 | grep -qF "No signature table present"; then
            echo "[*] Signing: $f"
            sbsign --key "$KEY_FILE" --cert "$CERT_FILE" --output "${f}.signed" "$f" || die "sbsign failed on $f"
            mv "${f}.signed" "$f" || die "Failed to replace $f"
            sbverify --list "$f" >/dev/null 2>&1 || die "sbverify failed after signing $f"
        else
            echo "[=] Already signed: $f"
        fi
        found=1
    done

    if [ "$found" -eq 1 ]; then
        echo "[✓] sbsigntool verification complete."
    else
        echo "[!] No kernel images found in /boot to verify."
    fi
}

# MAIN ENTRY
require_root

case "${1:-}" in
--mount)
    update_sbsigntool
    mount_keystore
    find_sb_keys
    sign_with_sbsigntool
    ;;
--sign)
    update_sbsigntool
    find_sb_keys
    sign_with_sbsigntool
    ;;
--unmount)
    unmount_keystore
    ;;
*)
    echo "Usage: $0 --mount | --sign | --unmount"
    exit 1
    ;;
esac
