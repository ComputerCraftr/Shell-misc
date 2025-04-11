#!/bin/sh
# /usr/local/bin/tether-bridge.sh

CURL="/usr/local/bin/curl"
TIMEOUT=60 # total time to wait in seconds
INTERVAL=1 # poll interval in seconds

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
    echo "Warning: /etc/.tether-env.conf not found. Proceeding with default values." >&2
fi

# Set defaults in case values aren't provided.
: "${INTERFACE:=ue0}"
: "${BRIDGE:=bridge0}"
: "${DISCORD_MENTION:=@everyone}"

# Ensure the webhook URL is defined.
if [ -z "${WEBHOOK_URL:-}" ]; then
    echo "Error: WEBHOOK_URL is not defined in /etc/.tether-env.conf." >&2
    exit 1
fi

# Add the tethered interface to the bridge if necessary.
if ! ifconfig "$BRIDGE" | grep -q "$INTERFACE"; then
    ifconfig "$BRIDGE" addm "$INTERFACE"
fi

# Bring up the new interface explicitly.
ifconfig "$INTERFACE" up

# Restart the DHCP client service for the bridge to force a DHCP lease renewal.
echo "Restarting dhclient service on ${BRIDGE}..."
service dhclient restart "$BRIDGE" || true

# Poll for an IP address (both IPv4 and IPv6) with a timeout.
echo "Polling for IPv4 and IPv6 addresses on ${BRIDGE}..."
SECONDS_WAITED=0
IPV4=""
IPV6=""
while [ "$SECONDS_WAITED" -lt "$TIMEOUT" ]; do
    # Get the first IPv4 address (skip IPv6)
    IPV4=$(ifconfig "$BRIDGE" | awk '/inet / { print $2; exit }')
    # Get the first non-link-local IPv6 address (if any)
    IPV6=$(ifconfig "$BRIDGE" | awk '/inet6 / && $2 !~ /^fe80/ { print $2; exit }')
    if [ -n "$IPV4" ] || [ -n "$IPV6" ]; then
        break
    fi
    sleep "$INTERVAL"
    SECONDS_WAITED=$((SECONDS_WAITED + INTERVAL))
done

if [ -z "$IPV4" ] && [ -z "$IPV6" ]; then
    echo "Error: No IPv4 or IPv6 address acquired on ${BRIDGE} after ${TIMEOUT} seconds." >&2
    exit 1
fi

# Build the IP info string for the Discord message.
IP_INFO=""
if [ -n "$IPV4" ]; then
    IP_INFO="IPv4: \`${IPV4}\`"
fi
if [ -n "$IPV6" ]; then
    if [ -n "$IP_INFO" ]; then
        IP_INFO="$IP_INFO, "
    fi
    IP_INFO="${IP_INFO}IPv6: \`${IPV6}\`"
fi

# Send a Discord webhook message if an address was acquired.
echo "Sending Discord notification with IP info: $IP_INFO"
if ! $CURL -s -X POST -H "Content-Type: application/json" \
    -d "{\"content\": \"${DISCORD_MENTION} Tethered via ${INTERFACE}: ${BRIDGE} acquired ${IP_INFO}\"}" \
    "$WEBHOOK_URL"; then
    echo "Error: Failed to send Discord notification." >&2
    exit 1
fi

echo "Notification sent successfully."
