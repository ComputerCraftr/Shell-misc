#!/bin/sh
set -eu

# Extract values from status output
LOADPCT=$(apcaccess -u -p LOADPCT 2>/dev/null || true)
NOMPOWER=$(apcaccess -u -p NOMPOWER 2>/dev/null || true)

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
