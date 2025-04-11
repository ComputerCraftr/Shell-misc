#!/bin/sh
# /usr/local/bin/tether-bridge.sh

# Exit on errors and undefined variables.
set -eu

# Ensure the script is run as root.
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root. Please use sudo or run as root." >&2
    exit 1
fi

# Source the environment file if it exists.
if [ -f /etc/.tether-env.conf ]; then
    . /etc/.tether-env.conf
else
    echo "Warning: tether-env.conf not found. Proceeding with default values." >&2
fi

# Set defaults in case values aren't provided.
: "${INTERFACE:=ue0}"
: "${BRIDGE:=bridge0}"
: "${DISCORD_MENTION:=@everyone}"

# Ensure the webhook URL is defined.
if [ -z "${WEBHOOK_URL:-}" ]; then
    echo "Error: WEBHOOK_URL is not defined in tether-env.conf." >&2
    exit 1
fi

# Add the tethered interface to the bridge if not already added.
if ! ifconfig "$BRIDGE" | grep -q "$INTERFACE"; then
    ifconfig "$BRIDGE" addm "$INTERFACE"
fi

# Bring up the new interface explicitly.
ifconfig "$INTERFACE" up

# Bring up the bridge explicitly (if not already up).
ifconfig "$BRIDGE" up

# Restart dhclient service to acquire new IP address.
echo "Restarting dhclient service to acquire IP address..."
service dhclient restart "$BRIDGE" || true

# Restart routing service to update default routes.
echo "Restarting routing service to update routes..."
service routing restart || true

# Wait for a few seconds to allow the network config to settle.
sleep 3

# Fetch the IPv4 address from the bridge.
IP=$(ifconfig "$BRIDGE" | awk '/inet / { print $2 }')

if [ -z "$IP" ]; then
    echo "Error: No IP address acquired on ${BRIDGE}." >&2
    exit 1
fi

# Send a Discord webhook message if an IP was acquired.
echo "Sending Discord notification with IP: $IP"
if ! curl -s -X POST -H "Content-Type: application/json" \
    -d "{\"content\": \"${DISCORD_MENTION} Tethered via ${INTERFACE}: ${BRIDGE} has IP ${IP}\"}" \
    "$WEBHOOK_URL"; then
    echo "Error: Failed to send Discord notification." >&2
    exit 1
fi
