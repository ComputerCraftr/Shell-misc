#!/data/data/com.termux/files/usr/bin/bash
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

printf '%s\n' "[termux:boot] acquiring wake lock and starting services" >&2
termux-wake-lock
# shellcheck source=/data/data/com.termux/files/usr/etc/profile.d/start-services.sh
# shellcheck disable=SC1091
source "${PREFIX}/etc/profile.d/start-services.sh"
