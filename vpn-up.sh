#!/bin/sh
# /usr/local/bin/vpn-up.sh

# If not running under full Bash mode (or if in POSIX compatibility mode), re-execute using full Bash.
if [ -z "${BASH_VERSION:-}" ]; then
    # Ensure a good PATH so that bash and related tools are found.
    export PATH="/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin:/usr/local/sbin"
    BASH_PATH=$(command -v bash)
    if [ -z "$BASH_PATH" ]; then
        logger -t vpn-up -p daemon.err "bash not found in PATH, cannot run script."
        exit 1
    fi
    exec "$BASH_PATH" "$0" "$@"
fi

# Disable POSIX mode (if it was enabled) so that Bash-specific features become available.
set +o posix

# Redirect all stdout and stderr to syslog (for devd visibility).
exec 1> >(logger -t vpn-up -p daemon.notice) 2> >(logger -t vpn-up -p daemon.err)

# Enable strict error handling.
set -euo pipefail
IFS=$'\n\t'

# Ensure the script is run as root.
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root. Exiting."
    exit 1
fi

# Configuration: timeouts, intervals, and retry settings.
OVPN_TEMPL=/usr/local/etc/openvpn/pia_template.ovpn
OVPN_FILE=/usr/local/etc/openvpn/pia.ovpn
OVPN_AUTH=/usr/local/etc/openvpn/.vpn-creds
OVPN_PROXY_AUTH=/usr/local/etc/openvpn/.proxy-creds
OVPN_PROXY_PORT=$(tail -n 1 /usr/local/etc/openvpn/.proxy-creds)
IP_TIMEOUT=120     # Total seconds to wait for an IP address.
GATEWAY_TIMEOUT=30 # Total seconds to wait for default gateway(s).
INTERVAL=1         # Polling interval in seconds.
MAX_RETRIES=10     # Maximum number of retries.
RETRY_COUNT=${RETRY_COUNT:-0}

# Dynamically determine the location of curl.
CURL=$(command -v curl)
if [ -z "$CURL" ]; then
    echo "Error: curl not found in PATH. Exiting."
    exit 1
fi

# The interface name is provided as the first argument (from devd).
if [ -z "${INTERFACE:-}" ] && [ "$#" -gt 0 ]; then
    export INTERFACE="$1"
elif [ "$#" -gt 0 ]; then
    echo "Warning: INTERFACE is already set to '${INTERFACE:-}'. Ignoring argument '$1'."
else
    echo "Error: INTERFACE is not set and no argument was provided. Exiting."
    exit 1
fi

# Ensure the OpenVPN template file exists.
if [ ! -f "$OVPN_TEMPL" ]; then
    echo "Error: OpenVPN template file $OVPN_TEMPL does not exist."
    exit 1
fi

# Error handler: log a message and, if under MAX_RETRIES, re-executes the script with the original "$@".
handle_error() {
    echo "Error encountered at line $1 (retry $RETRY_COUNT of $MAX_RETRIES)"
    if [ "$RETRY_COUNT" -lt "$MAX_RETRIES" ]; then
        export RETRY_COUNT=$((RETRY_COUNT + 1))
        echo "Retrying in 2 seconds... (Retry $RETRY_COUNT of $MAX_RETRIES)"
        sleep 2
        exec "$0" "$INTERFACE"
    else
        echo "Maximum retries reached. Exiting."
        exit 1
    fi
}

# Trap any error (nonzero exit status) and call handle_error.
trap 'handle_error $LINENO' ERR

# Load environment variables from /usr/local/etc/.gateway-env.conf if it exists.
if [ -f /usr/local/etc/.gateway-env.conf ]; then
    # Using "source ... || false" to ensure a failure can be caught for retries.
    source /usr/local/etc/.gateway-env.conf || false
else
    echo "Warning: /usr/local/etc/.gateway-env.conf not found, proceeding with default values."
fi

# Set defaults for the Discord notification if not defined.
: "${DISCORD_MENTION:=@everyone}"

# Ensure the webhook URL is defined.
if [ -z "${WEBHOOK_URL:-}" ]; then
    echo "Error: WEBHOOK_URL must be set in /usr/local/etc/.gateway-env.conf."
    exit 1
fi

echo "Starting VPN setup for interface: $INTERFACE"

# Verify the specified interface exists. Sometimes it isn't available immediately.
if ! ifconfig "$INTERFACE" >/dev/null 2>&1; then
    echo "Error: Interface $INTERFACE does not exist."
    false
fi

# Bring the interface up.
ifconfig "$INTERFACE" up

