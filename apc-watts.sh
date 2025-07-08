#!/bin/sh
set -eu

# Get status output
STATUS=$(apcaccess status 2>/dev/null || true)

# Ensure non-empty output
if [ -z "$STATUS" ]; then
    echo "Error: apcaccess returned no output." >&2
    exit 1
fi

# Extract values
LOADPCT=$(printf '%s\n' "$STATUS" | awk '/LOADPCT/ { gsub(/[%]/, "", $3); print $3 }')
NOMPOWER=$(printf '%s\n' "$STATUS" | awk '/NOMPOWER/ { print $3 }')

# Validate values are numeric
case "$LOADPCT" in
'' | *[!0-9.]*)
    echo "Error: Invalid LOADPCT: $LOADPCT" >&2
    exit 1
    ;;
esac

case "$NOMPOWER" in
'' | *[!0-9.]*)
    echo "Error: Invalid NOMPOWER: $NOMPOWER" >&2
    exit 1
    ;;
esac

# Calculate estimated power draw in watts
WATTS=$(echo "$LOADPCT * $NOMPOWER / 100" | bc -l)
WATTS_FMT=$(printf "%.1f" "$WATTS")

# Output cleanly
echo "Estimated Power Draw: $WATTS_FMT Watts"
