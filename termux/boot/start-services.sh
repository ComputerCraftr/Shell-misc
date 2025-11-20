#!/data/data/com.termux/files/usr/bin/bash
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

termux-wake-lock
# shellcheck source=/dev/null
source "${PREFIX}/etc/profile.d/start-services.sh"
