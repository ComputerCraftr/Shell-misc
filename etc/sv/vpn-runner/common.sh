#!/bin/sh

log() { logger -t "$SCRIPT_NAME" -p daemon.notice "$*"; }
log_err() { logger -t "$SCRIPT_NAME" -p daemon.err "$*"; }

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
