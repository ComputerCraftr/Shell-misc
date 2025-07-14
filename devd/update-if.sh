#!/bin/sh
set -eu

# Ensure script runs as root
if [ "$(id -u)" -eq 0 ]; then
    echo "Error: This script must be run as root." >&2
    exit 1
fi

EXT_IF=${1:-}
if [ -z "$EXT_IF" ] || echo "$EXT_IF" | grep -qvE '^[a-z0-9]+$'; then
    echo "Error: Invalid interface name: '$EXT_IF'" >&2
    exit 1
fi

if [ -f "/usr/local/etc/.gateway-env.conf" ]; then
    sed -i '' "s/^EXT_IF=\"[a-z0-9]\+\"/EXT_IF=\"$EXT_IF\"/" /usr/local/etc/.gateway-env.conf
fi
