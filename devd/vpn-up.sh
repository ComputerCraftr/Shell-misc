#!/bin/sh
# /usr/local/bin/vpn-up.sh
SCRIPT_NAME=vpn-up

# Define logging wrapper functions.
log() { logger -t "$SCRIPT_NAME" -p daemon.notice "$*"; }
log_err() { logger -t "$SCRIPT_NAME" -p daemon.err "$*"; }

# If not running under full Bash mode (or if in POSIX compatibility mode), re-execute using full Bash.
if [ -z "${BASH_VERSION:-}" ]; then
    # Ensure a good PATH so that bash and related tools are found.
    export PATH="/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin:/usr/local/sbin"
    BASH_PATH=$(command -v bash)
    if [ -z "$BASH_PATH" ]; then
        log_err "bash not found in PATH, cannot run script."
        exit 1
    fi
    exec "$BASH_PATH" "$0" "$@"
fi

# Disable POSIX mode (if it was enabled) so that Bash-specific features and strict error handling become available.
set +o posix
set -euo pipefail
IFS=$'\n\t'

# Ensure the script is run as root.
if [ "$(id -u)" -ne 0 ]; then
    log_err "Error: This script must be run as root. Exiting."
    exit 1
fi

# Handle interface from either $EXT_IF (retry) or $1 (first run).
if [ -n "${EXT_IF:-}" ]; then
    # Already exported by a retry
    if [ "$#" -gt 0 ] && [ "$1" != "$EXT_IF" ]; then
        log "Warning: EXT_IF is already set to '$EXT_IF'; ignoring argument '$1'."
    fi
elif [ "$#" -gt 0 ]; then
    export EXT_IF="$1"
else
    log_err "Error: EXT_IF is not set and no argument was provided. Exiting."
    exit 1
fi

# Define LOCKFILE and set RETRY_COUNT from last argument.
LOCKFILE="/var/run/${SCRIPT_NAME}.${EXT_IF}.lock"
RETRY_COUNT=${2:-0}

# On first execution, ensure single instance using a simple PID-based lockfile.
if [ "$RETRY_COUNT" -eq 0 ]; then
    if [ -e "$LOCKFILE" ]; then
        OLDPID=$(cat "$LOCKFILE" 2>/dev/null || echo "")
        if [ -n "$OLDPID" ] && kill -0 "$OLDPID" 2>/dev/null; then
            log_err "Lockfile exists and process $OLDPID is still running. Exiting."
            exit 0
        fi
        log "Stale lockfile found. Removing..."
        rm -f "$LOCKFILE"
    fi

    trap 'rm -f "$LOCKFILE"; exec 1>&- 2>&-' INT TERM HUP EXIT
    echo $$ >"$LOCKFILE"

    exec 1> >(logger -t "$SCRIPT_NAME" -p daemon.notice) \
    2> >(logger -t "$SCRIPT_NAME" -p daemon.err)
fi

# Configuration: timeouts, intervals, and retry settings.
OVPN_TEMPL=/usr/local/etc/openvpn/pia_template.ovpn
OVPN_FILE=/usr/local/etc/openvpn/pia.ovpn
OVPN_AUTH=/usr/local/etc/openvpn/.vpn-creds
OVPN_PROXY_AUTH=/usr/local/etc/openvpn/.proxy-creds
OVPN_PROXY_PORT=$(tail -n 1 "$OVPN_PROXY_AUTH" || echo 0)
TUN_IF=$(awk '/dev / {print $2}' <"$OVPN_TEMPL")
IP_TIMEOUT=10      # Total seconds to wait for an IP address.
GATEWAY_TIMEOUT=10 # Total seconds to wait for default gateway(s).
INTERVAL=1         # Polling interval in seconds.
MAX_RETRIES=20     # Maximum number of retries.
RETRY_TIMEOUT=10   # Total seconds to wait between retries.

# Dynamically determine the location of curl.
CURL=$(command -v curl)
if [ -z "$CURL" ]; then
    log_err "Error: curl not found in PATH. Exiting."
    exit 1
fi

# Ensure the OpenVPN files exist.
if [ ! -f "$OVPN_TEMPL" ] || [ ! -f "$OVPN_AUTH" ] || [ ! -f "$OVPN_PROXY_AUTH" ]; then
    log_err "Error: OpenVPN config files are missing."
    exit 1
fi

