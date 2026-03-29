#!/bin/sh

log() { logger -t "$SCRIPT_NAME" -p daemon.notice "$*"; }
log_err() { logger -t "$SCRIPT_NAME" -p daemon.err "$*"; }

ensure_single_line_value() {
    label="$1"
    value="$2"
    newline=$(printf '\nX')
    newline=${newline%X}
    carriage_return=$(printf '\r')

    case "$value" in
    *"$newline"* | *"$carriage_return"*)
        log_err "$label contains an invalid newline or carriage return."
        exit 1
        ;;
    esac
}

ensure_absolute_path() {
    label="$1"
    value="$2"
    ensure_single_line_value "$label" "$value"
    if ! LC_ALL=C printf '%s\n' "$value" | grep -Eq '^/[^[:cntrl:][:space:]|&\\]*$'; then
        log_err "$label must be an absolute path without control, whitespace, '|', '&', or '\\': '$value'"
        exit 1
    fi
}

ensure_safe_interface_name() {
    label="$1"
    value="$2"

    ensure_single_line_value "$label" "$value"
    if ! LC_ALL=C printf '%s\n' "$value" | grep -Eq '^[A-Za-z0-9_.-]+$'; then
        log_err "$label contains invalid characters: '$value'"
        exit 1
    fi
}

ensure_safe_interface_list() {
    label="$1"
    value="$2"

    ensure_single_line_value "$label" "$value"
    if ! LC_ALL=C printf '%s\n' "$value" | grep -Eq '^[A-Za-z0-9_.-]+(,[A-Za-z0-9_.-]+)*$'; then
        log_err "$label must be a comma-separated list of interface names: '$value'"
        exit 1
    fi
}

ensure_nonempty_decimal() {
    label="$1"
    value="$2"

    ensure_single_line_value "$label" "$value"
    if ! LC_ALL=C printf '%s\n' "$value" | grep -Eq '^[0-9]+$'; then
        log_err "$label must be a non-empty decimal value: '$value'"
        exit 1
    fi
}

write_file_atomically_mode() {
    target_path="$1"
    target_mode="$2"
    shift 2
    [ "${1-}" = "--" ] && shift
    target_dir=$(dirname "$target_path")
    temp_path=$(umask 077 && mktemp "${target_dir}/.${SCRIPT_NAME}.tmp.XXXXXX") || return 1
    if ! chmod "$target_mode" "$temp_path"; then
        rm -f -- "$temp_path"
        return 1
    fi
    if ! "$@" >"$temp_path"; then
        rm -f -- "$temp_path"
        return 1
    fi
    if ! mv -f -- "$temp_path" "$target_path"; then
        rm -f -- "$temp_path"
        return 1
    fi
}

file_mode() {
    target_path="$1"

    if stat -f '%Lp' "$target_path" 2>/dev/null; then
        return 0
    fi
    stat -c '%a' "$target_path" 2>/dev/null
}

replace_file_atomically() {
    source_path="$1"
    if ! source_mode=$(file_mode "$source_path"); then
        return 1
    fi

    write_file_atomically_mode "$2" "$source_mode" -- cat "$source_path"
}

write_file_atomically() {
    target_path="$1"
    shift
    write_file_atomically_mode "$target_path" 600 -- "$@"
}