# Restart the DHCP client service on the interface.
echo "Restarting DHCP client on interface $INTERFACE..."
service dhclient restart "$INTERFACE"

# Poll for an IPv4 or non-link-local IPv6 address on the interface.
SECONDS_WAITED=0
IPV4=""
IPV6=""

while [ "$SECONDS_WAITED" -lt "$IP_TIMEOUT" ]; do
    IPV4=$(ifconfig "$INTERFACE" | awk '/inet / {print $2; exit}')
    IPV6=$(ifconfig "$INTERFACE" | awk '/inet6 / && $2 !~ /^fe80/ {print $2; exit}')
    if [ -n "$IPV4" ] || [ -n "$IPV6" ]; then
        break
    fi
    sleep "$INTERVAL"
    SECONDS_WAITED=$((SECONDS_WAITED + INTERVAL))
done

if [ -z "$IPV4" ] && [ -z "$IPV6" ]; then
    echo "Error: Failed to acquire an IP address on interface $INTERFACE after $IP_TIMEOUT seconds."
    false
fi

# Poll for default gateways for IPv4 and IPv6 (using netstat)
SECONDS_WAITED=0
DEFAULT_GW_IPV4=""
DEFAULT_GW_IPV6=""

while [ "$SECONDS_WAITED" -lt "$GATEWAY_TIMEOUT" ]; do
    # For IPv4, extract the default gateway from netstat.
    DEFAULT_GW_IPV4=$(netstat -rn -f inet 2>/dev/null | awk '$1 == "default" {print $2; exit}')
    # For IPv6, extract the default gateway from netstat (ignoring link-local).
    DEFAULT_GW_IPV6=$(netstat -rn -f inet6 2>/dev/null | awk '$1 == "default" {print $2; exit}')
    if [ -n "$DEFAULT_GW_IPV4" ]; then
        break
    fi
    sleep "$INTERVAL"
    SECONDS_WAITED=$((SECONDS_WAITED + INTERVAL))
done

if [ -z "$DEFAULT_GW_IPV4" ]; then
    echo "Error: Failed to acquire a default gateway on interface $INTERFACE after $GATEWAY_TIMEOUT seconds."
    false
fi

# Update the OpenVPN configuration.
sed -e "s|__AUTH_FILE__|$OVPN_AUTH|" \
    -e "s|__PROXY_STRING__|${DEFAULT_GW_IPV4} ${OVPN_PROXY_PORT}|" \
    -e "s|__PROXY_AUTH_FILE__|$OVPN_PROXY_AUTH|" \
    "$OVPN_TEMPL" >"$OVPN_FILE"

# Restart ipfw, OpenVPN, and DHCP services.
echo "Restarting ipfw, OpenVPN client, and DHCP server..."
service ipfw restart
service openvpn restart
service kea restart

# Build the IP information string.
DISCORD_MESSAGE="\`${INTERFACE}\` is up, acquired IP address(es):"
[ -n "$IPV4" ] && DISCORD_MESSAGE="${DISCORD_MESSAGE}\`\`\`$IPV4\`\`\`"
[ -n "$IPV6" ] && DISCORD_MESSAGE="${DISCORD_MESSAGE}\`\`\`$IPV6\`\`\`"

# Build the default gateway information string.
if [ -n "$DEFAULT_GW_IPV4" ] || [ -n "$DEFAULT_GW_IPV6" ]; then
    DISCORD_MESSAGE="${DISCORD_MESSAGE}\nDefault Gateway(s):"
    [ -n "$DEFAULT_GW_IPV4" ] && DISCORD_MESSAGE="${DISCORD_MESSAGE}\`\`\`$DEFAULT_GW_IPV4\`\`\`"
    [ -n "$DEFAULT_GW_IPV6" ] && DISCORD_MESSAGE="${DISCORD_MESSAGE}\`\`\`$DEFAULT_GW_IPV6\`\`\`"
fi

# Build the external IP information string.
EXT_IP=$("$CURL" https://ifconfig.me 2>/dev/null || true)
if [ -n "$EXT_IP" ]; then
    DISCORD_MESSAGE="${DISCORD_MESSAGE}\nExternal IP:\`\`\`$EXT_IP\`\`\`"
fi

# Send the Discord notification.
echo "Sending Discord notification with the following message: $DISCORD_MESSAGE"
"$CURL" -s -X POST -H "Content-Type: application/json" \
    -d "{\"content\": \"${DISCORD_MENTION} ${DISCORD_MESSAGE}\"}" \
    "$WEBHOOK_URL"

echo "Notification sent successfully."
