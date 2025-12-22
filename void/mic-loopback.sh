#!/bin/sh
set -eu

# Usage:
#   mic-loopback.sh <source.node.name> [volume]
# Example:
#   mic-loopback.sh alsa_input.pci-0000_10_00.3.analog-stereo 0.05

SRC_NAME="${1:?usage: $0 <source.node.name> [volume_0_to_1]}"
VOL="${2:-0.05}"

SRC_ID="$(
    wpctl status -n | awk -v want="$SRC_NAME" '
    # Enter Audio section ONLY on an exact match
    /^Audio$/ { in_audio=1; next }

    # Leave Audio section on any other top-level header
    in_audio && /^[A-Z]/ { in_audio=0 }

    # Enter Sources subsection
    in_audio && /├─ Sources:/ { in_sources=1; next }

    # Leave Sources subsection when another subsection begins
    in_sources && /├─/ { in_sources=0 }

    in_sources {
      line=$0
      # Strip tree drawing characters and everything before first digit
      sub(/^[^0-9]*/, "", line)

      # Match: <id>. <node.name>
      if (match(line, /^([0-9]+)\.\s+([^[:space:]]+)/, m)) {
        if (m[2] == want) {
          print m[1]
          exit
        }
      }
    }
  '
)"

[ -n "$SRC_ID" ] || {
    echo "ERROR: source not found: $SRC_NAME" >&2
    exit 1
}

# Set capture volume BEFORE loopback
wpctl set-volume "$SRC_ID" "$VOL"

# Start loopback for this exact capture node
exec pw-loopback -C "$SRC_NAME"
