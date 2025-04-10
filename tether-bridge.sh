#!/bin/sh
# /usr/local/bin/tether-bridge.sh

# Exit on errors and undefined variables.
set -eu

# Ensure the script is run as root.
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo or run as root user."
    exit 1
fi

# Source the environment file if it exists.
[ -f /etc/.tether-env.conf ] && . /etc/.tether-env.conf

# Set defaults just in case.
: "${INTERFACE:=ue0}"
: "${BRIDGE:=bridge0}"
: "${DISCORD_MENTION:=@everyone}"

# Ensure the webhook URL is defined.
[ -n "$WEBHOOK_URL" ] || exit 1

# Add the tethered interface to the bridge if it's not already a member.
if ! ifconfig "$BRIDGE" | grep -q "$INTERFACE"; then
    ifconfig "$BRIDGE" addm "$INTERFACE"
fi

# Wait a few seconds for the DHCP (via SYNCDHCP on bridge0) to get an IP.
sleep 15

# Fetch the IP address from bridge0.
IP=$(ifconfig "$BRIDGE" | awk '/inet / { print $2 }')

# Send a Discord webhook message if an IP was found.
if [ -n "$IP" ]; then
    curl -s -X POST -H "Content-Type: application/json" \
        -d "{\"content\": \"${DISCORD_MENTION} Tethered via ${INTERFACE}: ${BRIDGE} has IP ${IP}\"}" \
        "$WEBHOOK_URL"
fi
