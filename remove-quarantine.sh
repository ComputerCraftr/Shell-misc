#!/bin/sh
set -eu

for dir in /Applications "$HOME/Applications"; do
    [ -d "$dir" ] || continue
    find "$dir" -name "*.app" -prune -exec sh -c '
		app="$1"
		xattr -p com.apple.quarantine "$app" >/dev/null 2>&1 && xattr -dr com.apple.quarantine "$app"
	' _ {} \;
done
