#!/bin/sh
set -eu

# Default configuration
WORDLIST="/usr/share/dict/words"
COUNT=5

usage() {
  printf "Usage: %s [-n word_count] [-w wordlist_file]\n" "$0" >&2
  exit 1
}

# Parse options
while getopts "n:w:" opt; do
  case "$opt" in
  n)
    case "$OPTARG" in
    '' | *[!0-9]*)
      echo "Error: -n requires a numeric argument" >&2
      usage
      ;;
    *) COUNT="$OPTARG" ;;
    esac
    ;;
  w)
    WORDLIST="$OPTARG"
    ;;
  *)
    usage
    ;;
  esac
done

# Validate wordlist
if [ ! -r "$WORDLIST" ]; then
  printf "Error: wordlist '%s' is not readable or does not exist\n" "$WORDLIST" >&2
  usage
fi

# Prepare temporary filtered wordlist
TMP_LIST=$(mktemp) || exit 1
trap 'rm -f "$TMP_LIST"' EXIT

grep -E '^[a-z]+$' "$WORDLIST" >"$TMP_LIST"
TOTAL=$(wc -l <"$TMP_LIST")
if [ "$TOTAL" -eq 0 ]; then
  printf "Error: no valid words found in '%s'\n" "$WORDLIST" >&2
  exit 1
fi

# Generate passphrase
i=0
PASSPHRASE=""
while [ "$i" -lt "$COUNT" ]; do
  # Get a random 16-bit number
  RAND=$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')
  INDEX=$((RAND % TOTAL + 1))
  raw=$(sed -n "${INDEX}p" "$TMP_LIST")

  # Capitalize first letter
  first=${raw%"${raw#?}"}
  rest=${raw#?}
  cap="$(printf '%s%s' "$(printf '%s' "$first" | tr '[:lower:]' '[:upper:]')" "$rest")"

  # Build hyphen-separated passphrase
  if [ "$i" -eq 0 ]; then
    PASSPHRASE=$cap
  else
    PASSPHRASE="$PASSPHRASE-$cap"
  fi

  i=$((i + 1))
done

# Output the generated passphrase
printf '%s\n\n' "$PASSPHRASE"

# Calculate entropy
ENT_PER=$(awk -v d="$TOTAL" 'BEGIN { printf "%.2f", log(d)/log(2) }')
TOTAL_ENT=$(awk -v e="$ENT_PER" -v c="$COUNT" 'BEGIN { printf "%.2f", e * c }')

printf "Entropy per word: %s bits\n" "$ENT_PER"
printf "Total entropy:    %s bits\n" "$TOTAL_ENT"

# Classify strength
CLASS=$(awk -v t="$TOTAL_ENT" 'BEGIN {
  if (t < 44) print "🔴 Weak: Not resistant to offline attacks";
  else if (t < 60) print "🟡 Moderate: Acceptable for low-value uses";
  else if (t < 80) print "🟢 Strong: Resistant to offline brute-force";
  else print "🟢🛡️ Very strong: Secure against targeted offline cracking";
}')
printf "%s\n" "$CLASS"
