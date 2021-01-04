#!/bin/dash

LOCK="/var/lock/libgnome-bookmarks.sh"
BOOKMARKS_FILE="/home/amnesia/.config/gtk-3.0/bookmarks"

_build_bookmark_line() {
    local target
    target=$(echo "$1" | sed 's, ,%20,g')

    if [ $# -ge 2 ]; then
        title="$2"
        echo "file://$target $title"
    else
        echo "file://$target"
    fi
}

add_gnome_bookmark() {
    # Avoid race conditions
    touch "${LOCK}" 2>/dev/null || true
    exec 9<"${LOCK}"
    flock --exclusive 9

    mkdir -p "$(dirname "${BOOKMARKS_FILE}")"
    _build_bookmark_line "$@" >> "${BOOKMARKS_FILE}"
}

remove_gnome_bookmark() {
    local line
    local tmpfile
    line=$(_build_bookmark_line "$@")
    tmpfile=$(mktemp)

    # Avoid race conditions
    touch "${LOCK}" 2>/dev/null || true
    exec 9<"${LOCK}"
    flock --exclusive 9

    # Check if the line exists
    if ! grep -q "^${line}$" "${BOOKMARKS_FILE}"; then
        return 1
    fi

    # Delete the line
    grep -v "^${line}$" "${BOOKMARKS_FILE}" > "${tmpfile}"
    # We do this instead of mv to preserve the ownership and
    # permissions of the bookmarks file
    cat "${tmpfile}" > "${BOOKMARKS_FILE}"
    rm "${tmpfile}"
}
