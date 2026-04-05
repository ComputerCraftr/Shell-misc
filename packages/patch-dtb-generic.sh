#!/bin/sh
# patch-dtb-generic.sh — DTB patcher for Milk-V Jupiter SD boot stability.
#
# Changes applied to target SD host nodes:
#   - Fix card-detect handling:
#       * drop cd-gpios / cd-inverted
#       * ensure broken-cd
#       * ensure disable-wp
#   - Keep only the default pinctrl state:
#       * force pinctrl-names = "default"
#       * remove pinctrl-[1-9]* assignments
#       * keep pinctrl-0
#   - Force conservative SD clocking for boot stability:
#       * set max-frequency = <25000000>
#   - Optionally disable 1.8 V signaling when requested:
#       * ensure no-1-8-v (only with APPLY_NO_1_8_V=1)
#   - Remove sd-uhs-sdr12/sdr25/sdr50/sdr104/ddr50 if present
#   - Drop turbo-mode properties anywhere in the tree.
#
# Usage:
#   ./patch-dtb-generic.sh -i INPUT.dtb -o OUTPUT.dtb
#
# Env:
#   NODES="sdh@d4280000 sdh@d4280800"  # default: sdh@d4280000
#   DTC=dtc                            # dtc binary
#   MAX_FREQ=25000000                  # default frequency cap
#   APPLY_NO_1_8_V=0                   # set to 1 to inject no-1-8-v

set -eu

DTC="${DTC:-dtc}"
NODES="${NODES:-sdh@d4280000}"
MAX_FREQ="${MAX_FREQ:-25000000}"
APPLY_NO_1_8_V="${APPLY_NO_1_8_V:-0}"

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
    -h | --help)
        usage
        ;;
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
case "$MAX_FREQ" in
'' | *[!0-9]*)
    echo "ERROR: MAX_FREQ must be an integer, got: $MAX_FREQ" >&2
    exit 1
    ;;
esac
case "$APPLY_NO_1_8_V" in
0 | 1) ;;
*)
    echo "ERROR: APPLY_NO_1_8_V must be 0 or 1, got: $APPLY_NO_1_8_V" >&2
    exit 1
    ;;
esac

tmpdir=$(
    mktemp -d "${TMPDIR:-/tmp}/dtbpatch.XXXXXXXX" 2>/dev/null ||
        mktemp -d
)
trap 'rm -rf "$tmpdir"' EXIT INT TERM HUP

base=$(basename "$IN")
dts_in="$tmpdir/${base}.dts"
dts_out="$tmpdir/${base}.patched.dts"

"$DTC" -I dtb -O dts -o "$dts_in" "$IN"

if ! awk -v NODES="$NODES" -v MAX_FREQ="$MAX_FREQ" -v APPLY_NO_1_8_V="$APPLY_NO_1_8_V" '
    function split_nodes(s,   n,i,a) {
        n = split(s, a, /[[:space:]]+/)
        for (i = 1; i <= n; i++) {
            if (a[i] != "") want[a[i]] = 1
        }
    }

    function count_braces(line,   i,c,delta) {
        delta = 0
        for (i = 1; i <= length(line); i++) {
            c = substr(line, i, 1)
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
                    node_depth = brace_depth + (index(line, "{") ? 1 : 0)

                    saw_broken_cd = 0
                    saw_disable_wp = 0
                    saw_pinctrl_names = 0
                    saw_no_1_8_v = 0
                    saw_max_frequency = 0

                    node_indent = leading_ws(line)
                    prop_indent = node_indent "\t"
                    saw_prop_indent = 0

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

            # Remove card-detect properties we do not want.
            if (line ~ /^[[:space:]]*cd-gpios[[:space:]]*=/) { brace_depth += delta; next }
            if (line ~ /^[[:space:]]*cd-inverted[[:space:]]*;[[:space:]]*$/) { brace_depth += delta; next }

            # Remove UHS capability flags if present to avoid retry storms during high-speed negotiation.
            if (line ~ /^[[:space:]]*sd-uhs-sdr12[[:space:]]*;[[:space:]]*$/) { brace_depth += delta; next }
            if (line ~ /^[[:space:]]*sd-uhs-sdr25[[:space:]]*;[[:space:]]*$/) { brace_depth += delta; next }
            if (line ~ /^[[:space:]]*sd-uhs-sdr50[[:space:]]*;[[:space:]]*$/) { brace_depth += delta; next }
            if (line ~ /^[[:space:]]*sd-uhs-sdr104[[:space:]]*;[[:space:]]*$/) { brace_depth += delta; next }
            if (line ~ /^[[:space:]]*sd-uhs-ddr50[[:space:]]*;[[:space:]]*$/) { brace_depth += delta; next }

            # Only remove an existing no-1-8-v when the caller does not want it applied.
            if (line ~ /^[[:space:]]*no-1-8-v[[:space:]]*;[[:space:]]*$/) {
                if (APPLY_NO_1_8_V == 1) {
                    saw_no_1_8_v = 1
                    print line
                }
                brace_depth += delta
                next
            }

            # Track presence of properties we want to ensure.
            if (line ~ /^[[:space:]]*broken-cd[[:space:]]*;[[:space:]]*$/) saw_broken_cd = 1
            if (line ~ /^[[:space:]]*disable-wp[[:space:]]*;[[:space:]]*$/) saw_disable_wp = 1

            # Normalize pinctrl-names.
            if (line ~ /^[[:space:]]*pinctrl-names[[:space:]]*=/) {
                saw_pinctrl_names = 1
                indent = leading_ws(line)
                print indent "pinctrl-names = \"default\";"
                brace_depth += delta
                next
            }

            # Drop non-default pinctrl states.
            if (line ~ /^[[:space:]]*pinctrl-[1-9][0-9]*[[:space:]]*=/) {
                brace_depth += delta
                next
            }

            # Force a conservative max-frequency.
            if (line ~ /^[[:space:]]*max-frequency[[:space:]]*=/) {
                saw_max_frequency = 1
                indent = leading_ws(line)
                print indent "max-frequency = <" MAX_FREQ ">;"
                brace_depth += delta
                next
            }

            # Before closing node, inject missing properties.
            if (line ~ /^[[:space:]]*};[[:space:]]*$/ && (brace_depth + delta) < node_depth) {
                if (!saw_broken_cd) print prop_indent "broken-cd;"
                if (!saw_disable_wp) print prop_indent "disable-wp;"
                if (APPLY_NO_1_8_V == 1 && !saw_no_1_8_v) print prop_indent "no-1-8-v;"
                if (!saw_max_frequency) print prop_indent "max-frequency = <" MAX_FREQ ">;"
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

        # Outside target nodes.
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

"$DTC" -@ -I dts -O dtb -o "$tmpdir/out.dtb" "$dts_out" 2>/dev/null ||
    "$DTC" -I dts -O dtb -o "$tmpdir/out.dtb" "$dts_out"

mv "$tmpdir/out.dtb" "$OUT"

echo "OK: wrote patched DTB -> $OUT" >&2
echo "Patched nodes: $NODES" >&2
echo "Forced max-frequency: $MAX_FREQ" >&2
if [ "$APPLY_NO_1_8_V" = 1 ]; then
    echo "Applied no-1-8-v" >&2
else
    echo "Left no-1-8-v unchanged/absent" >&2
fi
