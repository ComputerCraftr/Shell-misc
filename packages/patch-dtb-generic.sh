#!/bin/sh
# patch-dtb-generic.sh — simple DTB patcher.
#
# Changes applied:
#   - Fix broken SD card detect (CD): drop cd-gpios/cd-inverted; ensure broken-cd; disable-wp;
#   - Keep only the default pinctrl state for the target nodes:
#       * force pinctrl-names = "default";
#       * remove pinctrl-[1-9] assignments;
#       * keep pinctrl-0 as the default state.
#
# This script patches node blocks by *node header name* (e.g. sdh@d4280000).
# Override NODES to patch multiple blocks.
#
# Usage:
#   ./patch-dtb-generic.sh -i INPUT.dtb -o OUTPUT.dtb
#
# Env:
#   NODES="sdh@d4280000 sdh@d4280800"  # default: sdh@d4280000
#   DTC=dtc                            # dtc binary

set -eu

DTC="${DTC:-dtc}"
NODES="${NODES:-sdh@d4280000}"

usage() {
    echo "Usage: $0 -i INPUT.dtb -o OUTPUT.dtb" >&2
    exit 2
}

IN=""
OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
    -i)
        IN="${2-}"
        shift 2
        ;;
    -o)
        OUT="${2-}"
        shift 2
        ;;
    -h | --help) usage ;;
    *)
        echo "Unknown arg: $1" >&2
        usage
        ;;
    esac
done

[ -n "$IN" ] && [ -n "$OUT" ] || usage
[ -r "$IN" ] || {
    echo "ERROR: cannot read: $IN" >&2
    exit 1
}
command -v "$DTC" >/dev/null 2>&1 || {
    echo "ERROR: dtc not found (set DTC=...)" >&2
    exit 1
}

tmpdir=$(
    mktemp -d "${TMPDIR:-/tmp}/dtbpatch.XXXXXXXX" 2>/dev/null ||
        mktemp -d
)
trap 'rm -rf "$tmpdir"' EXIT INT TERM HUP

base="$(basename "$IN")"
dts_in="$tmpdir/${base}.dts"
dts_out="$tmpdir/${base}.patched.dts"

"$DTC" -I dtb -O dts -o "$dts_in" "$IN"

if ! awk -v NODES="$NODES" '
    function split_nodes(s,   n,i,a) {
        n = split(s, a, /[[:space:]]+/)
        for (i=1; i<=n; i++) if (a[i] != "") want[a[i]] = 1
    }

    function count_braces(line,   i,c,delta) {
        delta = 0
        for (i=1; i<=length(line); i++) {
            c = substr(line,i,1)
            if (c == "{") delta++
            else if (c == "}") delta--
        }
        return delta
    }

    function leading_ws(s,   t) {
        t = s
        sub(/[^[:space:]].*$/, "", t)
        return t
    }

    BEGIN {
        split_nodes(NODES)
        in_node = 0
        node_depth = -1
        brace_depth = 0
    }

    {
        line = $0
        delta = count_braces(line)

        # Drop turbo-mode from OPP tables (or anywhere it appears).
        if (line ~ /^[[:space:]]*turbo-mode[[:space:]]*;[[:space:]]*$/) {
            brace_depth += delta
            next
        }

        # Enter a target node by header name, e.g. "sdh@d4280000 {"
        if (!in_node) {
            for (n in want) {
                pat = "^[[:space:]]*" n "[[:space:]]*\\{[[:space:]]*$"
                if (line ~ pat) {
                    in_node = 1
                    node_depth = brace_depth + (index(line,"{") ? 1 : 0)

                    saw_broken_cd = 0
                    saw_disable_wp = 0
                    saw_pinctrl_names = 0
                    node_indent = ""
                    prop_indent = ""
                    saw_prop_indent = 0
                    node_indent = leading_ws(line)
                    prop_indent = node_indent "\t"

                    print line
                    brace_depth += delta
                    next
                }
            }
        }

        if (in_node) {
            if (!saw_prop_indent && line ~ /^[[:space:]]*[^[:space:]}]/) {
                prop_indent = leading_ws(line)
                saw_prop_indent = 1
            }
            # --- Broken CD: remove cd-gpios and cd-inverted
            if (line ~ /^[[:space:]]*cd-gpios[[:space:]]*=/) { brace_depth += delta; next }
            if (line ~ /^[[:space:]]*cd-inverted[[:space:]]*;[[:space:]]*$/) { brace_depth += delta; next }

            # Track presence
            if (line ~ /^[[:space:]]*broken-cd[[:space:]]*;[[:space:]]*$/) saw_broken_cd = 1
            if (line ~ /^[[:space:]]*disable-wp[[:space:]]*;[[:space:]]*$/) saw_disable_wp = 1

            # --- Keep only the default pinctrl state
            # Force pinctrl-names to only "default".
            if (line ~ /^[[:space:]]*pinctrl-names[[:space:]]*=/) {
                saw_pinctrl_names = 1
                indent = ""
                indent = leading_ws(line)
                print indent "pinctrl-names = \"default\";"
                brace_depth += delta
                next
            }

            # Always remove any non-zero pinctrl assignment (fast/alt state selectors)
            if (line ~ /^[[:space:]]*pinctrl-[1-9][0-9]*[[:space:]]*=/) { brace_depth += delta; next }

            # Before closing node, inject missing properties
            if (line ~ /^[[:space:]]*};[[:space:]]*$/ && (brace_depth + delta) < node_depth) {
                if (!saw_broken_cd) print prop_indent "broken-cd;"
                if (!saw_disable_wp) print prop_indent "disable-wp;"
                if (!saw_pinctrl_names) print prop_indent "pinctrl-names = \"default\";"
                print line
                in_node = 0
                node_depth = -1
                brace_depth += delta
                next
            }

            print line
            brace_depth += delta
            next
        }

        # Outside target nodes
        print line
        brace_depth += delta
    }
' <"$dts_in" >"$dts_out"; then
    echo "ERROR: awk failed while patching DTS" >&2
    exit 1
fi

if [ ! -s "$dts_out" ]; then
    echo "ERROR: awk produced empty DTS output" >&2
    exit 1
fi

# Recompile (try -@ for symbols; fall back if unsupported)
"$DTC" -@ -I dts -O dtb -o "$tmpdir/out.dtb" "$dts_out" 2>/dev/null ||
    "$DTC" -I dts -O dtb -o "$tmpdir/out.dtb" "$dts_out"

mv "$tmpdir/out.dtb" "$OUT"

echo "OK: wrote patched DTB -> $OUT" >&2
echo "Patched nodes: $NODES" >&2