# Error handler: log a message and, if under MAX_RETRIES, re-executes the script with the original "$@".
handle_error() {
    log_err "Error encountered at line $1 (retry $RETRY_COUNT of $MAX_RETRIES)"
    if [ "$RETRY_COUNT" -lt "$MAX_RETRIES" ]; then
        RETRY_COUNT=$((RETRY_COUNT + 1))
        log "Retrying in $RETRY_TIMEOUT seconds... (Retry $RETRY_COUNT of $MAX_RETRIES)"
        sleep "$RETRY_TIMEOUT"
        exec "$0" "$EXT_IF" "$RETRY_COUNT"
    else
        log_err "Maximum retries reached. Exiting."
        rm -f "$LOCKFILE"
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
    log_err "Error: /usr/local/etc/.gateway-env.conf not found."
    exit 1
fi

# Set defaults for the Discord notification if not defined.
: "${DISCORD_MENTION:=@everyone}"

# Ensure the webhook URL is defined.
if [ -z "${WEBHOOK_URL:-}" ]; then
    log_err "Error: WEBHOOK_URL must be set in /usr/local/etc/.gateway-env.conf."
    exit 1
fi

log "Starting VPN setup for interface: $EXT_IF"

# Verify the specified interface exists. Sometimes it isn't available immediately.
if ! ifconfig "$EXT_IF" >/dev/null 2>&1; then
    log_err "Error: Interface $EXT_IF does not exist."
    false
fi

# Bring the interface up.
ifconfig "$EXT_IF" up

# Restart the DHCP client service on the interface.
log "Restarting DHCP client on interface $EXT_IF..."
service dhclient restart "$EXT_IF"

# Poll for an IPv4 or non-link-local IPv6 address on the interface.
SECONDS_WAITED=0
IPV4=""
IPV6=""

while [ "$SECONDS_WAITED" -lt "$IP_TIMEOUT" ]; do
    if ifconfig "$EXT_IF" >/dev/null 2>&1; then
        IPV4=$(ifconfig "$EXT_IF" | awk '/inet / {print $2}')
        IPV6=$(ifconfig "$EXT_IF" | awk '/inet6 / && $2 !~ /^fe80/ {print $2}')
        if [ -n "$IPV4" ] || [ -n "$IPV6" ]; then
            break
        fi
    fi
    sleep "$INTERVAL"
    SECONDS_WAITED=$((SECONDS_WAITED + INTERVAL))
done

if [ -z "$IPV4" ] && [ -z "$IPV6" ]; then
    log_err "Error: Failed to acquire an IP address on interface $EXT_IF after $IP_TIMEOUT seconds."
    false
fi

# Poll for default gateways for IPv4 and IPv6 (using netstat)
SECONDS_WAITED=0
DEFAULT_GW_IPV4=""
DEFAULT_GW_IPV6=""

while [ "$SECONDS_WAITED" -lt "$GATEWAY_TIMEOUT" ]; do
    # For IPv4, extract the default gateway from netstat.
    DEFAULT_GW_IPV4=$(netstat -rn -f inet 2>/dev/null | awk '$1 == "default" {print $2}')
    # For IPv6, extract the default gateway from netstat (ignoring link-local).
    DEFAULT_GW_IPV6=$(netstat -rn -f inet6 2>/dev/null | awk '$1 == "default" {print $2}')
    if [ -n "$DEFAULT_GW_IPV4" ]; then
        break
    fi
    sleep "$INTERVAL"
    SECONDS_WAITED=$((SECONDS_WAITED + INTERVAL))
done

if [ -z "$DEFAULT_GW_IPV4" ]; then
    log_err "Error: Failed to acquire a default gateway on interface $EXT_IF after $GATEWAY_TIMEOUT seconds."
    false
fi

# Update the OpenVPN configuration.
sed -e "s|__AUTH_FILE__|$OVPN_AUTH|" \
    -e "s|__PROXY_STRING__|${DEFAULT_GW_IPV4} ${OVPN_PROXY_PORT}|" \
    -e "s|__PROXY_AUTH_FILE__|$OVPN_PROXY_AUTH|" \
    "$OVPN_TEMPL" >"$OVPN_FILE"

# Restart ipfw and OpenVPN services.
log "Restarting ipfw and OpenVPN client..."
if ! ipfw list | grep -qwF "$EXT_IF" || ! ipfw list | grep -qwF "$TUN_IF"; then
    # Restart ipfw if we need to detect and apply rules on a new interface
    service ipfw restart
fi
service openvpn onerestart

# Build the IP information string.
DISCORD_MESSAGE="\`$(date)\` - \`${EXT_IF}\` acquired IP address(es):"
[ -n "$IPV4" ] && DISCORD_MESSAGE="${DISCORD_MESSAGE}\`\`\`$IPV4\`\`\`"
[ -n "$IPV6" ] && DISCORD_MESSAGE="${DISCORD_MESSAGE}\`\`\`$IPV6\`\`\`"

# Build the default gateway information string.
if [ -n "$DEFAULT_GW_IPV4" ] || [ -n "$DEFAULT_GW_IPV6" ]; then
    DISCORD_MESSAGE="${DISCORD_MESSAGE}Default Gateway(s):"
    [ -n "$DEFAULT_GW_IPV4" ] && DISCORD_MESSAGE="${DISCORD_MESSAGE}\`\`\`$DEFAULT_GW_IPV4\`\`\`"
    [ -n "$DEFAULT_GW_IPV6" ] && DISCORD_MESSAGE="${DISCORD_MESSAGE}\`\`\`$DEFAULT_GW_IPV6\`\`\`"
fi

# Poll for an IPv4 address on the tunnel interface.
SECONDS_WAITED=0
TUN_IPV4=""

while [ "$SECONDS_WAITED" -lt "$IP_TIMEOUT" ]; do
    if ifconfig "$TUN_IF" >/dev/null 2>&1; then
        TUN_IPV4=$(ifconfig "$TUN_IF" | awk '/inet / {print $2}')
        if [ -n "$TUN_IPV4" ]; then
            break
        fi
    fi
    sleep "$INTERVAL"
    SECONDS_WAITED=$((SECONDS_WAITED + INTERVAL))
done

if [ -z "$TUN_IPV4" ]; then
    log_err "Error: Failed to acquire an IP address on tunnel interface $TUN_IF after $IP_TIMEOUT seconds."
    false
fi

# Build the external IP information string.
EXT_IP=$("$CURL" -s --retry 5 --retry-delay 5 -4 https://ifconfig.co)

# If the external IP is not usable, log a message and retry.
if [ -z "$EXT_IP" ] || [[ "$EXT_IP" =~ ^102\.129\.252\.[0-9]+$ ]]; then
    log_err "Error: External IP is not usable: '$EXT_IP'"
    false
else
    DISCORD_MESSAGE="${DISCORD_MESSAGE}External IP:\`\`\`$EXT_IP\`\`\`"
fi

# Bring up IPv6 gateway tunnel if available.
if [ -n "$GIF_IF" ] && [ -n "$INT_IF" ] && [ -n "$GIF_UPDATE_URL" ]; then
    # Update the external IP.
    "$CURL" -s --retry 5 --retry-delay 5 -4 -X GET \
        -H "Cache-Control: no-cache, no-store, must-revalidate" \
        "$GIF_UPDATE_URL&myip=$EXT_IP"

    # Calculate MTU - 20 bytes for 6in4 overhead.
    GIF_MTU=$(($(ifconfig "$TUN_IF" | awk '/mtu / {print $NF}') - 20))

    # Bring up the 6in4 tunnel.
    ifconfig "$GIF_IF" tunnel "$TUN_IPV4" "$GIF_IPV4_SERVER" mtu "$GIF_MTU"
    ifconfig "$GIF_IF" inet6 "$GIF_IPV6_CLIENT" "$GIF_IPV6_SERVER" prefixlen 128 up
    ifconfig "$INT_IF" inet6 "$GIF_IPV6_LOCAL" prefixlen 64 up

    # Set the default IPv6 route.
    route -n delete -inet6 default || true
    route -n add -inet6 default "$GIF_IPV6_SERVER"

    # Restart the router advertisement daemon.
    log "Restarting router advertisement daemon..."
    service rtadvd restart
fi

# Send the Discord notification.
log "Sending Discord notification with the following message: $DISCORD_MESSAGE"
"$CURL" -s --retry 5 --retry-delay 5 -4 -X POST -H "Content-Type: application/json" \
    -d "{\"content\": \"${DISCORD_MENTION} ${DISCORD_MESSAGE}\"}" \
    "$WEBHOOK_URL"

log "Notification sent successfully."
rm -f "$LOCKFILE"
